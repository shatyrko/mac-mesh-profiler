import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("Networks") {
                    ForEach(ServiceID.allCases) { id in
                        SidebarRow(id: id, runtime: app.model(for: id).runtime,
                                   configuredPeers: app.model(for: id).configuredPeers)
                            .tag(SidebarItem.service(id))
                    }
                }
                Section("VPN") {
                    ForEach(app.vpn.services) { v in
                        VPNSidebarRow(vpn: v, busy: app.vpn.busy[v.id], issue: app.vpn.worstIssue(v.id))
                            .tag(SidebarItem.vpn(v.id))
                    }
                    WireGuardSidebarRow(model: app.wireguard)
                        .tag(SidebarItem.wireguard)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch app.selection {
            case .service(.yggdrasil): YggdrasilView(model: app.yggdrasil)
            case .service(.mycelium): MyceliumView(model: app.mycelium)
            case .vpn(let id): VPNView(id: id)
            case .wireguard: WireGuardView()
            case nil: Text("Select a network").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await app.checkForUpdates()
                        await app.refreshAll()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh status and check for updates")
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { clearErrors() }
        } message: {
            Text(currentError ?? "")
        }
    }

    private var title: String {
        switch app.selection {
        case .service(let id): return id.title
        case .vpn(let id): return app.vpn.service(id)?.name ?? "VPN"
        case .wireguard: return "WireGuard"
        case nil: return "Mac Mesh Profiler"
        }
    }

    private var currentError: String? {
        app.services.compactMap(\.runtime.lastError).first ?? app.vpn.lastError ?? app.wireguard.lastError
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { currentError != nil }, set: { if !$0 { clearErrors() } })
    }

    private func clearErrors() {
        for s in app.services { s.runtime.lastError = nil }
        app.vpn.lastError = nil
        app.wireguard.lastError = nil
    }
}

private struct WireGuardSidebarRow: View {
    let model: WireGuardModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("WireGuard")
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.busy != nil {
                ProgressView().controlSize(.mini)
            } else if let issue = model.worstIssue() {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(issue == .problem ? .red : .orange)
                    .help("The tunnel may be affecting the mesh — see Mesh check")
            } else {
                StatusDot(color: !model.running.isEmpty ? .green : (model.isInstalled ? .secondary : .red.opacity(0.6)))
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if let busy = model.busy { return busy }
        guard model.isInstalled else { return "Not installed" }
        let up = model.running
        if let first = up.first {
            return up.count == 1 ? "\(first.name) up" + (first.interface.map { " · \($0)" } ?? "")
                                 : "\(up.count) tunnels up"
        }
        if model.tunnels.isEmpty { return "No tunnels" }
        return model.tunnels.count == 1 ? "\(model.tunnels[0].name) down" : "\(model.tunnels.count) tunnels, none up"
    }
}

private struct VPNSidebarRow: View {
    let vpn: VPNService
    let busy: String?
    let issue: MeshCheckItem.Severity?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(vpn.name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if busy != nil {
                ProgressView().controlSize(.mini)
            } else if vpn.isConnected, let issue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(issue == .problem ? .red : .orange)
                    .help("The VPN may be affecting the mesh — see Mesh check")
            } else {
                StatusDot(color: VPNStatusColor.color(vpn.state))
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if let busy { return busy }
        if vpn.isConnected, let iface = vpn.interface { return "Connected · \(iface)" }
        return vpn.state.title
    }
}

private struct SidebarRow: View {
    let id: ServiceID
    let runtime: ServiceRuntime
    let configuredPeers: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: id.symbol)
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if runtime.busy != nil {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(color: StatusDot.color(runtime.health))
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        guard runtime.isInstalled else { return "Not installed" }
        if runtime.daemon.running {
            // Same count as the Peers tab: configured peers that are connected.
            guard !configuredPeers.isEmpty, runtime.liveNote == nil else { return "Running" }
            let up = configuredPeers.filter { PeerMatch.live(for: $0, in: runtime.livePeers)?.state == .up }.count
            return "Running · \(up)/\(configuredPeers.count) up"
        }
        return runtime.stateText
    }
}
