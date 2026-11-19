import SwiftUI

struct MyceliumView: View {
    @Bindable var model: MyceliumModel

    private var running: Bool { model.runtime.daemon.running }

    private var presets: [PeerPreset] {
        [
            PeerPreset(title: "All ThreeFold public nodes — TCP, IPv4",
                       uris: MyceliumPublicNodes.uris(proto: "tcp", ipv6: false)),
            PeerPreset(title: "All ThreeFold public nodes — QUIC, IPv4",
                       uris: MyceliumPublicNodes.uris(proto: "quic", ipv6: false)),
            PeerPreset(title: "All ThreeFold public nodes — TCP, IPv6",
                       uris: MyceliumPublicNodes.uris(proto: "tcp", ipv6: true)),
        ] + MyceliumPublicNodes.all.map {
            PeerPreset(title: "Node \($0.id) (\($0.region)) — tcp://\($0.ipv4):9651",
                       uris: ["tcp://\($0.ipv4):9651"])
        }
    }

    private var showLive: Bool { running && model.runtime.liveNote == nil }

    var body: some View {
        ServiceTabs(service: .mycelium,
                    peersBadge: peersBadge(configured: model.draft.peers,
                                           live: model.runtime.livePeers, showLive: showLive)) { tab in
            switch tab {
            case .status:
                Form {
                    StatusSection(
                        name: "Mycelium",
                        runtime: model.runtime,
                        extraRows: model.nodePublicKey.map { [("Public key", $0)] } ?? [],
                        install: { await model.installOrUpdate() },
                        start: { await model.start() },
                        stop: { await model.stop() },
                        restart: { await model.restart() },
                        setBoot: { await model.setStartAtBoot($0) },
                        canStart: model.tunNameProblem == nil)
                    if !model.runtime.isInstalled {
                        Section {
                            Text("Install downloads the latest release from github.com/threefoldtech/mycelium, checks it against GitHub's sha256 and installs it to \(MyceliumModel.binary). A launch daemon is created and the node starts with the peers from the Peers tab.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)

            case .peers:
                Form {
                    PeerListEditor(
                        title: "Peers",
                        peers: $model.draft.peers,
                        live: model.runtime.livePeers,
                        showLive: showLive,
                        schemes: MyceliumModel.peerSchemes,
                        placeholder: "tcp://host:9651  or  quic://[ipv6]:9651",
                        presets: presets,
                        footer: model.runtime.liveNote ?? model.runtime.liveSource
                            ?? "ThreeFold's hosted public nodes are all interconnected; connecting to several gives the best results.")
                    OtherConnectionsSection(
                        peers: PeerMatch.unmatched(model.runtime.livePeers, configured: model.draft.peers))
                }
                .formStyle(.grouped)

            case .node:
                Form { nodeSection }.formStyle(.grouped)

            case .network:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    Form { NetworkSection(snapshot: model.runtime.network, running: running) }
                        .formStyle(.grouped)
                }

            case .log:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    LogView(paths: [model.logPath])
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ApplyBar(
                isDirty: model.runtime.isInstalled && model.isDirty,
                busy: model.runtime.busy != nil,
                note: "Written to \(MyceliumModel.configPath)" + (running ? ", then Mycelium restarts." : "."),
                applyTitle: running ? "Apply & Restart" : "Apply",
                apply: { await model.apply() },
                revert: { model.revert() })
        }
    }

    private var notInstalled: some View {
        TabPlaceholder(symbol: "shippingbox", title: "Mycelium isn't installed",
                       message: "Install it from the Status tab.")
    }

    private var nodeSection: some View {
        Section("Node") {
            LabeledContent("TUN interface") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("", text: $model.draft.tunName, prompt: Text("utun20"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    if let problem = model.tunNameProblem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            LabeledContent("TCP listen port") {
                TextField("", value: $model.draft.tcpListenPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 100)
            }
            LabeledContent("QUIC listen port") {
                TextField("", value: $model.draft.quicListenPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 100)
            }
            Toggle("Disable QUIC", isOn: $model.draft.disableQuic)
            Toggle("Disable LAN peer discovery", isOn: $model.draft.disablePeerDiscovery)
            LabeledContent("HTTP API address") {
                TextField("", text: $model.draft.apiAddr, prompt: Text("127.0.0.1:8989"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            }
            if !model.draft.extra.isEmpty {
                LabeledContent("Other settings") {
                    Text(model.draft.extra.map { "\($0.key) = \($0.rawValue)" }.joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}
