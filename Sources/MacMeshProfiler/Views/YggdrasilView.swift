import SwiftUI

struct YggdrasilView: View {
    @Bindable var model: YggdrasilModel

    private var loaded: Bool { model.saved != nil }
    private var running: Bool { model.runtime.daemon.running }

    private var showLive: Bool { running && model.runtime.liveNote == nil }

    var body: some View {
        ServiceTabs(service: .yggdrasil,
                    peersBadge: loaded ? peersBadge(configured: model.draft.peers,
                                                    live: model.runtime.livePeers, showLive: showLive) : nil) { tab in
            switch tab {
            case .status:
                Form {
                    statusSection
                    if model.runtime.isInstalled { configSourceSection }
                }
                .formStyle(.grouped)

            case .peers:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    Form {
                        if !loaded { configSourceSection }
                        PeerListEditor(
                            title: "Peers",
                            peers: $model.draft.peers,
                            live: model.runtime.livePeers,
                            showLive: showLive,
                            schemes: YggdrasilModel.peerSchemes,
                            placeholder: "tls://host:port",
                            footer: peersFooter,
                            disabled: !loaded,
                            emptyText: loaded ? "No peers configured." : "Load the configuration above to see and edit peers.")
                        OtherConnectionsSection(
                            peers: PeerMatch.unmatched(model.runtime.livePeers, configured: model.draft.peers))
                    }
                    .formStyle(.grouped)
                }

            case .node:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    Form {
                        if !loaded { configSourceSection }
                        nodeSection
                    }
                    .formStyle(.grouped)
                }

            case .network:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    Form {
                        NetworkSection(snapshot: model.runtime.network, running: running) { path in
                            path == "/var/run/yggdrasil.sock" ? "Admin socket (root only)" : "Unix socket"
                        }
                    }
                    .formStyle(.grouped)
                }

            case .log:
                if !model.runtime.isInstalled {
                    notInstalled
                } else {
                    LogView(paths: model.logPaths)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ApplyBar(
                isDirty: model.isDirty,
                busy: model.runtime.busy != nil,
                note: "Written to \(YggdrasilModel.configPath) (previous version kept as .bak)"
                    + (running ? ", then Yggdrasil restarts." : "."),
                applyTitle: running ? "Apply & Restart" : "Apply",
                apply: { await model.apply() },
                revert: { model.revert() })
        }
    }

    private var statusSection: some View {
        StatusSection(
            name: "Yggdrasil",
            runtime: model.runtime,
            extraRows: model.publicKey.map { [("Public key", $0)] } ?? [],
            install: { await model.installOrUpdate() },
            start: { await model.start() },
            stop: { await model.stop() },
            restart: { await model.restart() },
            setBoot: { await model.setStartAtBoot($0) },
            canStart: model.runtime.daemon.plistInstalled)
    }

    private var notInstalled: some View {
        TabPlaceholder(symbol: "shippingbox", title: "Yggdrasil isn't installed",
                       message: "Install it from the Status tab.")
    }

    private var peersFooter: String {
        var parts: [String] = []
        if let note = model.runtime.liveNote { parts.append(note) }
        if running && model.runtime.liveNote == nil && !(model.saved?.adminListen.hasPrefix("tcp://") ?? false) {
            parts.append("Green = connected, red = no open connection (from netstat). Turn on the local admin API in the Node tab for latency and error details.")
        }
        parts.append("Pick a few peers close to you. Public peers: publicpeers.neilalexander.dev")
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private var configSourceSection: some View {
        Section {
            if let at = model.savedAt {
                LabeledContent("Configuration") {
                    HStack {
                        Text("Read from \(YggdrasilModel.configPath) \(at.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                        Button("Reload") { Task { await model.loadFromSystem() } }
                            .disabled(model.runtime.busy != nil)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Load the current configuration")
                        .font(.headline)
                    Text("\(YggdrasilModel.configPath) is readable only by root, so the app asks for your password once to read the peers and listen addresses. Your private key is never read into the app.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Load from \(YggdrasilModel.configPath)") { Task { await model.loadFromSystem() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.runtime.busy != nil)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var nodeSection: some View {
        Section {
            StringListEditor(label: "Listen addresses (for incoming peerings)",
                             items: $model.draft.listen,
                             placeholder: "tls://[::]:0")
            TextField("TUN interface", text: $model.draft.ifName, prompt: Text("auto"))
            Toggle(isOn: Binding(
                get: { model.draft.adminListen.hasPrefix("tcp://") },
                set: { model.draft.adminListen = $0 ? YggdrasilModel.localTCPAdmin : "" })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local admin API on \(YggdrasilModel.localTCPAdmin)")
                    Text("Lets this app show live peer status without asking for a password. Any program on this Mac can then query and control the node.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.draft.adminListen.isEmpty,
               model.draft.adminListen != YggdrasilModel.localTCPAdmin {
                LabeledContent("AdminListen", value: model.draft.adminListen)
            }
        } header: {
            Text("Node")
        }
        .disabled(!loaded)
    }
}
