import AppKit
import SwiftUI

@main
struct MacMeshProfilerApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("Mac Mesh Profiler", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Status") { Task { await app.refreshAll() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            Image(systemName: app.anyRunning
                  ? "point.3.filled.connected.trianglepath.dotted"
                  : "point.3.connected.trianglepath.dotted")
        }
    }
}
