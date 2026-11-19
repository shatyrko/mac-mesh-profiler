import Foundation

/// A WireGuard peer, as configured (no preshared key).
struct WGPeerSummary: Codable, Hashable {
    var publicKey: String
    var endpoint: String?
    var allowedIPs: [String]
    var keepalive: Int?
}

/// What the app keeps of a wg-quick config: everything except the private and
/// preshared keys, which stay in the root-only file under /etc/wireguard.
struct WGConfigSummary: Codable, Equatable {
    var addresses: [String] = []
    var dns: [String] = []
    var mtu: Int?
    var listenPort: Int?
    /// Derived from the private key with `wg pubkey` (as root), when available.
    var publicKey: String?
    var table: String?
    /// PreUp/PostUp/PreDown/PostDown commands: wg-quick runs these as root.
    var hooks: [String] = []
    var peers: [WGPeerSummary] = []

    /// Interface addresses without the prefix length.
    var bareAddresses: [String] { addresses.map { String($0.split(separator: "/").first ?? "") } }
    /// DNS entries that are IP addresses (the rest are search domains).
    var dnsServers: [String] { dns.filter { IPAddress.bytes($0) != nil } }
    var isFullTunnel: Bool {
        peers.contains { $0.allowedIPs.contains("0.0.0.0/0") || $0.allowedIPs.contains("::/0") }
    }
}

/// Live per-peer numbers from `wg show all dump` (needs root).
struct WGPeerStats: Hashable {
    var publicKey: String
    var endpoint: String?
    /// nil = never.
    var latestHandshake: Date?
    var rxBytes: Int64
    var txBytes: Int64
}

enum WireGuardConfig {
    /// wg-quick interface names: 1–15 of [a-zA-Z0-9_=+.-].
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9_=+.-]{1,15}$"#, options: .regularExpression) != nil
    }

    static func sanitizedName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=+.-")
        let s = String(name.map { allowed.contains($0) ? $0 : "-" }.prefix(15))
        return s.isEmpty ? "wg0" : s
    }

    struct Parsed {
        var summary: WGConfigSummary
        var hasPrivateKey: Bool
    }

    /// Parses a wg-quick config. Key material is recognised but never stored.
    static func parse(_ text: String) -> Parsed {
        var summary = WGConfigSummary()
        var hasPrivateKey = false
        var section = ""
        var peer: WGPeerSummary?

        func list(_ v: String) -> [String] {
            v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func flushPeer() {
            if let p = peer { summary.peers.append(p) }
            peer = nil
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                flushPeer()
                section = line.lowercased()
                if section == "[peer]" { peer = WGPeerSummary(publicKey: "", endpoint: nil, allowedIPs: []) }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if section == "[interface]" {
                switch key {
                case "privatekey": hasPrivateKey = !value.isEmpty
                case "address": summary.addresses += list(value)
                case "dns": summary.dns += list(value)
                case "mtu": summary.mtu = Int(value)
                case "listenport": summary.listenPort = Int(value)
                case "table": summary.table = value
                case "preup", "postup", "predown", "postdown":
                    summary.hooks.append("\(line[..<eq].trimmingCharacters(in: .whitespaces)) = \(value)")
                default: break
                }
            } else if section == "[peer]" {
                switch key {
                case "publickey": peer?.publicKey = value
                case "endpoint": peer?.endpoint = value
                case "allowedips": peer?.allowedIPs += list(value)
                case "persistentkeepalive": peer?.keepalive = Int(value)
                default: break   // PresharedKey is skipped on purpose
                }
            }
        }
        flushPeer()
        return Parsed(summary: summary, hasPrivateKey: hasPrivateKey)
    }

    // MARK: Root scripts

    static let directory = "/etc/wireguard"

    /// wg-quick needs Homebrew's bash 4+, wg and wireguard-go on PATH.
    static let pathExport = "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Prints every config in /etc/wireguard without its key lines:
    /// `== name`, then `PUB:<public key>`, then the remaining lines.
    static let dumpScript = """
    \(pathExport)
    for f in \(directory)/*.conf; do
      [ -f "$f" ] || continue
      n=$(/usr/bin/basename "$f" .conf)
      /bin/echo "== $n"
      k=$(/usr/bin/sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$f" | /usr/bin/head -1)
      if [ -n "$k" ] && command -v wg >/dev/null 2>&1; then
        /bin/echo "PUB:$(printf '%s' "$k" | wg pubkey)"
      fi
      /usr/bin/sed -E '/^[[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=/d' "$f"
    done
    """

    static func parseDump(_ text: String) -> [String: WGConfigSummary] {
        var out: [String: WGConfigSummary] = [:]
        var name: String?
        var publicKey: String?
        var lines: [String] = []
        func flush() {
            guard let n = name else { return }
            var s = parse(lines.joined(separator: "\n")).summary
            s.publicKey = publicKey
            out[n] = s
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("== ") {
                flush()
                name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                publicKey = nil
                lines = []
            } else if line.hasPrefix("PUB:") {
                publicKey = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return out
    }

    /// Copies a config into /etc/wireguard (root:wheel 600). The directory is
    /// kept 755 so the app can list tunnel names without a password.
    static func importScript(source: String, name: String) -> String {
        """
        /usr/bin/install -d -m 755 -o root -g wheel \(directory)
        /bin/chmod 755 \(directory)
        /usr/bin/install -m 600 -o root -g wheel \(Shell.quote(source)) \(directory)/\(name).conf
        \(dumpScript)
        """
    }

    /// Runs wg-quick with its output captured in a file: wg-quick leaves a
    /// background monitor running, which would otherwise hold the prompt open.
    static func wgQuickScript(_ action: String, name: String) -> String {
        """
        \(pathExport)
        out=$(/usr/bin/mktemp /private/var/tmp/wgquick.XXXXXX)
        if wg-quick \(action) \(Shell.quote(name)) >"$out" 2>&1 </dev/null; then rc=0; else rc=$?; fi
        /bin/cat "$out"
        /bin/rm -f "$out"
        exit $rc
        """
    }

    static func removeScript(name: String, running: Bool) -> String {
        (running ? wgQuickScript("down", name: name).replacingOccurrences(of: "exit $rc", with: "") + "\n" : "")
            + "/bin/rm -f \(directory)/\(name).conf\n"
    }

    /// Live stats without key material: `N name utun`, `P utun pubkey endpoint allowed handshake rx tx keepalive`.
    static let statsScript = """
    \(pathExport)
    for f in /var/run/wireguard/*.name; do
      [ -f "$f" ] || continue
      /usr/bin/printf 'N\\t%s\\t%s\\n' "$(/usr/bin/basename "$f" .name)" "$(/bin/cat "$f")"
    done
    wg show all dump | /usr/bin/awk -F'\\t' 'NF==9 {print "P\\t"$1"\\t"$2"\\t"$4"\\t"$5"\\t"$6"\\t"$7"\\t"$8"\\t"$9}'
    """

    static func parseStats(_ text: String) -> (names: [String: String], peers: [String: [WGPeerStats]]) {
        var names: [String: String] = [:]
        var peers: [String: [WGPeerStats]] = [:]
        for raw in text.split(separator: "\n") {
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "N", f.count >= 3 {
                names[f[1]] = f[2].trimmingCharacters(in: .whitespacesAndNewlines)
            } else if f.first == "P", f.count >= 9 {
                let hs = TimeInterval(f[5]) ?? 0
                peers[f[1], default: []].append(WGPeerStats(
                    publicKey: f[2],
                    endpoint: f[3] == "(none)" ? nil : f[3],
                    latestHandshake: hs > 0 ? Date(timeIntervalSince1970: hs) : nil,
                    rxBytes: Int64(f[6]) ?? 0, txBytes: Int64(f[7]) ?? 0))
            }
        }
        return (names, peers)
    }
}
