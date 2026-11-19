import Foundation

/// The subset of mycelium.toml this app edits. Keys it doesn't know about are
/// kept verbatim (`extra`) so hand-made additions survive an apply.
struct MyceliumSettings: Equatable {
    var peers: [String] = []
    var tunName: String = ""
    var tcpListenPort: Int = 9651
    var quicListenPort: Int = 9651
    var disableQuic = false
    var disablePeerDiscovery = false
    var apiAddr = "127.0.0.1:8989"
    var extra: [ExtraEntry] = []

    struct ExtraEntry: Equatable {
        var key: String
        var rawValue: String
    }

    /// Address the app uses to talk to the HTTP API (wildcards → loopback).
    var apiBaseURL: URL? {
        var addr = apiAddr
        if addr.hasPrefix("0.0.0.0:") { addr = "127.0.0.1:" + addr.dropFirst("0.0.0.0:".count) }
        if addr.hasPrefix("[::]:") { addr = "[::1]:" + addr.dropFirst("[::]:".count) }
        return URL(string: "http://\(addr)")
    }
}

enum MyceliumPublicNodes {
    struct Node {
        let id: String
        let region: String
        let ipv4: String
        let ipv6: String
    }

    /// Hosted public nodes from the Mycelium README (v0.6.x+ network).
    static let all: [Node] = [
        Node(id: "01", region: "DE", ipv4: "188.40.132.242", ipv6: "2a01:4f8:221:1e0b::2"),
        Node(id: "02", region: "DE", ipv4: "136.243.47.186", ipv6: "2a01:4f8:212:fa6::2"),
        Node(id: "03", region: "BE", ipv4: "185.69.166.7", ipv6: "2a02:1802:5e:0:ec4:7aff:fe51:e80d"),
        Node(id: "04", region: "BE", ipv4: "185.69.166.8", ipv6: "2a02:1802:5e:0:ec4:7aff:fe51:e36b"),
        Node(id: "05", region: "FI", ipv4: "65.21.231.58", ipv6: "2a01:4f9:6a:1dc5::2"),
        Node(id: "06", region: "FI", ipv4: "65.109.18.113", ipv6: "2a01:4f9:5a:1042::2"),
        Node(id: "07", region: "US-EAST", ipv4: "209.159.146.190", ipv6: "2604:a00:50:17b:9e6b:ff:fe1f:e054"),
        Node(id: "08", region: "US-WEST", ipv4: "5.78.122.16", ipv6: "2a01:4ff:1f0:8859::1"),
        Node(id: "09", region: "SG", ipv4: "5.223.43.251", ipv6: "2a01:4ff:2f0:3621::1"),
        Node(id: "10", region: "IND", ipv4: "142.93.217.194", ipv6: "2400:6180:100:d0::841:2001"),
    ]

    static func uris(proto: String, ipv6: Bool) -> [String] {
        all.map { "\(proto)://" + (ipv6 ? "[\($0.ipv6)]" : $0.ipv4) + ":9651" }
    }
}

enum MyceliumConfigFile {
    // MARK: Parse

    static func parse(_ text: String) -> MyceliumSettings {
        var s = MyceliumSettings()
        for (key, raw) in statements(text) {
            switch key {
            case "peers": s.peers = stringArray(raw)
            case "tun_name": s.tunName = string(raw) ?? s.tunName
            case "tcp_listen_port": s.tcpListenPort = Int(raw) ?? s.tcpListenPort
            case "quic_listen_port": s.quicListenPort = Int(raw) ?? s.quicListenPort
            case "disable_quic": s.disableQuic = raw == "true"
            case "disable_peer_discovery": s.disablePeerDiscovery = raw == "true"
            case "api_addr": s.apiAddr = string(raw) ?? s.apiAddr
            default: s.extra.append(.init(key: key, rawValue: raw))
            }
        }
        return s
    }

    /// Splits TOML text into top-level `key = value` statements, ignoring
    /// comments and joining multi-line arrays. Good enough for mycelium.toml,
    /// which has no tables.
    static func statements(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var current = ""
        var inString = false
        var escaped = false
        var depth = 0
        var inComment = false

        func flush() {
            let stmt = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard let eq = stmt.firstIndex(of: "=") else { return }
            let key = stmt[..<eq].trimmingCharacters(in: .whitespaces)
            let value = stmt[stmt.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !key.hasPrefix("[") { result.append((key, value)) }
        }

        for ch in text {
            if inComment {
                if ch == "\n" { inComment = false } else { continue }
            }
            if inString {
                current.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "#": inComment = true
            case "\"": inString = true; current.append(ch)
            case "[": depth += 1; current.append(ch)
            case "]": depth = max(0, depth - 1); current.append(ch)
            case "\n":
                if depth == 0 { flush() } else { current.append(" ") }
            default: current.append(ch)
            }
        }
        flush()
        return result
    }

    static func string(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }
        return unescape(String(raw.dropFirst().dropLast()))
    }

    static func stringArray(_ raw: String) -> [String] {
        // Collect every "…" literal inside the brackets.
        var out: [String] = []
        var cur = ""
        var inString = false
        var escaped = false
        for ch in raw {
            if inString {
                if escaped { cur.append(ch); escaped = false }
                else if ch == "\\" { cur.append(ch); escaped = true }
                else if ch == "\"" { out.append(unescape(cur)); cur = ""; inString = false }
                else { cur.append(ch) }
            } else if ch == "\"" {
                inString = true
            }
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Render

    static func render(_ s: MyceliumSettings) -> String {
        var lines = [
            "# Managed by Mac Mesh Profiler. Unknown keys are preserved.",
            "",
            "peers = [",
        ]
        lines += s.peers.map { "  \(quote($0))," }
        lines += [
            "]",
            "tun_name = \(quote(s.tunName))",
            "tcp_listen_port = \(s.tcpListenPort)",
            "quic_listen_port = \(s.quicListenPort)",
            "disable_quic = \(s.disableQuic)",
            "disable_peer_discovery = \(s.disablePeerDiscovery)",
            "api_addr = \(quote(s.apiAddr))",
        ]
        lines += s.extra.map { "\($0.key) = \($0.rawValue)" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func launchdPlist(label: String, binary: String, config: String, key: String,
                             workingDir: String, log: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>--config-file</string>
                <string>\(config)</string>
                <string>--key-file</string>
                <string>\(key)</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(workingDir)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
            <key>StandardOutPath</key>
            <string>\(log)</string>
            <key>StandardErrorPath</key>
            <string>\(log)</string>
        </dict>
        </plist>

        """
    }
}
