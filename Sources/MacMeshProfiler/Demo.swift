import Foundation

/// Sample data for `-demo YES`, used for README screenshots.
///
/// Everything here is made up: IPs come from the documentation ranges
/// (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32), keys and
/// overlay addresses are random-looking constants, and the Mycelium peers are
/// ThreeFold's published public nodes. Nothing is read from or written to the system.
@MainActor
enum Demo {
    static func apply(to app: AppModel) {
        applyYggdrasil(app.yggdrasil)
        applyMycelium(app.mycelium)
        applyVPN(app.vpn)
        applyWireGuard(app.wireguard)
    }

    // MARK: WireGuard

    private static func applyWireGuard(_ model: WireGuardModel) {
        var nl = WGConfigSummary()
        nl.addresses = ["10.2.0.2/32"]
        nl.dns = ["10.2.0.1"]
        nl.publicKey = "q3V1bW9ja1B1YmxpY0tleUZvckRlbW9Pbmx5MDEyMzQ="
        nl.peers = [WGPeerSummary(publicKey: "ZGVtb1BlZXJQdWJsaWNLZXlOb3RSZWFsQWJjZGVmZ2g=",
                                  endpoint: "198.51.100.140:51820", allowedIPs: ["0.0.0.0/0", "::/0"], keepalive: 25)]
        var home = WGConfigSummary()
        home.addresses = ["10.66.0.5/24"]
        home.peers = [WGPeerSummary(publicKey: "aG9tZUdhdGV3YXlQdWJsaWNLZXlEZW1vT25seTAxMjM=",
                                    endpoint: "home.example.net:51820", allowedIPs: ["10.66.0.0/24", "192.168.1.0/24"],
                                    keepalive: nil)]
        let tunnels = [
            WGTunnel(name: "wg-NL-12", summary: nl, running: true, interface: "utun12",
                     rxBytes: 182_452_224, txBytes: 21_495_808),
            WGTunnel(name: "home", summary: home),
        ]
        var vpn = VPNService(id: "wg:wg-NL-12", name: "wg-NL-12", type: "WireGuard", appBundleID: nil, enabled: true,
                             state: .connected, server: "198.51.100.140:51820", providerBundleID: nil, onDemand: nil)
        vpn.interface = "utun12"
        vpn.addresses = ["10.2.0.2"]
        vpn.dnsServers = ["10.2.0.1"]
        vpn.routes = [
            RouteEntry(family: "IPv4", destination: "0/1", gateway: "utun12", flags: "USc"),
            RouteEntry(family: "IPv4", destination: "128.0/1", gateway: "utun12", flags: "USc"),
            RouteEntry(family: "IPv4", destination: "10.2.0.2", gateway: "10.2.0.2", flags: "UH"),
            RouteEntry(family: "IPv6", destination: "::/1", gateway: "utun12", flags: "USc"),
            RouteEntry(family: "IPv6", destination: "8000::/1", gateway: "utun12", flags: "USc"),
        ]
        vpn.resolvers = [DNSResolver(index: 1, domain: nil, nameservers: ["10.2.0.1"], searchDomains: [], interface: nil)]
        let checks: [MeshCheckItem] = MeshClashCheck.flagItems(vpn, connected: true) + [
            MeshCheckItem(severity: .ok, title: "Yggdrasil overlay route is intact", detail: "200::/7 → utun4 (routing table)."),
            MeshCheckItem(severity: .info, title: "4 of 4 Yggdrasil peers are reached through wg-NL-12",
                          detail: "203.0.113.10, 198.51.100.24, 2001:db8:4:1::7, 192.0.2.55. This works, but adds latency, and these peers see the VPN's exit address instead of yours."),
            MeshCheckItem(severity: .ok, title: "Mycelium overlay route is intact", detail: "400::/7 → utun20 (routing table)."),
            MeshCheckItem(severity: .info, title: "10 of 10 Mycelium peers are reached through wg-NL-12",
                          detail: "ThreeFold public nodes. This works, but adds latency, and these peers see the VPN's exit address instead of yours."),
        ]
        model.applyDemo(
            tunnels: tunnels,
            stats: ["wg-NL-12": [WGPeerStats(publicKey: nl.peers[0].publicKey, endpoint: "198.51.100.140:51820",
                                             latestHandshake: Date().addingTimeInterval(-47),
                                             rxBytes: 182_452_224, txBytes: 21_495_808)]],
            vpn: ["wg-NL-12": vpn], checks: ["wg-NL-12": checks], version: "1.0.20250521")
    }

    // MARK: VPN

    private static func applyVPN(_ model: VPNModel) {
        let flags = VPNFlags(includeAllNetworks: false, excludeLocalNetworks: true, enforceRoutes: false,
                             excludeAPNs: true, excludeCellularServices: true, excludeDeviceCommunication: true)
        var proton = VPNService(
            id: "6F1C2A9E-3B47-4D8A-9E21-5C7B0D4F8A13", name: "ProtonVPN", type: "VPN",
            appBundleID: "ch.protonvpn.mac", enabled: true, state: .connected,
            server: "203.0.113.80", providerBundleID: "ch.protonvpn.mac.WireGuard-Extension", onDemand: false,
            vendorSettings: [KeyValue(key: "wg-protocol", value: "udp")], flags: flags)
        proton.companions = [CompanionConfig(
            id: "0B3E7D21-8C5A-4F19-A6D4-2E9F1B7C5A30", name: "Proton VPN Split tunneling",
            kind: "Proxy (per-app / per-IP rules)", providerBundleID: "ch.protonvpn.mac.Transparent-Proxy",
            settings: [KeyValue(key: "appIDs", value: "—"), KeyValue(key: "dnsServers", value: "10.2.0.1"),
                       KeyValue(key: "ips", value: "192.0.2.55")],
            excludedIPs: ["192.0.2.55"], splitMode: "exclusion")]
        proton.interface = "utun11"
        proton.addresses = ["10.2.0.2", "2a07:b944::2:2"]
        proton.dnsServers = ["10.2.0.1"]
        proton.isPrimary = true
        proton.routes = [
            RouteEntry(family: "IPv4", destination: "0/1", gateway: "10.2.0.1", flags: "UGScg"),
            RouteEntry(family: "IPv4", destination: "128.0/1", gateway: "10.2.0.1", flags: "UGSc"),
            RouteEntry(family: "IPv4", destination: "10.2.0.2", gateway: "10.2.0.2", flags: "UH"),
            RouteEntry(family: "IPv4", destination: "default", gateway: "link#24", flags: "UCSIg"),
            RouteEntry(family: "IPv6", destination: "::/1", gateway: "utun11", flags: "USc"),
            RouteEntry(family: "IPv6", destination: "8000::/1", gateway: "utun11", flags: "USc"),
            RouteEntry(family: "IPv6", destination: "default", gateway: "fe80::%utun11", flags: "UGcIg"),
        ]
        proton.resolvers = [DNSResolver(index: 1, domain: nil, nameservers: ["10.2.0.1"], searchDomains: [],
                                        interface: "utun11")]
        proton.rawStatus = "Connected\nExtended Status <dictionary> {\n  Status : 2\n  …\n}"

        let office = VPNService(
            id: "C4D81F06-72AE-4B3C-8F95-1A6E2D0B9C47", name: "Office VPN", type: "VPN",
            appBundleID: nil, enabled: true, state: .disconnected,
            server: "vpn.example.com", providerBundleID: nil, onDemand: false, flags: flags)

        model.services = [proton, office]
        model.checks = [
            proton.id: [
                MeshCheckItem(severity: .ok, title: "Other tunnels are left alone",
                              detail: "\"Include all networks\" is off, so traffic follows the routing table and the mesh TUN routes keep working."),
                MeshCheckItem(severity: .ok, title: "Yggdrasil overlay route is intact",
                              detail: "200::/7 → utun4 (routing table)."),
                MeshCheckItem(severity: .info, title: "3 of 4 Yggdrasil peers are reached through ProtonVPN",
                              detail: "203.0.113.10, 198.51.100.24, 2001:db8:4:1::7. This works, but adds latency, and these peers see the VPN's exit address instead of yours."),
                MeshCheckItem(severity: .ok, title: "1 Yggdrasil peer excluded by split tunnelling",
                              detail: "192.0.2.55"),
                MeshCheckItem(severity: .ok, title: "Mycelium overlay route is intact",
                              detail: "400::/7 → utun20 (routing table)."),
                MeshCheckItem(severity: .info, title: "10 of 10 Mycelium peers are reached through ProtonVPN",
                              detail: "ThreeFold public nodes. This works, but adds latency, and these peers see the VPN's exit address instead of yours."),
            ],
            office.id: MeshClashCheck.flagItems(office, connected: false),
        ]
        model.lastRefresh = Date()
    }

    // MARK: Yggdrasil

    private static func applyYggdrasil(_ model: YggdrasilModel) {
        var settings = YggdrasilSettings()
        settings.peers = [
            "tls://203.0.113.10:443",
            "quic://198.51.100.24:443",
            "tls://[2001:db8:4:1::7]:443",
            "tcp://192.0.2.55:9001",
        ]
        settings.listen = ["tls://[::]:9443"]
        settings.ifName = "auto"
        settings.adminListen = YggdrasilModel.localTCPAdmin

        let address = "201:5f0c:93a2:7e41:c08d:1b6e:a2f4:39d7"
        var r = ServiceRuntime()
        r.installedVersion = "0.5.15"
        r.latestRelease = Release(tag: "v0.5.15", assets: [])
        r.daemon = DaemonStatus(plistInstalled: true, loaded: true, running: true, pid: 412,
                                lastExit: nil, disabledAtBoot: false)
        r.address = InterfaceAddress(interface: "utun4", address: address)
        r.lastRefresh = Date()
        r.livePeers = [
            LivePeer(endpoint: "tls://203.0.113.10:443", state: .up, kind: "outbound",
                     overlayAddress: "200:7c1e:4d2a:9b3f:61e0:58a4:c3d9:2f17",
                     rxBytes: 48_213_504, txBytes: 6_291_456, latencyMs: 38),
            LivePeer(endpoint: "quic://198.51.100.24:443", state: .up, kind: "outbound",
                     overlayAddress: "202:a91b:3e7c:44d0:8f25:b16a:0c3e:7d92",
                     rxBytes: 12_582_912, txBytes: 2_097_152, latencyMs: 61),
            LivePeer(endpoint: "tls://[2001:db8:4:1::7]:443", state: .down, kind: "outbound",
                     lastError: "dial tcp [2001:db8:4:1::7]:443: i/o timeout"),
            LivePeer(endpoint: "tcp://192.0.2.55:9001", state: .connecting, kind: "outbound"),
            LivePeer(endpoint: "tls://[2001:db8:77::12]:51544", state: .up, kind: "inbound",
                     rxBytes: 734_003, txBytes: 1_258_291, latencyMs: 112),
            LivePeer(endpoint: "tls://[fe80::1c2d:3e4f:5a6b:7c8d%en0]:61234", state: .up,
                     kind: "LAN (multicast)", rxBytes: 3_145_728, txBytes: 2_621_440, latencyMs: 2),
        ]
        r.network = NetworkSnapshot(
            connections: [],
            listening: [
                ListeningSocket(proto: "UDP", family: "IPv6", address: "all", port: 9001,
                                interface: "all", purpose: "Multicast peer discovery (LAN)"),
                ListeningSocket(proto: "TCP", family: "IPv4", address: "127.0.0.1", port: 9001,
                                interface: "lo0", purpose: "Admin API"),
                ListeningSocket(proto: "TCP", family: "IPv4+6", address: "all", port: 9443,
                                interface: "all", purpose: "Peer listener (Listen)"),
                ListeningSocket(proto: "TCP", family: "IPv6", address: "fe80::1c2d:5e8a:…", port: 61002,
                                interface: "en0", purpose: "LAN peering listener (multicast)"),
            ],
            interfaces: [
                InterfaceUse(name: "utun4", roles: ["Overlay (TUN)"], mtu: 65535, isUp: true,
                             addresses: ["fe80::4a1c:7e2b:93d0:16f5", address]),
                InterfaceUse(name: "en0", roles: ["Peering traffic", "LAN peering listener (multicast)"],
                             mtu: 1500, isUp: true,
                             addresses: ["fe80::1c2d:5e8a:a7b3:4f61", "192.168.1.20"]),
                InterfaceUse(name: "lo0", roles: ["Admin API"], mtu: 16384, isUp: true,
                             addresses: ["127.0.0.1", "::1", "fe80::1"]),
            ],
            unixSockets: [],
            establishedCount: 4)

        model.applyDemo(settings: settings, runtime: r,
                        publicKey: "2b7e4c1d9a03f5e6b8c0d2a4f6e8b0c1d3e5f7a9b1c3d5e7f9a0b2c4d6e8f0a1",
                        logPath: writeLog("yggdrasil", yggdrasilLog(address: address)))
    }

    // MARK: Mycelium

    private static func applyMycelium(_ model: MyceliumModel) {
        var settings = MyceliumSettings()
        settings.peers = MyceliumPublicNodes.uris(proto: "tcp", ipv6: false)
        settings.tunName = "utun20"

        let address = "4c2:9a1e:73f0:5b28:1d6c:e94a:208b:7f35"
        var r = ServiceRuntime()
        r.installedVersion = "0.7.10"
        r.latestRelease = Release(tag: "v0.7.10", assets: [])
        r.daemon = DaemonStatus(plistInstalled: true, loaded: true, running: true, pid: 731,
                                lastExit: nil, disabledAtBoot: false)
        r.address = InterfaceAddress(interface: "utun20", address: address)
        r.lastRefresh = Date()
        let traffic: [(Int64, Int64)] = [(412, 288), (530, 301), (377, 260), (498, 312), (611, 342),
                                         (583, 330), (702, 355), (655, 349), (0, 0), (544, 317)]
        r.livePeers = zip(settings.peers, traffic).enumerated().map { i, pair in
            let (peer, t) = pair
            let connecting = i == 8
            return LivePeer(endpoint: peer, state: connecting ? .connecting : .up, kind: "static",
                            rxBytes: connecting ? nil : t.0 * 1024, txBytes: connecting ? nil : t.1 * 1024)
        } + [
            LivePeer(endpoint: "tcp://[fe80::a1b2:c3d4:e5f6:789a%en0]:9651", state: .up,
                     kind: "LAN discovery", rxBytes: 96 * 1024, txBytes: 88 * 1024),
        ]
        r.network = NetworkSnapshot(
            connections: [],
            listening: [
                ListeningSocket(proto: "TCP", family: "IPv4", address: "127.0.0.1", port: 8989,
                                interface: "lo0", purpose: "HTTP API"),
                ListeningSocket(proto: "TCP", family: "IPv4", address: "127.0.0.1", port: 8990,
                                interface: "lo0", purpose: "JSON-RPC API"),
                ListeningSocket(proto: "UDP", family: "IPv4+6", address: "all", port: 9650,
                                interface: "all", purpose: "LAN peer discovery"),
                ListeningSocket(proto: "TCP", family: "IPv4+6", address: "all", port: 9651,
                                interface: "all", purpose: "Peer listener (TCP)"),
                ListeningSocket(proto: "UDP", family: "IPv4+6", address: "all", port: 9651,
                                interface: "all", purpose: "Peer listener (QUIC)"),
            ],
            interfaces: [
                InterfaceUse(name: "utun20", roles: ["Overlay (TUN)"], mtu: 1400, isUp: true,
                             addresses: ["fe80::83d1:2c4e:6a0f:b5e7", address]),
                InterfaceUse(name: "en0", roles: ["Peering traffic"], mtu: 1500, isUp: true,
                             addresses: ["fe80::1c2d:5e8a:a7b3:4f61", "192.168.1.20"]),
                InterfaceUse(name: "lo0", roles: ["HTTP API", "JSON-RPC API"], mtu: 16384, isUp: true,
                             addresses: ["127.0.0.1", "::1", "fe80::1"]),
            ],
            unixSockets: [],
            establishedCount: 10)

        model.applyDemo(settings: settings, runtime: r,
                        publicKey: "9d41e07b2c58fa3613be0c74d92a58f1e6037cb4a8d21f95e04b7c3a6d18f2e9",
                        logPath: writeLog("mycelium", myceliumLog(address: address)))
    }

    // MARK: Sample logs

    private static func writeLog(_ name: String, _ text: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mmp-demo-\(name).log")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private static func yggdrasilLog(address: String) -> String {
        """
        2026/11/19 09:12:03 Build name: yggdrasil
        2026/11/19 09:12:03 Build version: 0.5.15
        2026/11/19 09:12:03 Your public key is 2b7e4c1d9a03f5e6b8c0d2a4f6e8b0c1d3e5f7a9b1c3d5e7f9a0b2c4d6e8f0a1
        2026/11/19 09:12:03 Your IPv6 address is \(address)
        2026/11/19 09:12:03 Your IPv6 subnet is 301:5f0c:93a2:7e41::/64
        2026/11/19 09:12:03 Interface name: utun4
        2026/11/19 09:12:03 Interface MTU: 65535
        2026/11/19 09:12:03 TCP listener started on [::]:9443
        2026/11/19 09:12:03 Admin socket listening on 127.0.0.1:9001
        2026/11/19 09:12:04 Multicast discovery is enabled
        2026/11/19 09:12:04 TLS listener started on [fe80::1c2d:5e8a:a7b3:4f61%en0]:61002
        2026/11/19 09:12:04 Connected outbound: 200:7c1e:4d2a:9b3f:61e0:58a4:c3d9:2f17@203.0.113.10:443, source 192.168.1.20:52114
        2026/11/19 09:12:05 Connected outbound: 202:a91b:3e7c:44d0:8f25:b16a:0c3e:7d92@198.51.100.24:443, source 192.168.1.20:60231
        2026/11/19 09:12:09 Connected inbound: 203:11f4:7b0e:9c2a:d6e1:43f8:a05b:6c29@[fe80::1c2d:3e4f:5a6b:7c8d%en0]:61234, source [fe80::1c2d:5e8a:a7b3:4f61%en0]:61002
        2026/11/19 09:12:34 Failed to connect to tls://[2001:db8:4:1::7]:443: dial tcp [2001:db8:4:1::7]:443: i/o timeout
        2026/11/19 09:14:51 Connected inbound: 201:e30c:5a9d:1b47:f82e:6d03:c9a1:4e75@[2001:db8:77::12]:51544, source [2001:db8:5::20]:9443
        2026/11/19 09:31:07 Failed to connect to tls://[2001:db8:4:1::7]:443: dial tcp [2001:db8:4:1::7]:443: i/o timeout
        2026/11/19 09:47:22 Disconnected outbound: 202:a91b:3e7c:44d0:8f25:b16a:0c3e:7d92@198.51.100.24:443, source 192.168.1.20:60231; error: read: i/o timeout
        2026/11/19 09:47:25 Connected outbound: 202:a91b:3e7c:44d0:8f25:b16a:0c3e:7d92@198.51.100.24:443, source 192.168.1.20:61877

        """
    }

    private static func myceliumLog(address: String) -> String {
        let nodes = MyceliumPublicNodes.all
        var lines = [
            "2026-11-19T09:20:11.204118Z  INFO mycelium: Router created. Pubkey: 9d41e07b2c58fa3613be0c74d92a58f1e6037cb4a8d21f95e04b7c3a6d18f2e9",
            "2026-11-19T09:20:11.205530Z  INFO mycelium: Started peer manager",
            "2026-11-19T09:20:11.206002Z  INFO mycelium::tun: Created TUN interface utun20, address \(address)/7",
            "2026-11-19T09:20:11.206391Z  INFO mycelium::peer_manager: Bound multicast discovery interface bind_address=[::]:9650",
        ]
        for (i, n) in nodes.enumerated() where i != 8 {
            lines.append(String(format: "2026-11-19T09:20:11.%06dZ  INFO connect_peer: mycelium::peer_manager: Connected to new peer endpoint.proto=Tcp endpoint.address=%@:9651", 251_000 + i * 7_313, n.ipv4))
        }
        let subnets = ["54b:83ab:6cb5:7b38", "40a:152c:b85b:9646", "597:a4ef:806:b09", "549:8bce:fa45:e001",
                       "410:2778:53bf:6f41", "488:74ac:8a31:277b", "4ab:a385:5a4e:ef8f", "4de:b695:3859:8234"]
        for (i, s) in subnets.enumerated() {
            let n = nodes[i]
            lines.append(String(format: "2026-11-19T09:20:%02d.%06dZ  INFO mycelium::router: Acquired route subnet=%@::/64 peer=\"TCP 192.168.1.20:%d <-> %@:9651\"", 12 + i, 104_000 + i * 51_771, s, 52_300 + i, n.ipv4))
        }
        lines.append("2026-11-19T09:20:41.880215Z  WARN mycelium::peer_manager: Failed to connect to peer endpoint.address=5.223.43.251:9651 err=connection timed out, retrying")
        lines.append("2026-11-19T09:21:02.117904Z  INFO mycelium::peer_manager: Discovered link-local peer endpoint.address=[fe80::a1b2:c3d4:e5f6:789a%en0]:9651")
        return lines.joined(separator: "\n") + "\n"
    }
}
