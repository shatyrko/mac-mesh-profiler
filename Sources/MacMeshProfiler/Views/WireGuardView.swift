import SwiftUI

enum WireGuardTab: String, CaseIterable, Identifiable {
    case tunnels, mesh, routes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tunnels: return "Tunnels"
        case .mesh: return "Mesh check"
        case .routes: return "Routes & DNS"
        }
    }
}

struct WireGuardView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("tab.wireguard") private var tabRaw = WireGuardTab.tunnels.rawValue
    /// Which running tunnel the Mesh check / Routes tabs show.
    @State private var selectedTunnel: String?

    private var model: WireGuardModel { app.wireguard }
    private var tab: Binding<WireGuardTab> {
        Binding(get: { WireGuardTab(rawValue: tabRaw) ?? .tunnels }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: tab) {
                ForEach(WireGuardTab.allCases) { t in Text(title(t)).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Group {
                switch tab.wrappedValue {
                case .tunnels: WireGuardTunnelsTab()
                case .mesh, .routes: runningTab(tab.wrappedValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func title(_ t: WireGuardTab) -> String {
        guard t == .mesh else { return t.title }
        let items: [MeshCheckItem] = model.running.flatMap { (t: WGTunnel) -> [MeshCheckItem] in model.checks[t.name] ?? [] }
        let issues = items.filter { $0.severity == .problem || $0.severity == .warning }.count
        return issues > 0 ? "Mesh check (\(issues))" : t.title
    }

    @ViewBuilder
    private func runningTab(_ t: WireGuardTab) -> some View {
        let running = model.running
        if running.isEmpty {
            TabPlaceholder(symbol: "lock.open", title: "No WireGuard tunnel is up",
                           message: "Start a tunnel in the Tunnels tab to see its routes, DNS and effect on the mesh.")
        } else {
            let name = running.first { $0.name == selectedTunnel }?.name ?? running[0].name
            VStack(spacing: 0) {
                if running.count > 1 {
                    Picker("Tunnel", selection: Binding(get: { name }, set: { selectedTunnel = $0 })) {
                        ForEach(running) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
                }
                if let vpn = model.asVPN[name] {
                    if t == .mesh {
                        VPNMeshTab(vpn: vpn, items: model.checks[name] ?? [])
                    } else {
                        VPNRoutesTab(vpn: vpn)
                    }
                } else {
                    TabPlaceholder(symbol: "hourglass", title: "Checking…", message: "")
                }
            }
        }
    }
}

// MARK: - Tunnels

private struct WireGuardTunnelsTab: View {
    @Environment(AppModel.self) private var app
    private var model: WireGuardModel { app.wireguard }
    private var refresh: () async -> Void { { [app] in await app.refreshAll() } }

    var body: some View {
        Form {
            toolsSection

            if model.isInstalled {
                if model.tunnels.isEmpty {
                    Section {
                        Text("No tunnels in \(WireGuardConfig.directory). Import a .conf file — for example one downloaded from Proton VPN's WireGuard configuration page.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.tunnels) { t in TunnelSection(tunnel: t) }

                Section {
                    HStack {
                        Button("Import .conf…") { Task { await model.importConfig(refresh: refresh) } }
                        if model.tunnels.contains(where: { $0.summary == nil }) {
                            Button("Load details…") { Task { await model.loadDetails(refresh: refresh) } }
                        }
                        if !model.running.isEmpty {
                            Button("Show handshakes…") { Task { await model.loadStats(refresh: refresh) } }
                        }
                        Spacer()
                        if let busy = model.busy {
                            ProgressView().controlSize(.small)
                            Text(busy).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.busy != nil || app.isDemo)
                } footer: {
                    Text("Configs are kept in \(WireGuardConfig.directory) as root-only files, where `wg-quick up <name>` finds them. The app keeps only the settings shown here; private and preshared keys never leave those files. Up, down, import and handshakes ask for your password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let out = model.lastOutput, !out.isEmpty {
                Section("Last command output") {
                    ScrollView(.horizontal) {
                        Text(out).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var toolsSection: some View {
        Section {
            // Same pattern as Yggdrasil and Mycelium: version, then Install / Update inline.
            LabeledContent("Installed") {
                HStack(spacing: 8) {
                    Text(model.toolsVersion ?? "Not installed")
                        .foregroundStyle(model.isInstalled ? .primary : .secondary)
                    if model.brewPath != nil {
                        if !model.isInstalled {
                            Button("Install \(model.latestVersion ?? "latest")") {
                                Task { await model.install(refresh: refresh) }
                            }
                            .disabled(model.busy != nil || app.isDemo)
                        } else if model.updateAvailable, let v = model.latestVersion {
                            Button("Update to \(v)") { Task { await model.install(refresh: refresh) } }
                                .disabled(model.busy != nil || app.isDemo)
                        } else if model.latestVersion != nil {
                            Text("up to date").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            if !model.isInstalled {
                if model.brewPath == nil {
                    Text("Homebrew is needed to install wireguard-tools. Get it from brew.sh, then come back here.")
                        .foregroundStyle(.secondary)
                    Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                }
            }
        } header: {
            Text("WireGuard")
        } footer: {
            Text("Terminal WireGuard: `wg`, `wg-quick` and `wireguard-go` from Homebrew's wireguard-tools. Install runs `brew install wireguard-tools` as you, without a password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TunnelSection: View {
    let tunnel: WGTunnel
    @Environment(AppModel.self) private var app
    private var model: WireGuardModel { app.wireguard }
    private var refresh: () async -> Void { { [app] in await app.refreshAll() } }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                StatusDot(color: tunnel.running ? .green : .secondary)
                Text(tunnel.running ? "Up" + (tunnel.interface.map { " · \($0)" } ?? "") : "Down")
                Spacer()
                if tunnel.running {
                    Button("Stop") { Task { await model.down(tunnel.name, refresh: refresh) } }
                } else {
                    Button("Start") { Task { await model.up(tunnel.name, refresh: refresh) } }
                }
                Button("Remove…", role: .destructive) { Task { await model.remove(tunnel.name, refresh: refresh) } }
            }
            .disabled(model.busy != nil || app.isDemo)

            if let s = tunnel.summary {
                row("Address", s.addresses.joined(separator: ", "))
                if !s.dns.isEmpty { row("DNS", s.dns.joined(separator: ", ")) }
                if let key = s.publicKey { row("Public key", key, copy: true) }
                if let port = s.listenPort { row("Listen port", "\(port)") }
                if let mtu = s.mtu { row("MTU", "\(mtu)") }
                if let table = s.table { row("Table", table) }
                if tunnel.running {
                    row("Traffic", "↓ \(formatBytes(tunnel.rxBytes))  ↑ \(formatBytes(tunnel.txBytes))")
                }
                ForEach(Array(s.peers.enumerated()), id: \.offset) { i, p in
                    peerRows(p, index: i, count: s.peers.count)
                }
                if !s.hooks.isEmpty {
                    LabeledContent {
                        Text(s.hooks.joined(separator: "\n")).font(.caption.monospaced())
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    } label: {
                        Text("Hooks")
                        Text("Run as root by wg-quick")
                    }
                }
            } else {
                Text("Settings not loaded yet — use “Load details…” below (password).")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(tunnel.name)
        }
    }

    @ViewBuilder
    private func peerRows(_ p: WGPeerSummary, index: Int, count: Int) -> some View {
        let live = model.stats[tunnel.name]?.first { $0.publicKey == p.publicKey }
        let label = count > 1 ? "Peer \(index + 1)" : "Peer"
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.endpoint ?? "no endpoint").font(.body.monospaced())
                Text(p.allowedIPs.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let k = p.keepalive {
                    Text("keepalive \(k) s").font(.caption).foregroundStyle(.secondary)
                }
                if tunnel.running, let live {
                    HStack(spacing: 6) {
                        StatusDot(color: handshakeColor(live.latestHandshake))
                        Text(handshakeText(live.latestHandshake))
                        Text("↓ \(formatBytes(live.rxBytes))  ↑ \(formatBytes(live.txBytes))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .textSelection(.enabled)
        } label: {
            Text(label)
            Text(p.publicKey).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
        }
    }

    /// WireGuard re-handshakes every 2 minutes while traffic flows; older than 3 means the peer isn't answering.
    private func handshakeColor(_ d: Date?) -> Color {
        guard let d else { return .red }
        return Date().timeIntervalSince(d) < 180 ? .green : .orange
    }

    private func handshakeText(_ d: Date?) -> String {
        guard let d else { return "no handshake yet" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "handshake \(s) s ago" }
        return "handshake \(s / 60) min ago"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, copy: Bool = false) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value).font(.body.monospaced()).textSelection(.enabled)
                if copy { CopyButton(text: value) }
            }
        }
    }
}
