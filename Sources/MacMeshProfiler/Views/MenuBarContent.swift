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
        Button("Open Mac Mesh Profiler…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func canStart(_ id: ServiceID) -> Bool {
        switch id {
        case .yggdrasil: return app.yggdrasil.runtime.daemon.plistInstalled
        case .mycelium: return app.mycelium.tunNameProblem == nil
        }
    }
}
