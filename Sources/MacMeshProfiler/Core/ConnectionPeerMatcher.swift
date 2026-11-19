import Foundation

/// Peer up/down without any daemon API: a configured peer is up when the
/// daemon has an established connection to its address and port (netstat).
/// Used for Yggdrasil when its admin API is off, and for Mycelium when its
/// HTTP API can't be reached.
@MainActor
final class ConnectionPeerMatcher {
    /// Host → resolved addresses, refreshed at most once a minute.
    private var resolvedHosts: [String: (addresses: [String], at: Date)] = [:]

    private func addresses(for host: String) async -> [String] {
        if let cached = resolvedHosts[host], Date().timeIntervalSince(cached.at) < 60 { return cached.addresses }
        let addrs = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: NetworkInspector.resolve(host)) }
        }
        resolvedHosts[host] = (addrs, Date())
        return addrs
    }

    /// Up/down for each configured peer from netstat: a peer is up when the
    /// daemon has an established connection to its address and port. Other
    /// connections (inbound, LAN multicast peers) are returned as extra entries.
    func peers(configured: [String], network: NetworkSnapshot) async -> [LivePeer] {
        var used = Set<Int>()
        var result: [LivePeer] = []
        for peer in configured {
            guard let uri = PeerURI(peer), let transport = uri.transport else {
                result.append(LivePeer(endpoint: peer, state: .unknown, kind: "outbound"))
                continue
            }
            let addrs = await addresses(for: uri.host)
            let match = network.connections.indices.first { i in
                let c = network.connections[i]
                return !used.contains(i) && c.proto == transport && c.remotePort == uri.port
                    && addrs.contains { NetworkInspector.addressMatches(netstat: c.remoteAddress, full: $0) }
            }
            if let i = match {
                used.insert(i)
                let c = network.connections[i]
                result.append(LivePeer(endpoint: peer, state: .up, kind: "outbound",
                                       rxBytes: c.rxBytes, txBytes: c.txBytes))
            } else {
                // QUIC runs over unconnected UDP sockets, so absence proves nothing there.
                result.append(LivePeer(endpoint: peer, state: transport == "UDP" ? .unknown : .down,
                                       kind: "outbound",
                                       lastError: transport == "UDP" ? nil : "no open connection"))
            }
        }
        let listeningPorts = Set(network.listening.map(\.port))
        for (i, c) in network.connections.enumerated() where !used.contains(i) && c.proto == "TCP" {
            let host = c.remoteAddress.contains(":") ? "[\(c.remoteAddress)]" : c.remoteAddress
            let kind = listeningPorts.contains(c.localPort) ? "inbound"
                : (c.remoteAddress.lowercased().hasPrefix("fe80:") ? "LAN (multicast)" : "outbound")
            result.append(LivePeer(endpoint: "tcp://\(host):\(c.remotePort)", state: .up, kind: kind,
                                   rxBytes: c.rxBytes, txBytes: c.txBytes))
        }
        return result
    }
}
