import Foundation

// Read-only view of the VPNs macOS knows about (System Settings › VPN).
//
// Everything here works without root:
// - `scutil --nc list/show/status` for the list, server and live status;
// - /Library/Preferences/com.apple.networkextension.plist (world-readable) for
//   the Network Extension flags (include all networks, exclude local networks …)
//   and companion configurations such as a split-tunnelling proxy. Only those
//   flags and the vendor settings are read; password and identity fields are not;
// - `netstat -rn` and `scutil --dns` for what a connected VPN does to routing and DNS.
//
// A VPN app's own settings (server choice, account, keys) live in its sandbox
// and Keychain and are not touched.

enum VPNState: String {
    case connected, connecting, disconnecting, disconnected, invalid, unknown

    init(scutil word: String) {
        switch word.lowercased() {
        case "connected": self = .connected
        case "connecting": self = .connecting
        case "disconnecting": self = .disconnecting
        case "disconnected": self = .disconnected
        case "invalid": self = .invalid
        default: self = .unknown
        }
    }

    var title: String { rawValue.capitalized }
}

struct KeyValue: Hashable, Identifiable {
    var id: String { key }
    var key: String
    var value: String
}

/// Network Extension flags of a VPN configuration (`NEVPNProtocol`).
struct VPNFlags: Equatable {
    var includeAllNetworks: Bool?
    var excludeLocalNetworks: Bool?
    var enforceRoutes: Bool?
    var excludeAPNs: Bool?
    var excludeCellularServices: Bool?
    var excludeDeviceCommunication: Bool?
}

/// Another Network Extension configuration of the same app, e.g. Proton's
/// split-tunnelling transparent proxy.
struct CompanionConfig: Equatable, Identifiable {
    var id: String
    var name: String
    var kind: String
    var providerBundleID: String?
    var settings: [KeyValue]
    /// Proton split tunnelling in exclusion mode: IPs/CIDRs that bypass the VPN.
    var excludedIPs: [String]
    /// Split-tunnelling mode as the app stores it ("exclusion", …), if known.
    var splitMode: String?
}

struct RouteEntry: Hashable, Identifiable {
    var id: String { family + destination + gateway + flags }
    var family: String       // "IPv4" / "IPv6"
    var destination: String
    var gateway: String
    var flags: String
    /// Interface-scoped routes ("I" flag) only apply to traffic bound to the interface.
    var scoped: Bool { flags.contains("I") }
    /// Host routes cloned on use ("W" flag): a cache, not configuration.
    var cloned: Bool { flags.contains("W") }
}

struct DNSResolver: Hashable, Identifiable {
    var id: Int { index }
    var index: Int
    var domain: String?
    var nameservers: [String]
    var searchDomains: [String]
    var interface: String?
    var supplemental = false
    /// No domain and not supplemental: used for every name without a more specific match.
    var isDefault: Bool { domain == nil && !supplemental }
}

struct VPNService: Identifiable, Equatable {
    var id: String               // configuration UUID
    var name: String
    var type: String             // "VPN", "IPSec", "PPP" …
    var appBundleID: String?
    var enabled: Bool
    var state: VPNState
    var server: String?
    var providerBundleID: String?
    var onDemand: Bool?
    var vendorSettings: [KeyValue] = []
    var flags: VPNFlags?
    var companions: [CompanionConfig] = []
    // Live, only while connected.
    var interface: String?
    var addresses: [String] = []
    var dnsServers: [String] = []
    var isPrimary: Bool?
    var routes: [RouteEntry] = []
    var resolvers: [DNSResolver] = []
    var rawStatus = ""

    var isConnected: Bool { state == .connected }

    /// IPs/CIDRs any companion config says bypass the VPN.
    var excludedIPs: [String] { companions.flatMap(\.excludedIPs) }
}

// MARK: - scutil's text format

/// `scutil` prints nested `<dictionary> { … }` / `<array> { … }` blocks.
indirect enum SCValue: Equatable {
    case string(String)
    case dict([String: SCValue])
    case array([SCValue])

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var dict: [String: SCValue]? { if case .dict(let d) = self { return d } else { return nil } }
    var strings: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.compactMap(\.string)
        case .dict: return []
        }
    }
    var bool: Bool? {
        guard let s = string?.uppercased() else { return nil }
        if ["TRUE", "1", "YES"].contains(s) { return true }
        if ["FALSE", "0", "NO"].contains(s) { return false }
        return nil
    }

    /// Every value stored under `key`, at any depth.
    func find(_ key: String) -> [SCValue] {
        switch self {
        case .string: return []
        case .array(let a): return a.flatMap { $0.find(key) }
        case .dict(let d):
            var out: [SCValue] = d[key].map { [$0] } ?? []
            for (k, v) in d.sorted(by: { $0.key < $1.key }) where k != key { out += v.find(key) }
            return out
        }
    }

    /// Parses scutil output. Lines outside any block are returned as `header`.
    static func parse(_ text: String) -> (header: [String], root: [String: SCValue]) {
        struct Frame { var key: String; var isArray: Bool; var items: [(String, SCValue)] = [] }
        var header: [String] = []
        var root: [String: SCValue] = [:]
        var stack: [Frame] = []

        func finish(_ f: Frame) -> SCValue {
            if f.isArray {
                return .array(f.items.sorted { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) }.map(\.1))
            }
            return .dict(Dictionary(f.items, uniquingKeysWith: { a, _ in a }))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" {
                guard let f = stack.popLast() else { continue }
                let v = finish(f)
                if stack.isEmpty { root[f.key] = v } else { stack[stack.count - 1].items.append((f.key, v)) }
                continue
            }
            for marker in ["<dictionary> {", "<array> {"] where trimmed.hasSuffix(marker) {
                var key = String(trimmed.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
                if key.hasSuffix(" :") || key == ":" { key = String(key.dropLast()).trimmingCharacters(in: .whitespaces) }
                stack.append(Frame(key: key, isArray: marker.hasPrefix("<array")))
            }
            if trimmed.hasSuffix("{") { continue }
            guard !stack.isEmpty else {
                header.append(trimmed)
                continue
            }
            let s = String(line)
            if let sep = s.range(of: " : ") {
                stack[stack.count - 1].items.append((String(s[..<sep.lowerBound]),
                                                     .string(String(s[sep.upperBound...]).trimmingCharacters(in: .whitespaces))))
            } else if s.trimmingCharacters(in: .whitespaces).hasSuffix(" :") {
                let key = s.trimmingCharacters(in: .whitespaces).dropLast(2)
                stack[stack.count - 1].items.append((String(key), .string("")))
            }
        }
        return (header, root)
    }
}

// MARK: - Readers

enum VPNReader {
    struct ListEntry {
        var id: String
        var name: String
        var type: String
        var appBundleID: String?
        var enabled: Bool
        var state: VPNState
    }

    /// `* (Disconnected)   595D…   VPN (ch.protonvpn.mac) "ProtonVPN"   [VPN:ch.protonvpn.mac]`
    static func parseList(_ text: String) -> [ListEntry] {
        let pattern = #"^(\*?)\s*\(([^)]*)\)\s+([0-9A-Fa-f-]{36})\s+(\S+)\s+(?:\(([^)]*)\)\s+)?"(.*)"\s+\["#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [ListEntry] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out.append(ListEntry(id: group(3) ?? "", name: group(6) ?? "", type: group(4) ?? "",
                                 appBundleID: group(5), enabled: group(1) == "*",
                                 state: VPNState(scutil: group(2) ?? "")))
        }
        return out
    }

    static func list() async -> [ListEntry] {
        parseList(await Shell.run("/usr/sbin/scutil", ["--nc", "list"]).stdout)
    }

    /// Server, provider, on-demand and the app's vendor settings from `scutil --nc show`.
    static func show(_ entry: ListEntry) async -> (server: String?, provider: String?, onDemand: Bool?, vendor: [KeyValue]) {
        let r = await Shell.run("/usr/sbin/scutil", ["--nc", "show", entry.id])
        let parsed = SCValue.parse(r.stdout).root
        let vpn = parsed["VPN"]?.dict ?? parsed[entry.type]?.dict ?? [:]
        var vendor: [KeyValue] = []
        if let app = entry.appBundleID, let d = parsed[app]?.dict {
            vendor = d.compactMap { k, v in
                guard !isSensitiveKey(k), let s = v.string ?? (v.strings.isEmpty ? nil : v.strings.joined(separator: ", "))
                else { return nil }
                return KeyValue(key: k, value: s.isEmpty ? "—" : s)
            }.sorted { $0.key < $1.key }
        }
        return (vpn["RemoteAddress"]?.string, vpn["NEProviderBundleIdentifier"]?.string,
                vpn["OnDemandEnabled"]?.bool, vendor)
    }

    /// Vendor keys that look like identifiers or secrets are not shown.
    static func isSensitiveKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.hasSuffix("id") { return true }   // single identifiers ("PVPNLogicalID", "session_id")
        return ["session", "token", "secret", "password", "passwd", "auth", "user", "key", "cert", "identity"]
            .contains { k.contains($0) }
    }

    struct Status {
        var state: VPNState
        var raw: String
        var interface: String?
        var addresses: [String]
        var dnsServers: [String]
        var isPrimary: Bool?
    }

    static func status(_ id: String) async -> Status {
        let r = await Shell.run("/usr/sbin/scutil", ["--nc", "status", id])
        let parsed = SCValue.parse(r.stdout)
        let root = SCValue.dict(parsed.root)
        let addresses = (root.find("Addresses")).flatMap(\.strings)
        return Status(
            state: VPNState(scutil: parsed.header.first ?? ""),
            raw: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            interface: root.find("InterfaceName").first?.string,
            addresses: addresses,
            // NE VPNs report "DNSServers"; IPSec/PPP put "ServerAddresses" under "DNS".
            dnsServers: (root.find("DNSServers") + root.find("ServerAddresses")).flatMap(\.strings),
            isPrimary: root.find("IsPrimaryInterface").first?.bool)
    }

    /// The VPN's tunnel interface: from its status, else by its addresses, else
    /// the utun carrying an unscoped default route that isn't a mesh TUN.
    static func tunnelInterface(status: Status, ifaces: [NetworkInspector.Iface],
                                routes: [RouteEntry: String], exclude: Set<String>) -> String? {
        if let name = status.interface, !name.isEmpty { return name }
        if let hit = ifaces.first(where: { i in
            i.name.hasPrefix("utun") && status.addresses.contains(where: i.addresses.contains)
        }) { return hit.name }
        return routes.first { r, iface in
            r.destination == "default" && !r.scoped && iface.hasPrefix("utun") && !exclude.contains(iface)
        }?.value
    }

    /// Every row of `netstat -rn`, keyed to its interface.
    static func routeTable() async -> [RouteEntry: String] {
        let r = await Shell.run("/usr/sbin/netstat", ["-rn"])
        var family = "IPv4"
        var out: [RouteEntry: String] = [:]
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("Internet6") { family = "IPv6"; continue }
            if line.hasPrefix("Internet") { family = "IPv4"; continue }
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 4, t[0] != "Destination" else { continue }
            let entry = RouteEntry(family: family, destination: t[0], gateway: t[1], flags: t[2])
            out[entry] = t[3]
        }
        return out
    }

    /// Resolvers from the main (unscoped) section of `scutil --dns`.
    static func resolvers() async -> [DNSResolver] {
        let r = await Shell.run("/usr/sbin/scutil", ["--dns"])
        var out: [DNSResolver] = []
        var current: DNSResolver?
        func flush() {
            if let c = current { out.append(c) }
            current = nil
        }
        for raw in r.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped") { break }
            if line.hasPrefix("resolver #"), let n = Int(line.dropFirst("resolver #".count)) {
                flush()
                current = DNSResolver(index: n, domain: nil, nameservers: [], searchDomains: [], interface: nil)
                continue
            }
            guard current != nil, let sep = line.range(of: " : ") else { continue }
            let key = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("nameserver[") { current?.nameservers.append(value) }
            else if key.hasPrefix("search domain[") { current?.searchDomains.append(value) }
            else if key == "domain" { current?.domain = value }
            else if key == "flags", value.contains("Supplemental") { current?.supplemental = true }
            else if key == "if_index", let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")") {
                // "23 (utun11)"
                current?.interface = String(value[value.index(after: open)..<close])
            }
        }
        flush()
        return out
    }
}

// MARK: - Network Extension preferences

/// One configuration from /Library/Preferences/com.apple.networkextension.plist.
struct NEConfigInfo {
    var id: String
    var name: String
    var pluginType: String?          // the owning app's bundle id
    var providerBundleID: String?
    /// 1 = packet tunnel, 2 = app/transparent proxy.
    var tunnelType: Int?
    var enabled: Bool?
    var flags: VPNFlags
    var vendor: [String: [String]]
}

enum NEPreferences {
    static let path = "/Library/Preferences/com.apple.networkextension.plist"

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Decodes the keyed archive by hand: only plain values and the flags we
    /// need are followed, so password/identity fields are never touched.
    static func load() -> [String: NEConfigInfo] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any]
        else { return [:] }

        func uid(_ v: Any) -> Int? {
            if v is String || v is NSNumber || v is Data || v is [Any] || v is [String: Any] { return nil }
            let d = String(describing: v)
            guard d.contains("CFKeyedArchiverUID"), let r = d.range(of: "value = ") else { return nil }
            return Int(d[r.upperBound...].prefix { $0.isNumber })
        }
        func resolve(_ v: Any?) -> Any? {
            guard let v else { return nil }
            if let i = uid(v) {
                guard i < objects.count else { return nil }
                let o = objects[i]
                return (o as? String) == "$null" ? nil : o
            }
            return v
        }
        func string(_ v: Any?) -> String? {
            let r = resolve(v)
            if let s = r as? String { return s }
            if let d = r as? [String: Any], let s = d["NS.string"] as? String { return s }
            return nil
        }
        func bool(_ v: Any?) -> Bool? { (resolve(v) as? NSNumber)?.boolValue }
        func strings(_ v: Any?) -> [String] {
            if let s = string(v) { return [s] }
            if let d = resolve(v) as? [String: Any], let items = d["NS.objects"] as? [Any] {
                return items.compactMap { string($0) }
            }
            if let n = resolve(v) as? NSNumber { return [n.stringValue] }
            return []
        }
        func dictionary(_ v: Any?) -> [String: [String]] {
            guard let d = resolve(v) as? [String: Any],
                  let keys = d["NS.keys"] as? [Any], let values = d["NS.objects"] as? [Any] else { return [:] }
            var out: [String: [String]] = [:]
            for (k, v) in zip(keys, values) {
                guard let key = string(k) else { continue }
                out[key] = strings(v)
            }
            return out
        }

        var out: [String: NEConfigInfo] = [:]
        for (key, ref) in top where key.count == 36 && key.contains("-") {
            guard let config = resolve(ref) as? [String: Any],
                  let vpn = resolve(config["VPN"]) as? [String: Any],
                  let proto = resolve(vpn["Protocol"]) as? [String: Any]
            else { continue }
            let flags = VPNFlags(
                includeAllNetworks: bool(proto["IncludeAllNetworks"]),
                excludeLocalNetworks: bool(proto["ExcludeLocalNetworks"]),
                enforceRoutes: bool(proto["EnforceRoutes"]),
                excludeAPNs: bool(proto["ExcludeAPNs"]),
                excludeCellularServices: bool(proto["ExcludeCellularServices"]),
                excludeDeviceCommunication: bool(proto["ExcludeDeviceCommunication"]))
            out[key] = NEConfigInfo(
                id: key,
                name: string(config["Name"]) ?? key,
                pluginType: string(proto["PluginType"]),
                providerBundleID: string(proto["NEProviderBundleIdentifier"]),
                tunnelType: (resolve(vpn["TunnelType"]) as? NSNumber)?.intValue,
                enabled: bool(vpn["Enabled"]),
                flags: flags,
                vendor: dictionary(proto["VendorConfiguration"]))
        }
        return out
    }

    /// Other configurations of the same app (split-tunnelling proxy and the like).
    static func companions(of service: String, app: String?, in configs: [String: NEConfigInfo]) -> [CompanionConfig] {
        guard let app else { return [] }
        return configs.values
            .filter { $0.id != service && $0.pluginType == app }
            .sorted { $0.name < $1.name }
            .map { c in
                let mode = c.vendor["plutoniumMode"]?.first
                let settings = c.vendor.keys.sorted().compactMap { k -> KeyValue? in
                    guard !VPNReader.isSensitiveKey(k) else { return nil }
                    let v = c.vendor[k] ?? []
                    return KeyValue(key: k, value: v.isEmpty ? "—" : v.joined(separator: ", "))
                }
                return CompanionConfig(
                    id: c.id, name: c.name,
                    kind: c.tunnelType == 2 ? "Proxy (per-app / per-IP rules)" : "Tunnel",
                    providerBundleID: c.providerBundleID,
                    settings: settings,
                    // Proton's split tunnelling: `ips` with plutoniumMode = exclusion bypass the VPN.
                    excludedIPs: mode == "exclusion" ? (c.vendor["ips"] ?? []) : [],
                    splitMode: mode)
            }
    }
}

// MARK: - Address helpers

enum IPAddress {
    /// Raw bytes of an IPv4/IPv6 literal (any %scope dropped).
    static func bytes(_ s: String) -> [UInt8]? {
        let host = String(s.split(separator: "%").first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    static func isIPv6(_ s: String) -> Bool { bytes(s)?.count == 16 }

    /// `cidr` may be a bare address or "addr/len".
    static func contains(cidr: String, _ ip: String) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard let net = bytes(String(parts.first ?? "")), let addr = bytes(ip), net.count == addr.count else { return false }
        let len = parts.count > 1 ? (Int(parts[1]) ?? net.count * 8) : net.count * 8
        var remaining = max(0, min(len, net.count * 8))
        for i in 0..<net.count where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if net[i] & mask != addr[i] & mask { return false }
            remaining -= bits
        }
        return true
    }

    /// RFC 1918, CGNAT, link-local and IPv6 ULA / link-local.
    static func isPrivate(_ ip: String) -> Bool {
        ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16",
         "fc00::/7", "fe80::/10"].contains { contains(cidr: $0, ip) }
    }
}
