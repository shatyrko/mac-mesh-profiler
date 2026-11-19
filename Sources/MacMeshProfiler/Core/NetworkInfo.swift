import Foundation

/// A socket a daemon is listening on.
struct ListeningSocket: Identifiable, Hashable {
    var id: String { "\(proto)|\(address)|\(port)" }
    /// "TCP" / "UDP"
    var proto: String
    /// "IPv4", "IPv6" or "IPv4+6"
    var family: String
    /// Display address: "all", "127.0.0.1", "fe80::603e:5fff:…" …
    var address: String
    var port: Int
    /// Interface(s) it is bound to, when that can be told.
    var interface: String
    var purpose: String
}

/// An interface a daemon uses, and in what role.
struct InterfaceUse: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var roles: [String]
    var mtu: Int?
    var isUp: Bool
    var addresses: [String]
}

/// An open connection (TCP established, or connected UDP).
struct OpenConnection: Hashable {
    var proto: String          // "TCP" / "UDP"
    var localAddress: String
    var localPort: Int
    /// As netstat prints it: long IPv6 addresses may be cut short.
    var remoteAddress: String
    var remotePort: Int
    var rxBytes: Int64?
    var txBytes: Int64?
}

struct NetworkSnapshot: Equatable {
    var connections: [OpenConnection] = []
    var listening: [ListeningSocket] = []
    var interfaces: [InterfaceUse] = []
    var unixSockets: [String] = []
    var establishedCount = 0
}

/// Reads sockets and interfaces without root: `netstat -anv` tags every socket
/// with `process:pid`, and `ifconfig` is world-readable.
enum NetworkInspector {
    struct Iface {
        var name: String
        var isUp: Bool
        var mtu: Int?
        var addresses: [String]   // without %scope
    }

    static func interfaces() async -> [Iface] {
        let r = await Shell.run("/sbin/ifconfig")
        var out: [Iface] = []
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                var iface = Iface(name: String(line[..<colon]), isUp: line.contains("<UP"), mtu: nil, addresses: [])
                if let m = line.range(of: "mtu ") {
                    iface.mtu = Int(line[m.upperBound...].prefix { $0.isNumber })
                }
                out.append(iface)
                continue
            }
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count >= 2, parts[0] == "inet" || parts[0] == "inet6", !out.isEmpty {
                let addr = String(parts[1].split(separator: "%").first ?? "")
                out[out.count - 1].addresses.append(addr)
            }
        }
        return out
    }

    /// - Parameters:
    ///   - process: executable name as netstat prints it ("yggdrasil", "mycelium").
    ///   - tun: the daemon's TUN interface, if known.
    ///   - purpose: labels a listening socket (proto, port, is link-local).
    static func snapshot(process: String, pid: Int, tun: String?,
                         purpose: (_ proto: String, _ port: Int, _ linkLocal: Bool) -> String) async -> NetworkSnapshot {
        async let netstat = Shell.run("/usr/sbin/netstat", ["-anv"])
        async let ifacesResult = interfaces()
        let (ns, ifaces) = await (netstat, ifacesResult)

        let tag = "\(process):\(pid)"
        var snap = NetworkSnapshot()
        var roles: [String: [String]] = [:]
        func addRole(_ iface: String, _ role: String) {
            if !(roles[iface]?.contains(role) ?? false) { roles[iface, default: []].append(role) }
        }
        if let tun { addRole(tun, "Overlay (TUN)") }

        for raw in ns.stdout.split(separator: "\n") {
            let tokens = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.contains(tag), let protoToken = tokens.first else { continue }

            if !protoToken.hasPrefix("tcp") && !protoToken.hasPrefix("udp") {
                // Unix domain socket: path is the last token when present.
                if let path = tokens.last, path.hasPrefix("/"), !snap.unixSockets.contains(path) {
                    snap.unixSockets.append(path)
                }
                continue
            }
            guard tokens.count >= 5 else { continue }
            let isTCP = protoToken.hasPrefix("tcp")
            let state = isTCP && tokens.count > 5 ? tokens[5] : ""
            let (localAddr, localPort) = splitAddress(tokens[3])

            let (remoteAddr, remotePort) = splitAddress(tokens[4])
            let connected = isTCP ? state == "ESTABLISHED" : (remotePort != nil && remoteAddr != "*")
            if connected, let lp = localPort, let rp = remotePort {
                // Byte counters follow the state column (TCP) or the foreign address (UDP).
                let rxIndex = isTCP ? 6 : 5
                snap.connections.append(OpenConnection(
                    proto: isTCP ? "TCP" : "UDP", localAddress: localAddr, localPort: lp,
                    remoteAddress: remoteAddr, remotePort: rp,
                    rxBytes: tokens.count > rxIndex ? Int64(tokens[rxIndex]) : nil,
                    txBytes: tokens.count > rxIndex + 1 ? Int64(tokens[rxIndex + 1]) : nil))
                if isTCP { snap.establishedCount += 1 }
                for name in interfacesFor(localAddr, in: ifaces) { addRole(name, "Peering traffic") }
                continue
            }
            let listening = isTCP ? state == "LISTEN" : localPort != nil
            guard listening, let port = localPort else { continue }

            let linkLocal = localAddr.lowercased().hasPrefix("fe80:")
            let names = interfacesFor(localAddr, in: ifaces)
            let label = purpose(isTCP ? "TCP" : "UDP", port, linkLocal)
            for name in names where name != "all" { addRole(name, label) }
            let family: String
            switch protoToken.dropFirst(3) {
            case "4": family = "IPv4"
            case "6": family = "IPv6"
            default: family = "IPv4+6"
            }
            let socket = ListeningSocket(
                proto: isTCP ? "TCP" : "UDP", family: family,
                address: localAddr == "*" ? "all" : (linkLocal ? localAddr + "…" : localAddr),
                port: port,
                interface: names.joined(separator: ", "),
                purpose: label)
            if !snap.listening.contains(socket) { snap.listening.append(socket) }
        }
        snap.listening.sort { ($0.port, $0.proto, $0.address) < ($1.port, $1.proto, $1.address) }

        let byName = Dictionary(ifaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        snap.interfaces = roles.keys.sorted { a, b in
            // TUN first, then by name.
            if a == tun { return true }
            if b == tun { return false }
            return a < b
        }.map { name in
            let i = byName[name]
            return InterfaceUse(name: name, roles: roles[name] ?? [], mtu: i?.mtu,
                                isUp: i?.isUp ?? false, addresses: i?.addresses ?? [])
        }
        return snap
    }

    /// Whether a netstat-printed address (possibly cut short) is `full`.
    static func addressMatches(netstat: String, full: String) -> Bool {
        let n = netstat.lowercased(), f = full.lowercased()
        if n == f { return true }
        // Truncated IPv6: netstat keeps a prefix, typically ending in ":".
        return n.contains(":") && n.count >= 6 && f.hasPrefix(n)
    }

    /// Numeric addresses for a host (IP literals pass through). Blocking; call off the main thread.
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [host] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf).split(separator: "%").first.map(String.init) ?? ""
                if !s.isEmpty, !out.contains(s) { out.append(s) }
            }
            cursor = ai.pointee.ai_next
        }
        return out.isEmpty ? [host] : out
    }

    /// netstat prints "addr.port"; the port follows the last dot. "*.*" has no port.
    static func splitAddress(_ s: String) -> (String, Int?) {
        guard let dot = s.lastIndex(of: ".") else { return (s, nil) }
        let addr = String(s[..<dot])
        let port = Int(s[s.index(after: dot)...])
        return (addr, port)
    }

    /// Interfaces a local address belongs to. netstat truncates long IPv6
    /// addresses, so link-local ones are matched by prefix against ifconfig.
    static func interfacesFor(_ address: String, in ifaces: [Iface]) -> [String] {
        if address == "*" { return ["all"] }
        if address == "127.0.0.1" || address == "::1" { return ["lo0"] }
        let addr = address.lowercased()
        var names: [String] = []
        for i in ifaces {
            let hit = i.addresses.contains { a in
                let candidate = a.lowercased()
                return candidate == addr || (addr.contains(":") && addr.count >= 8 && candidate.hasPrefix(addr))
            }
            if hit { names.append(i.name) }
        }
        return names
    }
}
