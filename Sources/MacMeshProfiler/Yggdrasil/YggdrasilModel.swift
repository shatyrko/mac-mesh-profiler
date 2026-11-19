import Foundation
import Observation

/// The part of /etc/yggdrasil.conf this app manages. Everything else in the
/// config (private key, multicast, NodeInfo, …) is left untouched on apply.
struct YggdrasilSettings: Codable, Equatable {
    var peers: [String] = []
    var listen: [String] = []
    var ifName: String = "auto"
    /// Empty = the platform default (unix:///var/run/yggdrasil.sock, root-only).
    var adminListen: String = ""
}

@MainActor
@Observable
final class YggdrasilModel: MeshServiceModel {
    static let binary = "/usr/local/bin/yggdrasil"
    static let ctl = "/usr/local/bin/yggdrasilctl"
    static let configPath = "/etc/yggdrasil.conf"
    static let logPaths = ["/tmp/yggdrasil.stdout.log", "/tmp/yggdrasil.stderr.log"]
    static let localTCPAdmin = "tcp://localhost:9001"
    static let peerSchemes = ["tcp", "tls", "quic", "ws", "wss", "socks", "sockstls", "unix"]
    static let listenSchemes = ["tcp", "tls", "quic", "ws", "wss"]
    static let publicPeersURL = URL(string: "https://publicpeers.neilalexander.dev")!

    let id = ServiceID.yggdrasil
    let daemon = LaunchDaemon(label: "yggdrasil", plistPath: "/Library/LaunchDaemons/yggdrasil.plist")

    var runtime = ServiceRuntime()
    @ObservationIgnored private let connectionMatcher = ConnectionPeerMatcher()

    /// Settings as last read from / written to the system config. nil until the
    /// user loads them once (the config file is root-only, so reading it needs a password).
    private(set) var saved: YggdrasilSettings?
    private(set) var savedAt: Date?
    /// What the editor shows.
    var draft = YggdrasilSettings()

    var isDirty: Bool { saved != nil && draft != saved }

    /// The node's public key (not secret). Shown only when it is known to
    /// belong to the running node, i.e. its address matches the live one.
    private(set) var publicKey: String?

    /// A key together with the address it produces, so a stale value (from a
    /// regenerated config) is never shown for the wrong node.
    private struct KeyedAddress: Codable, Equatable {
        var key: String
        var address: String
    }
    private var knownKey: KeyedAddress?

    private let defaultsKey = "yggdrasil.savedSettings"
    private let defaultsDateKey = "yggdrasil.savedAt"
    private let defaultsKeyKey = "yggdrasil.publicKey"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let s = try? JSONDecoder().decode(YggdrasilSettings.self, from: data) {
            saved = s
            draft = s
            savedAt = UserDefaults.standard.object(forKey: defaultsDateKey) as? Date
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKeyKey),
           let k = try? JSONDecoder().decode(KeyedAddress.self, from: data) {
            knownKey = k
        }
    }

    private func rememberKey(_ k: KeyedAddress) {
        guard k != knownKey else { return }
        knownKey = k
        if let data = try? JSONEncoder().encode(k) {
            UserDefaults.standard.set(data, forKey: defaultsKeyKey)
        }
    }

    private func remember(_ s: YggdrasilSettings) {
        saved = s
        draft = s
        savedAt = Date()
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            UserDefaults.standard.set(savedAt, forKey: defaultsDateKey)
        }
    }

    // MARK: Status

    func refresh() async {
        var r = runtime
        if FileManager.default.isExecutableFile(atPath: Self.binary) {
            let v = await Shell.run(Self.binary, ["-version"])
            r.installedVersion = v.stdout.split(separator: "\n")
                .first(where: { $0.hasPrefix("Build version:") })
                .map { $0.replacingOccurrences(of: "Build version:", with: "").trimmingCharacters(in: .whitespaces) }
                ?? "unknown"
        } else {
            r.installedVersion = nil
        }
        r.daemon = await daemon.status()
        r.address = r.daemon.running ? await Interfaces.overlayAddress(.yggdrasil) : nil

        let admin = saved?.adminListen ?? ""
        if r.daemon.running, let pid = r.daemon.pid {
            let listenPorts = Set((saved?.listen ?? []).compactMap(Self.port(of:)))
            let adminPort = admin.hasPrefix("tcp://") ? Self.port(of: admin) : nil
            r.network = await NetworkInspector.snapshot(
                process: "yggdrasil", pid: pid, tun: r.address?.interface
            ) { proto, port, linkLocal in
                if proto == "UDP" && port == 9001 { return "Multicast peer discovery (LAN)" }
                if proto == "TCP" && port == adminPort { return "Admin API" }
                if linkLocal { return "LAN peering listener (multicast)" }
                if listenPorts.contains(port) { return proto == "UDP" ? "Peer listener (QUIC)" : "Peer listener (Listen)" }
                return proto == "UDP" ? "UDP" : "Peer listener"
            }
        } else {
            r.network = NetworkSnapshot()
        }
        await resolvePublicKey(address: r.address?.address, admin: r.daemon.running ? admin : "")

        if !r.daemon.running {
            r.livePeers = []
            r.liveNote = nil
        } else if admin.hasPrefix("tcp://") {
            if let peers = await fetchLivePeers(endpoint: admin) {
                r.livePeers = peers
                r.liveNote = nil
            } else {
                r.livePeers = []
                r.liveNote = "Could not reach the admin API at \(admin)."
            }
        } else {
            // No admin API: derive up/down from the daemon's open connections.
            r.livePeers = await connectionMatcher.peers(configured: saved?.peers ?? draft.peers, network: r.network)
            r.liveNote = nil
        }
        r.lastRefresh = Date()
        r.busy = runtime.busy
        r.lastError = runtime.lastError
        r.latestRelease = runtime.latestRelease
        runtime = r
    }

    /// Port number of a URI or host:port string ("tls://[::]:443" → 443).
    static func port(of uri: String) -> Int? {
        var s = uri
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        return Int(s[s.index(after: colon)...])
    }

    /// Finds the public key without root, in order of preference:
    /// 1. the admin API (`getSelf`), when it listens on TCP;
    /// 2. the daemon's startup log ("Your public key is …" followed by
    ///    "Your IPv6 address is …"), accepted only if that address is the live one;
    /// 3. the key read during "Load from /etc/yggdrasil.conf", same address check.
    private func resolvePublicKey(address: String?, admin: String) async {
        guard let address else {
            publicKey = knownKey?.key
            return
        }
        if let k = knownKey, k.address == address {
            publicKey = k.key
            return
        }
        if admin.hasPrefix("tcp://") {
            let r = await Shell.run(Self.ctl, ["-endpoint=\(admin)", "-json", "getSelf"])
            if r.ok, let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
               let key = json["key"] as? String, let addr = json["address"] as? String, addr == address {
                rememberKey(KeyedAddress(key: key, address: addr))
                publicKey = key
                return
            }
        }
        if let k = Self.keyFromLogs(), k.address == address {
            rememberKey(k)
            publicKey = k.key
            return
        }
        publicKey = nil
    }

    /// Last "Your public key is X" / "Your IPv6 address is Y" pair in the logs.
    private static func keyFromLogs() -> KeyedAddress? {
        var found: KeyedAddress?
        for path in logPaths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size < 8 * 1024 * 1024,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            // The log can contain stray non-UTF-8 bytes; decode leniently.
            let text = String(decoding: data, as: UTF8.self)
            var pendingKey: String?
            for line in text.split(separator: "\n") {
                if let r = line.range(of: "Your public key is ") {
                    pendingKey = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                } else if let r = line.range(of: "Your IPv6 address is "), let key = pendingKey {
                    found = KeyedAddress(key: key, address: line[r.upperBound...].trimmingCharacters(in: .whitespaces))
                    pendingKey = nil
                }
            }
        }
        return found
    }

    private func fetchLivePeers(endpoint: String) async -> [LivePeer]? {
        let r = await Shell.run(Self.ctl, ["-endpoint=\(endpoint)", "-json", "getPeers"])
        guard r.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let peers = json["peers"] as? [[String: Any]] else { return nil }
        return peers.map { p in
            let up = p["up"] as? Bool ?? false
            let lastError = (p["last_error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let latencyNs = (p["latency"] as? NSNumber)?.doubleValue
            return LivePeer(
                endpoint: p["remote"] as? String ?? "?",
                state: up ? .up : (lastError == nil ? .connecting : .down),
                kind: (p["inbound"] as? Bool ?? false) ? "inbound" : "outbound",
                overlayAddress: p["address"] as? String,
                rxBytes: (p["bytes_recvd"] as? NSNumber)?.int64Value,
                txBytes: (p["bytes_sent"] as? NSNumber)?.int64Value,
                latencyMs: latencyNs.flatMap { $0 > 0 ? $0 / 1_000_000 : nil },
                lastError: lastError)
        }
    }

    func checkForUpdate() async {
        if let release = try? await GitHub.latestRelease(repo: "yggdrasil-network/yggdrasil-go") {
            runtime.latestRelease = release
        }
    }

    // MARK: Service control

    func start() async {
        await perform("Starting Yggdrasil…") {
            try await Admin.run(daemon.startScript(startAtBoot: !runtime.daemon.disabledAtBoot),
                                reason: "start Yggdrasil")
        }
    }

    func stop() async {
        await perform("Stopping Yggdrasil…") {
            try await Admin.run(daemon.stopScript(), reason: "stop Yggdrasil")
        }
    }

    func restart() async {
        await perform("Restarting Yggdrasil…") {
            try await Admin.run(daemon.restartScript(), reason: "restart Yggdrasil")
        }
    }

    func setStartAtBoot(_ on: Bool) async {
        await perform(on ? "Enabling start at boot…" : "Disabling start at boot…") {
            try await Admin.run(daemon.bootSettingScript(enabled: on), reason: "change Yggdrasil's boot setting")
        }
    }

    // MARK: Configuration

    /// Reads the managed keys from the root-only config. The private key never
    /// leaves the root shell: jq projects only the fields we need.
    func loadFromSystem() async {
        await perform("Reading \(Self.configPath)…") {
            let script = """
            C=\(Self.configPath)
            Y=\(Self.binary)
            /bin/echo "JSON:$("$Y" -useconffile "$C" -normaliseconf -json | /usr/bin/jq -c '{Peers: (.Peers // []), Listen: (.Listen // []), IfName: (.IfName // "auto")}')"
            /bin/echo "ADMIN:$(/usr/bin/sed -n 's/^[[:space:]]*"\\{0,1\\}AdminListen"\\{0,1\\}[[:space:]]*:[[:space:]]*//p' "$C" | /usr/bin/head -1)"
            /bin/echo "KEY:$("$Y" -useconffile "$C" -publickey)"
            /bin/echo "ADDR:$("$Y" -useconffile "$C" -address)"
            """
            let out = try await Admin.run(script, reason: "read the Yggdrasil configuration")
            var fields: [String: String] = [:]
            for line in out.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = String(line[line.index(after: colon)...])
            }
            guard let json = fields["JSON"],
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw AdminError.failed("Unexpected output while reading the config:\n\(out)")
            }
            var s = YggdrasilSettings()
            s.peers = obj["Peers"] as? [String] ?? []
            s.listen = obj["Listen"] as? [String] ?? []
            s.ifName = obj["IfName"] as? String ?? "auto"
            s.adminListen = (fields["ADMIN"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t\",'"))
            remember(s)
            if let key = fields["KEY"]?.trimmingCharacters(in: .whitespaces), key.count == 64,
               let addr = fields["ADDR"]?.trimmingCharacters(in: .whitespaces), !addr.isEmpty {
                rememberKey(KeyedAddress(key: key, address: addr))
            }
        }
    }

    /// Root script that merges `settings` into the existing config (or a fresh
    /// one), validates it with yggdrasil itself, keeps a backup and swaps it in.
    func applyScript(_ settings: YggdrasilSettings) throws -> String {
        var patch: [String: Any] = [
            "Peers": settings.peers,
            "Listen": settings.listen,
            "IfName": settings.ifName.isEmpty ? "auto" : settings.ifName,
        ]
        if !settings.adminListen.isEmpty { patch["AdminListen"] = settings.adminListen }
        let patchData = try JSONSerialization.data(withJSONObject: patch)
        let b64 = patchData.base64EncodedString()
        return """
        umask 077
        C=\(Self.configPath)
        Y=\(Self.binary)
        P="$(/bin/echo \(b64) | /usr/bin/base64 -D)"
        T="$(/usr/bin/mktemp /etc/yggdrasil.conf.new.XXXXXX)"
        trap '/bin/rm -f "$T" "$T.base"' EXIT
        if [ -f "$C" ]; then "$Y" -useconffile "$C" -normaliseconf -json > "$T.base"; else "$Y" -genconf -json > "$T.base"; fi
        /usr/bin/jq --argjson p "$P" '. + $p' "$T.base" > "$T"
        "$Y" -useconffile "$T" -normaliseconf > /dev/null
        if [ -f "$C" ]; then /bin/cp -p "$C" "$C.bak.$(/bin/date +%Y%m%d-%H%M%S)"; fi
        /usr/sbin/chown root:wheel "$T"
        /bin/chmod 640 "$T"
        /bin/mv -f "$T" "$C"
        /bin/ls -1t "$C".bak.* 2>/dev/null | /usr/bin/tail -n +6 | while read -r f; do /bin/rm -f "$f"; done
        """
    }

    func apply() async {
        let settings = draft
        await perform("Applying Yggdrasil configuration…") {
            let script = try applyScript(settings) + "\n" + daemon.restartIfLoadedScript()
            try await Admin.run(script, reason: "update /etc/yggdrasil.conf and restart Yggdrasil")
            remember(settings)
        }
    }

    func revert() {
        if let saved { draft = saved }
    }

    // MARK: Install / update

    func installOrUpdate() async {
        await perform(runtime.isInstalled ? "Updating Yggdrasil…" : "Installing Yggdrasil…") {
            let release = try await GitHub.latestRelease(repo: "yggdrasil-network/yggdrasil-go")
            runtime.latestRelease = release
            let suffix = "-macos-\(GitHub.archToken.go).pkg"
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(suffix) }) else {
                throw GitHubError.noAsset("macOS \(GitHub.archToken.go) .pkg")
            }
            runtime.busy = "Downloading \(asset.name)…"
            let (file, sha) = try await GitHub.download(asset)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            runtime.busy = "Installing Yggdrasil \(release.version)…"

            var script = """
            umask 022
            D="$(/usr/bin/mktemp -d /private/var/tmp/meshprofiler.XXXXXX)"
            trap '/bin/rm -rf "$D"' EXIT
            /bin/cp \(Shell.quote(file.path)) "$D/yggdrasil.pkg"
            /bin/echo "\(sha)  $D/yggdrasil.pkg" | /usr/bin/shasum -a 256 -c - > /dev/null
            /usr/sbin/installer -pkg "$D/yggdrasil.pkg" -target /
            """
            // The pkg's postinstall re-normalises the config, which drops AdminListen.
            // Re-apply our managed settings so nothing the user set is lost.
            if let saved {
                script += "\n(\n" + (try applyScript(saved)) + "\n)\n" + daemon.restartIfLoadedScript()
            }
            try await Admin.run(script, reason: "install Yggdrasil \(release.version)")
        }
    }
}
