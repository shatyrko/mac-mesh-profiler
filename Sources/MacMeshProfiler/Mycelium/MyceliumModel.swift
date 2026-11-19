import Foundation
import Observation

@MainActor
@Observable
final class MyceliumModel: MeshServiceModel {
    static let binary = "/usr/local/bin/mycelium"
    static let configDir = "/etc/mycelium"
    static let configPath = "/etc/mycelium/mycelium.toml"
    static let keyPath = "/etc/mycelium/priv_key.bin"
    static let logPath = "/var/log/mycelium.log"
    static let plistPath = "/Library/LaunchDaemons/tech.threefold.mycelium.plist"
    static let label = "tech.threefold.mycelium"
    static let newsyslogPath = "/etc/newsyslog.d/mycelium.conf"
    static let peerSchemes = ["tcp", "quic"]

    let id = ServiceID.mycelium
    let daemon = LaunchDaemon(label: MyceliumModel.label, plistPath: MyceliumModel.plistPath)

    var runtime = ServiceRuntime()
    @ObservationIgnored private let connectionMatcher = ConnectionPeerMatcher()
    /// Parsed from /etc/mycelium/mycelium.toml (world-readable, no secrets in it).
    private(set) var saved: MyceliumSettings?
    var draft = MyceliumSettings()
    var nodePublicKey: String?
    /// Interfaces present right now, to warn about a clashing tun name.
    private(set) var interfaceNames: Set<String> = []

    var configExists: Bool { saved != nil }
    var configuredPeers: [String] { (saved ?? draft).peers }
    /// Log file shown in the Log tab (demo mode swaps in a sample file).
    var logPath = MyceliumModel.logPath
    var isDirty: Bool { draft != (saved ?? baseline) }
    /// Defaults shown when no config file exists yet.
    private var baseline = MyceliumSettings()

    init() {
        Task { await prepareDefaults() }
    }

    private func prepareDefaults() async {
        var b = MyceliumSettings()
        b.peers = MyceliumPublicNodes.uris(proto: "tcp", ipv6: false)
        b.tunName = await Interfaces.freeUtun()
        let wasPristine = draft == baseline
        baseline = b
        if saved == nil, wasPristine { draft = b }
    }

    var tunNameProblem: String? {
        let name = draft.tunName
        if name.range(of: #"^utun[0-9]+$"#, options: .regularExpression) == nil {
            return "On macOS the interface name must be utun followed by a number (e.g. utun20)."
        }
        let ownInterface = runtime.address?.interface
        if interfaceNames.contains(name), name != ownInterface {
            return "\(name) is already used by another interface; pick a free one."
        }
        return nil
    }

    // MARK: Status

    func refresh() async {
        var r = runtime
        if FileManager.default.isExecutableFile(atPath: Self.binary) {
            let v = await Shell.run(Self.binary, ["--version"])
            let text = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            r.installedVersion = text.split(separator: " ").last.map(String.init) ?? "unknown"
        } else {
            r.installedVersion = nil
        }

        // Re-read the config unless the user is in the middle of editing it.
        if let text = try? String(contentsOfFile: Self.configPath, encoding: .utf8) {
            let parsed = MyceliumConfigFile.parse(text)
            let editing = isDirty
            saved = parsed
            if !editing { draft = parsed }
        } else if saved != nil {
            saved = nil
        }

        r.daemon = await daemon.status()
        interfaceNames = await Interfaces.names()
        r.address = r.daemon.running ? await Interfaces.overlayAddress(.mycelium) : nil

        if r.daemon.running, let pid = r.daemon.pid {
            let cfg = saved ?? draft
            let apiPort = YggdrasilModel.port(of: cfg.apiAddr)
            let extra = Dictionary(cfg.extra.map { ($0.key, $0.rawValue) }, uniquingKeysWith: { a, _ in a })
            let rpcPort = extra["jsonrpc_addr"].flatMap { YggdrasilModel.port(of: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) } ?? 8990
            let discoveryPort = extra["peer_discovery_port"].flatMap { Int($0) } ?? 9650
            let metricsPort = extra["metrics_api_address"].flatMap { YggdrasilModel.port(of: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
            r.network = await NetworkInspector.snapshot(
                process: "mycelium", pid: pid, tun: cfg.tunName.isEmpty ? nil : cfg.tunName
            ) { proto, port, _ in
                switch (proto, port) {
                case ("TCP", cfg.tcpListenPort): return "Peer listener (TCP)"
                case ("UDP", cfg.quicListenPort): return "Peer listener (QUIC)"
                case ("UDP", discoveryPort): return "LAN peer discovery"
                case ("TCP", apiPort ?? -1): return "HTTP API"
                case ("TCP", rpcPort): return "JSON-RPC API"
                case ("TCP", metricsPort ?? -1): return "Metrics API"
                default: return proto
                }
            }
        } else {
            r.network = NetworkSnapshot()
        }

        if r.daemon.running, let base = (saved ?? draft).apiBaseURL {
            if let (info, peers) = await fetchLive(base: base) {
                r.livePeers = peers
                r.liveNote = nil
                r.liveSource = nil
                nodePublicKey = info["nodePubkey"] as? String
                if let ip = info["nodeIp"] as? String {
                    r.address = InterfaceAddress(interface: r.address?.interface ?? "", address: ip)
                }
            } else {
                // API unreachable: fall back to the daemon's open connections.
                r.livePeers = await connectionMatcher.peers(configured: (saved ?? draft).peers, network: r.network)
                r.liveNote = nil
                r.liveSource = "Mycelium API at \(base.absoluteString) not reachable — status from open connections (netstat): green = connected, red = no connection."
            }
        } else {
            r.livePeers = []
            r.liveNote = nil
            r.liveSource = nil
        }
        r.lastRefresh = Date()
        r.busy = runtime.busy
        r.lastError = runtime.lastError
        r.latestRelease = runtime.latestRelease
        runtime = r
    }

    private func fetchLive(base: URL) async -> ([String: Any], [LivePeer])? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (infoData, _) = try await session.data(from: base.appendingPathComponent("api/v1/admin"))
            let (peerData, _) = try await session.data(from: base.appendingPathComponent("api/v1/admin/peers"))
            let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any] ?? [:]
            let raw = try JSONSerialization.jsonObject(with: peerData) as? [[String: Any]] ?? []
            let peers: [LivePeer] = raw.map { p in
                let ep = p["endpoint"] as? [String: Any] ?? [:]
                let proto = (ep["proto"] as? String ?? "?").lowercased()
                // v0.7 nests it as {"addr": {"socket": "ip:port"}}; older docs say "socketAddr".
                let nested = ep["addr"] as? [String: Any]
                let addr = nested?["socket"] as? String
                    ?? ep["addr"] as? String
                    ?? ep["socketAddr"] as? String
                    ?? nested?.values.compactMap { $0 as? String }.first
                    ?? "?"
                let state: PeerState
                switch p["connectionState"] as? String {
                case "alive": state = .up
                case "connecting": state = .connecting
                case "dead": state = .down
                default: state = .unknown
                }
                let kind: String
                switch p["type"] as? String {
                case "static": kind = "static"
                case "inbound": kind = "inbound"
                case "linkLocalDiscovery": kind = "LAN discovery"
                default: kind = p["type"] as? String ?? "?"
                }
                return LivePeer(endpoint: "\(proto)://\(addr)", state: state, kind: kind,
                                rxBytes: (p["rxBytes"] as? NSNumber)?.int64Value,
                                txBytes: (p["txBytes"] as? NSNumber)?.int64Value)
            }
            return (info, peers)
        } catch {
            return nil
        }
    }

    func checkForUpdate() async {
        if let release = try? await GitHub.latestRelease(repo: "threefoldtech/mycelium") {
            runtime.latestRelease = release
        }
    }

    // MARK: Service control

    func start() async {
        await perform("Starting Mycelium…") {
            var script = ""
            // Make sure there is something to start (config + launch daemon).
            if saved == nil { script += writeConfigScript(draft) + "\n" }
            script += writePlistScript() + "\n"
            script += daemon.startScript(startAtBoot: !runtime.daemon.disabledAtBoot)
            try await Admin.run(script, reason: "start Mycelium")
        }
    }

    func stop() async {
        await perform("Stopping Mycelium…") {
            try await Admin.run(daemon.stopScript(), reason: "stop Mycelium")
        }
    }

    func restart() async {
        await perform("Restarting Mycelium…") {
            try await Admin.run(daemon.restartScript(), reason: "restart Mycelium")
        }
    }

    func setStartAtBoot(_ on: Bool) async {
        await perform(on ? "Enabling start at boot…" : "Disabling start at boot…") {
            try await Admin.run(daemon.bootSettingScript(enabled: on), reason: "change Mycelium's boot setting")
        }
    }

    // MARK: Configuration

    func writeConfigScript(_ settings: MyceliumSettings) -> String {
        let b64 = Data(MyceliumConfigFile.render(settings).utf8).base64EncodedString()
        return """
        umask 022
        /bin/mkdir -p \(Self.configDir)
        /bin/chmod 755 \(Self.configDir)
        T="$(/usr/bin/mktemp \(Self.configPath).XXXXXX)"
        /bin/echo \(b64) | /usr/bin/base64 -D > "$T"
        /usr/sbin/chown root:wheel "$T"
        /bin/chmod 644 "$T"
        /bin/mv -f "$T" \(Self.configPath)
        """
    }

    func writePlistScript() -> String {
        let plist = MyceliumConfigFile.launchdPlist(
            label: Self.label, binary: Self.binary, config: Self.configPath,
            key: Self.keyPath, workingDir: Self.configDir, log: Self.logPath)
        let b64 = Data(plist.utf8).base64EncodedString()
        // Rotate the log at 1 MB, keep 5 compressed copies.
        let rotate = Data("\(Self.logPath)\t644\t5\t1024\t*\tJ\n".utf8).base64EncodedString()
        return """
        /bin/echo \(b64) | /usr/bin/base64 -D > \(Self.plistPath)
        /usr/sbin/chown root:wheel \(Self.plistPath)
        /bin/chmod 644 \(Self.plistPath)
        /bin/mkdir -p /etc/newsyslog.d
        /bin/echo \(rotate) | /usr/bin/base64 -D > \(Self.newsyslogPath)
        """
    }

    func apply() async {
        let settings = draft
        guard tunNameProblem == nil || runtime.daemon.running else {
            runtime.lastError = tunNameProblem
            return
        }
        await perform("Applying Mycelium configuration…") {
            let script = writeConfigScript(settings) + "\n" + daemon.restartIfLoadedScript()
            try await Admin.run(script, reason: "update \(Self.configPath) and restart Mycelium")
            saved = settings
        }
    }

    func revert() {
        draft = saved ?? baseline
    }

    // MARK: Install / update

    func installOrUpdate() async {
        let fresh = !runtime.isInstalled
        await perform(fresh ? "Installing Mycelium…" : "Updating Mycelium…") {
            let release = try await GitHub.latestRelease(repo: "threefoldtech/mycelium")
            runtime.latestRelease = release
            let name = "mycelium-\(GitHub.archToken.rust)-apple-darwin.tar.gz"
            guard let asset = release.assets.first(where: { $0.name == name }) else {
                throw GitHubError.noAsset(name)
            }
            runtime.busy = "Downloading \(asset.name)…"
            let (file, sha) = try await GitHub.download(asset)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            runtime.busy = "Installing Mycelium \(release.version)…"

            // Everything below runs as root. The archive is copied into a
            // root-only directory and its checksum re-verified there before use.
            var script = """
            umask 022
            D="$(/usr/bin/mktemp -d /private/var/tmp/meshprofiler.XXXXXX)"
            trap '/bin/rm -rf "$D"' EXIT
            /bin/cp \(Shell.quote(file.path)) "$D/mycelium.tar.gz"
            /bin/echo "\(sha)  $D/mycelium.tar.gz" | /usr/bin/shasum -a 256 -c - > /dev/null
            /usr/bin/tar -xzf "$D/mycelium.tar.gz" -C "$D" mycelium
            /bin/mkdir -p /usr/local/bin
            /usr/bin/install -m 755 -o root -g wheel "$D/mycelium" \(Self.binary)
            /usr/bin/xattr -d com.apple.quarantine \(Self.binary) 2>/dev/null || true
            """
            if saved == nil {
                script += "\nif [ ! -f \(Self.configPath) ]; then\n" + writeConfigScript(draft) + "\nfi"
            }
            script += "\n" + writePlistScript()
            if fresh || !runtime.daemon.loaded {
                script += "\n" + daemon.startScript(startAtBoot: true)
            } else {
                script += "\n" + daemon.restartScript()
            }
            try await Admin.run(script, reason: "install Mycelium \(release.version)")
        }
    }

    // MARK: Demo

    /// Fills the model with sample data for screenshots (see Demo.swift).
    func applyDemo(settings: MyceliumSettings, runtime: ServiceRuntime, publicKey: String, logPath: String) {
        saved = settings
        draft = settings
        self.runtime = runtime
        nodePublicKey = publicKey
        interfaceNames = []
        self.logPath = logPath
    }
}
