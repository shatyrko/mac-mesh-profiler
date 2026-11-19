import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("Networks") {
                    ForEach(ServiceID.allCases) { id in
                        SidebarRow(id: id, runtime: app.model(for: id).runtime)
                            .tag(id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch app.selection {
            case .yggdrasil: YggdrasilView(model: app.yggdrasil)
            case .mycelium: MyceliumView(model: app.mycelium)
            case nil: Text("Select a network").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(app.selection?.title ?? "Mac Mesh Profiler")
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

    private var currentError: String? {
        app.services.compactMap(\.runtime.lastError).first
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { currentError != nil }, set: { if !$0 { clearErrors() } })
    }

    private func clearErrors() {
        for s in app.services { s.runtime.lastError = nil }
    }
}

private struct SidebarRow: View {
    let id: ServiceID
    let runtime: ServiceRuntime

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
            let up = runtime.livePeers.filter { $0.state == .up }.count
            return runtime.livePeers.isEmpty ? "Running" : "Running · \(up) peer\(up == 1 ? "" : "s") up"
        }
        return runtime.stateText
    }
}
