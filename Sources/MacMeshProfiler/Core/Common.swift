import Foundation

enum PeerState: String {
    case up, connecting, down, unknown
}

/// A peer as reported live by a running daemon.
struct LivePeer: Identifiable, Hashable {
    var id: String { endpoint + "|" + kind }
    /// Connection URI, e.g. `tls://1.2.3.4:443` or `tcp://188.40.132.242:9651`.
    var endpoint: String
    var state: PeerState
    /// static / inbound / discovered …
    var kind: String
    var overlayAddress: String?
    var rxBytes: Int64?
    var txBytes: Int64?
    var latencyMs: Double?
    var lastError: String?
}

enum OverlayNetwork {
    case yggdrasil  // 200::/7
    case mycelium   // 400::/7

    func contains(_ address: String) -> Bool {
        guard let first = address.split(separator: ":").first, let v = Int(first, radix: 16) else { return false }
        switch self {
        case .yggdrasil: return (0x200...0x3ff).contains(v)
        case .mycelium: return (0x400...0x5ff).contains(v)
        }
    }
}

struct InterfaceAddress: Equatable {
    var interface: String
    var address: String
}

enum Interfaces {
    /// Finds the overlay address of a mesh by scanning `ifconfig` (no root needed).
    static func overlayAddress(_ net: OverlayNetwork) async -> InterfaceAddress? {
        let r = await Shell.run("/sbin/ifconfig")
        var current = ""
        for raw in r.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                current = String(line[..<colon])
                continue
            }
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if parts.count >= 2, parts[0] == "inet6" {
                let addr = String(parts[1].split(separator: "%").first ?? "")
                if net.contains(addr) { return InterfaceAddress(interface: current, address: addr) }
            }
        }
        return nil
    }

    static func names() async -> Set<String> {
        let r = await Shell.run("/sbin/ifconfig", ["-l"])
        return Set(r.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    /// First `utunN` (N ≥ start) not currently present.
    static func freeUtun(startingAt start: Int = 20) async -> String {
        let used = await names()
        var n = start
        while used.contains("utun\(n)") { n += 1 }
        return "utun\(n)"
    }
}

struct PeerURI: Equatable {
    var scheme: String
    var host: String
    var port: Int

    /// "tls://[2a01::1]:443?key=…" → (tls, 2a01::1, 443). nil if there is no host:port.
    init?(_ uri: String) {
        guard let sep = uri.range(of: "://") else { return nil }
        scheme = uri[..<sep.lowerBound].lowercased()
        var rest = String(uri[sep.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "/" }) { rest = String(rest[..<cut]) }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            guard after.hasPrefix(":"), let p = Int(after.dropFirst()) else { return nil }
            port = p
        } else {
            guard let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) else { return nil }
            host = String(rest[..<colon])
            port = p
        }
        if host.isEmpty { return nil }
    }

    /// Transport the scheme rides on (QUIC is UDP; socks/unix are not matchable).
    var transport: String? {
        switch scheme {
        case "tcp", "tls", "ws", "wss": return "TCP"
        case "quic": return "UDP"
        default: return nil
        }
    }
}

enum PeerText {
    /// Pulls every `scheme://…` token out of pasted text (markdown lists, comma lists, …).
    static func extract(from text: String, schemes: [String]) -> [String] {
        let pattern = "(?:" + schemes.joined(separator: "|") + ")://[^\\s`'\",<>()]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".;]".contains(last) { s.removeLast() }
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    static func isValid(_ uri: String, schemes: [String]) -> Bool {
        guard let range = uri.range(of: "://") else { return false }
        let scheme = uri[..<range.lowerBound].lowercased()
        let rest = uri[range.upperBound...]
        return schemes.contains(scheme) && !rest.isEmpty && !rest.contains(" ")
    }
}

func formatBytes(_ n: Int64?) -> String {
    guard let n else { return "—" }
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

/// Reads the last `maxLines` lines of a (possibly large) text file.
func tailFile(_ path: String, maxLines: Int = 300) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let chunk: UInt64 = 256 * 1024
    try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(maxLines).joined(separator: "\n")
}
