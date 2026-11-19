import AppKit
import Foundation
import Observation

/// The system's VPNs (any app's), read-only apart from connect/disconnect.
@MainActor
@Observable
final class VPNModel {
    var services: [VPNService] = []
    /// Mesh check results per VPN id.
    var checks: [String: [MeshCheckItem]] = [:]
    /// Operation in progress per VPN id.
    var busy: [String: String] = [:]
    var lastError: String?
    var lastRefresh: Date?

    private var prefsCache: (date: Date?, configs: [String: NEConfigInfo])?

    func service(_ id: String) -> VPNService? { services.first { $0.id == id } }

    /// Worst open issue for a VPN, if any.
    func worstIssue(_ id: String) -> MeshCheckItem.Severity? {
        checks[id]?.map(\.severity).filter { $0 == .problem || $0 == .warning }
            .min { $0.rawValue < $1.rawValue }
    }

    func refresh(meshes: [MeshContext]) async {
        let entries = await VPNReader.list()

        let date = NEPreferences.modificationDate()
        if prefsCache == nil || prefsCache?.date != date {
            let configs = await Task.detached { NEPreferences.load() }.value
            prefsCache = (date, configs)
        }
        let configs = prefsCache?.configs ?? [:]

        var list: [VPNService] = await withTaskGroup(of: (Int, VPNService).self) { group in
            for (i, e) in entries.enumerated() {
                group.addTask {
                    async let shown = VPNReader.show(e)
                    async let status = VPNReader.status(e.id)
                    let (s, st) = await (shown, status)
                    var v = VPNService(id: e.id, name: e.name, type: e.type, appBundleID: e.appBundleID,
                                       enabled: e.enabled, state: st.state == .unknown ? e.state : st.state,
                                       server: s.server, providerBundleID: s.provider, onDemand: s.onDemand,
                                       vendorSettings: s.vendor)
                    v.rawStatus = st.raw
                    v.addresses = st.addresses
                    v.dnsServers = st.dnsServers
                    v.isPrimary = st.isPrimary
                    v.interface = st.interface
                    return (i, v)
                }
            }
            var out: [(Int, VPNService)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }

        for i in list.indices {
            list[i].flags = configs[list[i].id]?.flags
            list[i].companions = NEPreferences.companions(of: list[i].id, app: list[i].appBundleID, in: configs)
        }

        // Routing and DNS for connected VPNs.
        if list.contains(where: \.isConnected) {
            async let routesResult = VPNReader.routeTable()
            async let ifacesResult = NetworkInspector.interfaces()
            async let resolversResult = VPNReader.resolvers()
            let (routes, ifaces, resolvers) = await (routesResult, ifacesResult, resolversResult)
            let meshTuns = Set(meshes.compactMap(\.tun))
            for i in list.indices where list[i].isConnected {
                let st = VPNReader.Status(state: list[i].state, raw: list[i].rawStatus,
                                          interface: list[i].interface, addresses: list[i].addresses,
                                          dnsServers: list[i].dnsServers, isPrimary: list[i].isPrimary)
                let iface = VPNReader.tunnelInterface(status: st, ifaces: ifaces, routes: routes, exclude: meshTuns)
                list[i].interface = iface
                if list[i].addresses.isEmpty, let iface {
                    list[i].addresses = ifaces.first { $0.name == iface }?.addresses ?? []
                }
                if let iface {
                    list[i].routes = routes.filter { $0.value == iface && !$0.key.cloned }.map(\.key)
                        .sorted { ($0.family, $0.scoped ? 1 : 0, $0.destination) < ($1.family, $1.scoped ? 1 : 0, $1.destination) }
                    list[i].resolvers = resolvers.filter { r in
                        r.interface == iface || r.nameservers.contains { list[i].dnsServers.contains($0) }
                    }
                }
            }
        }

        var newChecks: [String: [MeshCheckItem]] = [:]
        for v in list {
            if v.isConnected {
                newChecks[v.id] = await MeshClashCheck.run(vpn: v, meshes: meshes)
            } else {
                newChecks[v.id] = MeshClashCheck.flagItems(v, connected: false)
            }
        }

        services = list
        checks = newChecks
        lastRefresh = Date()
    }

    func connect(_ id: String, meshes: @escaping () -> [MeshContext]) async {
        await run(id, label: "Connecting…", args: ["--nc", "start", id], meshes: meshes)
    }

    func disconnect(_ id: String, meshes: @escaping () -> [MeshContext]) async {
        await run(id, label: "Disconnecting…", args: ["--nc", "stop", id], meshes: meshes)
    }

    /// `scutil --nc start/stop` — the same switch as System Settings › VPN. No root needed.
    private func run(_ id: String, label: String, args: [String], meshes: () -> [MeshContext]) async {
        guard busy[id] == nil else { return }
        busy[id] = label
        lastError = nil
        let r = await Shell.run("/usr/sbin/scutil", args)
        if !r.ok {
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = "scutil \(args.joined(separator: " ")) failed" + (msg.isEmpty ? "." : ": \(msg)")
        } else {
            // The state changes asynchronously; give it a few seconds to settle.
            let stopping = args.contains("stop")
            var last = VPNState.unknown
            for second in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                last = await VPNReader.status(id).state
                // On-demand VPNs come straight back after a stop: keep watching a little longer.
                if stopping && second < 4 { continue }
                if last == .connected || last == .disconnected || last == .invalid { break }
            }
            if stopping && last != .disconnected {
                let name = service(id).flatMap { owningAppName($0) } ?? "the VPN's own app"
                lastError = "The VPN reconnected right after being stopped. Its \"connect on demand\" is on, which only \(name) can turn off — disconnect it there."
            }
        }
        await refresh(meshes: meshes())
        busy[id] = nil
    }

    /// Opens the app that owns the VPN, when it can be found.
    func openOwningApp(_ v: VPNService) {
        guard let bundle = v.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func owningAppName(_ v: VPNService) -> String? {
        guard let bundle = v.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
