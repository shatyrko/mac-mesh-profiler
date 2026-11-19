import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(ServiceID.allCases) { id in
            let model = app.model(for: id)
            let rt = model.runtime
            Text("\(id.title) — \(rt.busy ?? rt.stateText)")
            if let addr = rt.address?.address {
                Button("Copy \(addr)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(addr, forType: .string)
                }
            }
            if rt.isInstalled {
                if rt.daemon.running {
                    Button("Stop \(id.title)") { Task { await model.stop() } }
                        .disabled(rt.busy != nil)
                    Button("Restart \(id.title)") { Task { await model.restart() } }
                        .disabled(rt.busy != nil)
                } else {
                    Button("Start \(id.title)") { Task { await model.start() } }
                        .disabled(rt.busy != nil || !canStart(id))
                }
            }
            Divider()
        }
        if !app.vpn.services.isEmpty {
            ForEach(app.vpn.services) { v in
                Text("\(v.name) — \(app.vpn.busy[v.id] ?? vpnState(v))")
                if (v.isConnected || v.state == .connecting) && v.onDemand == true {
                    Button("Disconnect in \(app.vpn.owningAppName(v) ?? "its app")…") { app.vpn.openOwningApp(v) }
                } else if v.isConnected || v.state == .connecting {
                    Button("Disconnect \(v.name)") {
                        Task { await app.vpn.disconnect(v.id, meshes: { app.meshContexts() }) }
                    }
                    .disabled(app.vpn.busy[v.id] != nil || app.isDemo)
                } else if v.enabled {
                    Button("Connect \(v.name)") {
                        Task { await app.vpn.connect(v.id, meshes: { app.meshContexts() }) }
                    }
                    .disabled(app.vpn.busy[v.id] != nil || app.isDemo)
                }
            }
            Divider()
        }
        if app.wireguard.isInstalled && !app.wireguard.tunnels.isEmpty {
            ForEach(app.wireguard.tunnels) { t in
                Text("WireGuard \(t.name) — \(t.running ? "Up" : "Down")")
                Button(t.running ? "Stop \(t.name)" : "Start \(t.name)") {
                    Task {
                        if t.running { await app.wireguard.down(t.name, refresh: { await app.refreshAll() }) }
                        else { await app.wireguard.up(t.name, refresh: { await app.refreshAll() }) }
                    }
                }
                .disabled(app.wireguard.busy != nil || app.isDemo)
            }
            Divider()
        }
        Button("Open Mac Mesh Profiler…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func vpnState(_ v: VPNService) -> String {
        guard v.isConnected else { return v.state.title }
        if let issue = app.vpn.worstIssue(v.id) {
            return issue == .problem ? "Connected · blocks the mesh" : "Connected · affects the mesh"
        }
        return "Connected"
    }

    private func canStart(_ id: ServiceID) -> Bool {
        switch id {
        case .yggdrasil: return app.yggdrasil.runtime.daemon.plistInstalled
        case .mycelium: return app.mycelium.tunNameProblem == nil
        }
    }
}
