import Foundation

/// What the VPN check needs to know about one mesh network.
struct MeshContext: Sendable {
    var name: String
    var running: Bool
    /// The mesh's own TUN interface while running.
    var tun: String?
    /// An address inside the overlay range, used to look up its route.
    var probe: String
    var overlayRange: String
    var configuredPeers: [String]
    /// Configured peers currently up, when live status is known.
    var peersUp: Int?
}

struct MeshCheckItem: Identifiable, Equatable {
    enum Severity: Int { case problem, warning, info, ok }
    var id: String { title }
    var severity: Severity
    var title: String
    var detail: String
}

/// Checks whether a VPN gets in the way of Yggdrasil and Mycelium.
///
/// Uses the routing table (`route -n get`) plus the VPN's Network Extension flags.
/// The routing table doesn't show per-app or per-flow rules (Network Extension
/// policies, transparent proxies), so results are labelled accordingly.
enum MeshClashCheck {
    /// Interface the kernel picks for `ip`, from `route -n get`.
    static func routeInterface(_ ip: String) async -> String? {
        let args = IPAddress.isIPv6(ip) ? ["-n", "get", "-inet6", ip] : ["-n", "get", ip]
        let r = await Shell.run("/sbin/route", args)
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Checks that need the VPN connected.
    static func run(vpn: VPNService, meshes: [MeshContext]) async -> [MeshCheckItem] {
        var items: [MeshCheckItem] = []
        items.append(contentsOf: flagItems(vpn, connected: true))

        let running = meshes.filter(\.running)
        if running.isEmpty {
            items.append(MeshCheckItem(severity: .info, title: "No mesh is running",
                                       detail: "Start Yggdrasil or Mycelium to check their routes and peers."))
            return items
        }

        for mesh in running {
            // 1. Overlay route.
            let iface = await routeInterface(mesh.probe)
            if let iface, iface == vpn.interface {
                items.append(MeshCheckItem(
                    severity: .problem,
                    title: "\(mesh.name) overlay is routed into \(vpn.name)",
                    detail: "Traffic for \(mesh.overlayRange) goes to \(iface) instead of \(mesh.tun ?? "the mesh's TUN"), so \(mesh.name) addresses are unreachable while the VPN is connected."))
            } else if let iface, mesh.tun == nil || iface == mesh.tun {
                items.append(MeshCheckItem(
                    severity: .ok,
                    title: "\(mesh.name) overlay route is intact",
                    detail: "\(mesh.overlayRange) → \(iface) (routing table)."))
            } else {
                items.append(MeshCheckItem(
                    severity: .warning,
                    title: "\(mesh.name) overlay route points elsewhere",
                    detail: "\(mesh.overlayRange) → \(iface ?? "no route"), expected \(mesh.tun ?? "the mesh's TUN")."))
            }

            // 2. Where peering traffic goes.
            items.append(contentsOf: await peerItems(vpn: vpn, mesh: mesh))

            // 3. Live peer health.
            if let up = mesh.peersUp, !mesh.configuredPeers.isEmpty, up == 0 {
                items.append(MeshCheckItem(
                    severity: .warning,
                    title: "No \(mesh.name) peers are connected",
                    detail: "None of the \(mesh.configuredPeers.count) configured peers is up while \(vpn.name) is connected. Disconnect the VPN briefly to see whether it's the cause."))
            }
        }
        return items
    }

    /// What can be said from the stored settings alone.
    static func flagItems(_ vpn: VPNService, connected: Bool) -> [MeshCheckItem] {
        if vpn.type == "WireGuard" {
            return [MeshCheckItem(severity: .ok, title: "No kill switch",
                                  detail: "wg-quick only adds routes for the peers' AllowedIPs, so traffic follows the routing table and more specific routes like the mesh TUNs keep working.")]
        }
        guard let flags = vpn.flags, let all = flags.includeAllNetworks else {
            return [MeshCheckItem(severity: .info, title: "VPN settings unknown",
                                  detail: "macOS's stored settings for this VPN couldn't be read, so only the routing table is checked.")]
        }
        if all {
            var detail = "macOS's \"include all networks\" option is on, the usual way a VPN kill switch is built. All traffic is forced into the VPN regardless of routes, so Yggdrasil and Mycelium overlay traffic most likely stops working while connected (expected from Apple's documentation, not tested here)."
            if flags.excludeLocalNetworks == true {
                detail += " Local networks are exempt, so LAN peers and multicast discovery should keep working."
            }
            return [MeshCheckItem(severity: connected ? .problem : .warning,
                                  title: connected ? "All traffic is forced through \(vpn.name)"
                                                   : "When connected, all traffic will be forced through \(vpn.name)",
                                  detail: detail)]
        }
        return [MeshCheckItem(severity: .ok, title: "Other tunnels are left alone",
                              detail: "\"Include all networks\" is off, so traffic follows the routing table and the mesh TUN routes keep working.")]
    }

    private static func peerItems(vpn: VPNService, mesh: MeshContext) async -> [MeshCheckItem] {
        let hosts = mesh.configuredPeers.compactMap { PeerURI($0)?.host }
        guard !hosts.isEmpty else { return [] }

        let resolved: [(host: String, ips: [String])] = await Task.detached {
            hosts.map { h in (h, NetworkInspector.resolve(h).filter { IPAddress.bytes($0) != nil }) }
        }.value

        var viaVPNPrivate: [String] = []
        var viaVPNPublic: [String] = []
        var direct: [String: Set<String>] = [:]   // interface → hosts
        var excludedBySplit: [String] = []
        var unresolved: [String] = []

        for (host, ips) in resolved {
            guard let ip = ips.first else { unresolved.append(host); continue }
            let label = host == ip ? ip : "\(host) (\(ip))"
            if vpn.excludedIPs.contains(where: { IPAddress.contains(cidr: $0, ip) }) {
                excludedBySplit.append(label)
                continue
            }
            let iface = await routeInterface(ip)
            if let iface, iface == vpn.interface {
                if IPAddress.isPrivate(ip) { viaVPNPrivate.append(label) } else { viaVPNPublic.append(label) }
            } else {
                direct[iface ?? "no route", default: []].insert(label)
            }
        }

        var items: [MeshCheckItem] = []
        let total = resolved.count
        if !viaVPNPrivate.isEmpty {
            items.append(MeshCheckItem(
                severity: .warning,
                title: "\(viaVPNPrivate.count) \(mesh.name) peer\(viaVPNPrivate.count == 1 ? "" : "s") on private addresses \(viaVPNPrivate.count == 1 ? "is" : "are") routed into \(vpn.name)",
                detail: viaVPNPrivate.joined(separator: ", ") + ". The VPN server can't reach your private networks, so these most likely can't connect. Exclude them in the VPN's split tunnelling, or disconnect it."))
        }
        if !viaVPNPublic.isEmpty {
            items.append(MeshCheckItem(
                severity: .info,
                title: "\(viaVPNPublic.count) of \(total) \(mesh.name) peers are reached through \(vpn.name)",
                detail: viaVPNPublic.joined(separator: ", ") + ". This works, but adds latency, and these peers see the VPN's exit address instead of yours."))
        }
        if viaVPNPrivate.isEmpty && viaVPNPublic.isEmpty {
            items.append(MeshCheckItem(
                severity: .ok,
                title: "\(mesh.name) peers bypass \(vpn.name)",
                detail: direct.isEmpty ? "All peers are excluded by split tunnelling."
                    : direct.sorted { $0.key < $1.key }
                        .map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
                        .joined(separator: "\n")))
        }
        if !excludedBySplit.isEmpty {
            items.append(MeshCheckItem(
                severity: .ok,
                title: "\(excludedBySplit.count) \(mesh.name) peer\(excludedBySplit.count == 1 ? "" : "s") excluded by split tunnelling",
                detail: excludedBySplit.joined(separator: ", ")))
        }
        if !unresolved.isEmpty {
            items.append(MeshCheckItem(
                severity: .info,
                title: "Couldn't resolve \(unresolved.count) \(mesh.name) peer host\(unresolved.count == 1 ? "" : "s")",
                detail: unresolved.joined(separator: ", ")))
        }
        return items
    }
}
