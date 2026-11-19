import AppKit
import Foundation
import Observation

/// A wg-quick tunnel: a config in /etc/wireguard.
struct WGTunnel: Identifiable, Equatable {
    var id: String { name }
    var name: String
    /// nil until imported by the app or loaded with the password.
    var summary: WGConfigSummary?
    var running = false
    /// The utun interface while running.
    var interface: String?
    var rxBytes: Int64?
    var txBytes: Int64?
}

/// Terminal WireGuard (wireguard-tools: `wg`, `wg-quick`, `wireguard-go`).
///
/// Configs live in /etc/wireguard (root-only files). Up, down, import and live
/// handshakes go through the admin prompt; listing tunnels, whether they're up
/// (their address on a utun interface) and traffic counters don't need it.
@MainActor
@Observable
final class WireGuardModel {
    var toolsVersion: String?
    /// Newest wireguard-tools in Homebrew's formula list (from `brew info`).
    var latestVersion: String?
    var brewPath: String?
    var tunnels: [WGTunnel] = []
    /// Live peer stats per tunnel name, from the last "Show handshakes".
    var stats: [String: [WGPeerStats]] = [:]
    var statsTime: Date?
    /// Running tunnels as VPN entries, for the mesh check and routes views.
    var asVPN: [String: VPNService] = [:]
    var checks: [String: [MeshCheckItem]] = [:]
    var busy: String?
    var lastError: String?
    var lastOutput: String?
    var lastRefresh: Date?

    /// utun name per tunnel, learned from /var/run/wireguard while root (stats).
    private var knownInterfaces: [String: String] = [:]
    private var summaries: [String: WGConfigSummary] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "wireguard.summaries"),
                  let s = try? JSONDecoder().decode([String: WGConfigSummary].self, from: data) else { return [:] }
            return s
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "wireguard.summaries")
        }
    }

    static let prefixes = ["/opt/homebrew", "/usr/local"]

    var isInstalled: Bool { toolsVersion != nil }
    var updateAvailable: Bool {
        guard let installed = toolsVersion, let latest = latestVersion else { return false }
        return isNewer(latest, than: installed)
    }

    private var brewEnvironment: [String: String] {
        ["HOME": NSHomeDirectory(), "HOMEBREW_NO_AUTO_UPDATE": "1",
         "PATH": "\(((brewPath ?? "/opt/homebrew/bin/brew") as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// Reads the newest version from Homebrew's local formula data (no download).
    func checkForUpdate() async {
        guard let brew = brewPath else { return }
        let r = await Shell.run(brew, ["info", "--json=v2", "wireguard-tools"], environment: brewEnvironment)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formula = (json["formulae"] as? [[String: Any]])?.first,
              let versions = formula["versions"] as? [String: Any],
              let stable = versions["stable"] as? String else { return }
        latestVersion = stable
    }
    var wgPath: String? {
        Self.prefixes.map { "\($0)/bin/wg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var running: [WGTunnel] { tunnels.filter(\.running) }

    func worstIssue() -> MeshCheckItem.Severity? {
        let items: [MeshCheckItem] = running.flatMap { (t: WGTunnel) -> [MeshCheckItem] in checks[t.name] ?? [] }
        let issues: [MeshCheckItem.Severity] = items.map(\.severity).filter { $0 == .problem || $0 == .warning }
        return issues.min { $0.rawValue < $1.rawValue }
    }

    // MARK: Refresh

    /// - Parameter vpnInterfaces: utuns owned by system VPNs (Proton's app uses the
    ///   same 10.2.0.2 address as its WireGuard configs, so those are skipped).
    func refresh(vpnInterfaces: Set<String>, meshes: [MeshContext]) async {
        brewPath = Self.prefixes.map { "\($0)/bin/brew" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        if let wg = wgPath {
            if toolsVersion == nil {
                let r = await Shell.run(wg, ["--version"])
                // "wireguard-tools v1.0.20250521 - https://git.zx2c4.com/wireguard-tools/"
                toolsVersion = r.stdout.split(separator: " ").first { $0.hasPrefix("v") }.map { String($0.dropFirst()) }
                    ?? (r.ok ? "installed" : nil)
            }
        } else {
            toolsVersion = nil
        }

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: WireGuardConfig.directory)) ?? [])
            .filter { $0.hasSuffix(".conf") }.map { String($0.dropLast(5)) }.sorted()
        let stored = summaries

        async let ifacesResult = NetworkInspector.interfaces()
        async let procResult = Shell.run("/usr/bin/pgrep", ["-x", "wireguard-go"])
        let (ifaces, proc) = await (ifacesResult, procResult)
        let wgRunning = proc.ok
        let meshTuns = Set(meshes.compactMap(\.tun))
        let byName = Dictionary(ifaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var list: [WGTunnel] = []
        var taken = Set<String>()
        for name in names {
            var t = WGTunnel(name: name, summary: stored[name])
            if wgRunning, let s = t.summary {
                func owns(_ i: NetworkInspector.Iface) -> Bool {
                    i.name.hasPrefix("utun") && !vpnInterfaces.contains(i.name) && !meshTuns.contains(i.name)
                        && !taken.contains(i.name) && s.bareAddresses.contains(where: i.addresses.contains)
                }
                if let known = knownInterfaces[name], let i = byName[known], owns(i) {
                    t.interface = known
                } else {
                    t.interface = ifaces.first(where: owns)?.name
                }
            }
            if let iface = t.interface {
                taken.insert(iface)
                t.running = true
                (t.rxBytes, t.txBytes) = await Self.byteCounters(iface)
            }
            list.append(t)
        }
        tunnels = list
        for name in knownInterfaces.keys where !(list.first { $0.name == name }?.running ?? false) {
            knownInterfaces[name] = nil
            stats[name] = nil
        }

        // Routes, DNS and the mesh check for running tunnels.
        var vpns: [String: VPNService] = [:]
        var newChecks: [String: [MeshCheckItem]] = [:]
        let up = list.filter(\.running)
        if !up.isEmpty {
            async let routesResult = VPNReader.routeTable()
            async let resolversResult = VPNReader.resolvers()
            let (routes, resolvers) = await (routesResult, resolversResult)
            for t in up {
                let v = vpnService(for: t, routes: routes, resolvers: resolvers)
                vpns[t.name] = v
                newChecks[t.name] = await MeshClashCheck.run(vpn: v, meshes: meshes)
            }
        }
        asVPN = vpns
        checks = newChecks
        lastRefresh = Date()
    }

    private func vpnService(for t: WGTunnel, routes: [RouteEntry: String], resolvers: [DNSResolver]) -> VPNService {
        let s = t.summary ?? WGConfigSummary()
        var v = VPNService(id: "wg:" + t.name, name: t.name, type: "WireGuard", appBundleID: nil, enabled: true,
                           state: .connected, server: s.peers.first?.endpoint, providerBundleID: nil, onDemand: nil)
        v.interface = t.interface
        v.addresses = s.bareAddresses
        v.dnsServers = s.dnsServers
        v.routes = routes.filter { $0.value == t.interface && !$0.key.cloned }.map(\.key)
            .sorted { ($0.family, $0.scoped ? 1 : 0, $0.destination) < ($1.family, $1.scoped ? 1 : 0, $1.destination) }
        v.resolvers = resolvers.filter { r in r.nameservers.contains { s.dnsServers.contains($0) } }
        v.isPrimary = s.isFullTunnel
        return v
    }

    /// Byte counters of an interface from `netstat -I <if> -b` (no root).
    static func byteCounters(_ iface: String) async -> (Int64?, Int64?) {
        let r = await Shell.run("/usr/sbin/netstat", ["-n", "-b", "-I", iface])
        for line in r.stdout.split(separator: "\n") where line.contains("<Link#") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            // Name Mtu <Link#N> Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            if t.count >= 9 { return (Int64(t[5]), Int64(t[8])) }
        }
        return (nil, nil)
    }

    // MARK: Actions

    private func perform(_ label: String, refresh: @escaping () async -> Void,
                         _ body: () async throws -> Void) async {
        guard busy == nil else { return }
        busy = label
        lastError = nil
        do {
            try await body()
        } catch AdminError.cancelled {
        } catch {
            lastError = error.localizedDescription
        }
        busy = nil
        await refresh()
    }

    /// `brew install` / `brew upgrade wireguard-tools` (pulls in wireguard-go and bash), as the user.
    func install(refresh: @escaping () async -> Void) async {
        guard let brew = brewPath else {
            lastError = "Homebrew isn't installed. Install it from https://brew.sh, then try again."
            return
        }
        let verb = isInstalled ? "upgrade" : "install"
        await perform(isInstalled ? "Updating wireguard-tools…" : "Installing wireguard-tools…", refresh: refresh) {
            let r = await Shell.run(brew, [verb, "wireguard-tools"], environment: brewEnvironment)
            lastOutput = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.ok else { throw AdminError.failed("brew \(verb) wireguard-tools failed — see the output below.") }
            toolsVersion = nil   // re-read
        }
    }

    /// Asks for a .conf file and copies it to /etc/wireguard.
    func importConfig(refresh: @escaping () async -> Void) async {
        let panel = NSOpenPanel()
        panel.title = "Import a WireGuard config"
        panel.allowedContentTypes = [.init(filenameExtension: "conf") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await importConfig(at: url, refresh: refresh)
    }

    func importConfig(at url: URL, refresh: @escaping () async -> Void) async {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let parsed = WireGuardConfig.parse(text)
        guard parsed.hasPrivateKey, !parsed.summary.peers.isEmpty, !parsed.summary.addresses.isEmpty else {
            lastError = "\(url.lastPathComponent) doesn't look like a WireGuard config (needs [Interface] with PrivateKey and Address, and a [Peer])."
            return
        }
        let name = WireGuardConfig.sanitizedName(url.deletingPathExtension().lastPathComponent)
        let exists = FileManager.default.fileExists(atPath: "\(WireGuardConfig.directory)/\(name).conf")
        if exists {
            let alert = NSAlert()
            alert.messageText = "Replace the tunnel “\(name)”?"
            alert.informativeText = "\(WireGuardConfig.directory)/\(name).conf already exists."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        await perform("Importing \(name)…", refresh: refresh) {
            // Root can't read files in privacy-protected folders (Documents, Desktop,
            // Downloads …) on the app's behalf, even after the user picked them.
            // Stage a copy in the app's own temp folder (0700/0600), which root can read.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wg-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: dir) }
            let staged = dir.appendingPathComponent("\(name).conf")
            guard FileManager.default.createFile(atPath: staged.path, contents: Data(text.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw AdminError.failed("Couldn't stage \(url.lastPathComponent) for import.")
            }
            let out = try await Admin.run(WireGuardConfig.importScript(source: staged.path, name: name),
                                          reason: "Mac Mesh Profiler wants to add the WireGuard tunnel \(name).")
            merge(WireGuardConfig.parseDump(out))
        }
    }

    /// Reads every config's non-secret settings (one password prompt).
    func loadDetails(refresh: @escaping () async -> Void) async {
        await perform("Reading WireGuard configs…", refresh: refresh) {
            let out = try await Admin.run(WireGuardConfig.dumpScript,
                                          reason: "Mac Mesh Profiler wants to read your WireGuard tunnel settings (keys are not read).")
            let loaded = WireGuardConfig.parseDump(out)
            // Forget tunnels whose files are gone.
            summaries = loaded
        }
    }

    private func merge(_ loaded: [String: WGConfigSummary]) {
        var s = summaries
        for (k, v) in loaded { s[k] = v }
        summaries = s
    }

    func up(_ name: String, refresh: @escaping () async -> Void) async {
        await perform("Starting \(name)…", refresh: refresh) {
            let out = try await Admin.run(WireGuardConfig.wgQuickScript("up", name: name),
                                          reason: "Mac Mesh Profiler wants to start the WireGuard tunnel \(name).")
            lastOutput = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if summaries[name] == nil { try? await loadSilently() }
        }
    }

    func down(_ name: String, refresh: @escaping () async -> Void) async {
        await perform("Stopping \(name)…", refresh: refresh) {
            let out = try await Admin.run(WireGuardConfig.wgQuickScript("down", name: name),
                                          reason: "Mac Mesh Profiler wants to stop the WireGuard tunnel \(name).")
            lastOutput = out.trimmingCharacters(in: .whitespacesAndNewlines)
            knownInterfaces[name] = nil
            stats[name] = nil
        }
    }

    func remove(_ name: String, refresh: @escaping () async -> Void) async {
        let running = tunnels.first { $0.name == name }?.running ?? false
        let alert = NSAlert()
        alert.messageText = "Remove the tunnel “\(name)”?"
        alert.informativeText = (running ? "It is stopped first. " : "")
            + "\(WireGuardConfig.directory)/\(name).conf is deleted, including its private key. Keep a copy of the original .conf if you want it back."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await perform("Removing \(name)…", refresh: refresh) {
            let out = try await Admin.run(WireGuardConfig.removeScript(name: name, running: running),
                                          reason: "Mac Mesh Profiler wants to remove the WireGuard tunnel \(name).")
            lastOutput = out.trimmingCharacters(in: .whitespacesAndNewlines)
            var s = summaries
            s[name] = nil
            summaries = s
        }
    }

    /// Handshakes and per-peer traffic via `wg show` (root).
    func loadStats(refresh: @escaping () async -> Void) async {
        await perform("Reading handshakes…", refresh: refresh) {
            let out = try await Admin.run(WireGuardConfig.statsScript,
                                          reason: "Mac Mesh Profiler wants to read live WireGuard status (keys are not read).")
            let (names, peers) = WireGuardConfig.parseStats(out)
            knownInterfaces = names
            stats = names.reduce(into: [:]) { acc, pair in acc[pair.key] = peers[pair.value] ?? [] }
            statsTime = Date()
        }
    }

    /// After an up: macOS usually reuses the authorization, so this rarely prompts again.
    private func loadSilently() async throws {
        let out = try await Admin.run(WireGuardConfig.dumpScript, reason: "Mac Mesh Profiler wants to read your WireGuard tunnel settings.")
        merge(WireGuardConfig.parseDump(out))
    }

    // MARK: Demo

    func applyDemo(tunnels: [WGTunnel], stats: [String: [WGPeerStats]], vpn: [String: VPNService],
                   checks: [String: [MeshCheckItem]], version: String) {
        self.tunnels = tunnels
        self.stats = stats
        self.statsTime = Date()
        self.asVPN = vpn
        self.checks = checks
        self.toolsVersion = version
        self.brewPath = "/opt/homebrew/bin/brew"
        self.lastRefresh = Date()
    }
}
