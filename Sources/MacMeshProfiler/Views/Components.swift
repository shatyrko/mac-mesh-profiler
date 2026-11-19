import AppKit
import SwiftUI

// MARK: - Small pieces

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    static func color(_ h: ServiceRuntime.Health) -> Color {
        switch h {
        case .running: return .green
        case .degraded: return .orange
        case .stopped: return .secondary
        case .missing: return .red.opacity(0.6)
        }
    }

    static func color(_ s: PeerState?) -> Color {
        switch s {
        case .up: return .green
        case .connecting: return .orange
        case .down: return .red
        case .unknown, nil: return .secondary.opacity(0.5)
        }
    }
}

struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

enum PeerMatch {
    static func normalize(_ uri: String) -> String {
        var s = uri.lowercased()
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func live(for configured: String, in live: [LivePeer]) -> LivePeer? {
        let key = normalize(configured)
        return live.first { $0.kind != "inbound" && normalize($0.endpoint) == key }
    }

    /// Live connections that don't correspond to a configured peer (inbound, LAN discovery…).
    static func unmatched(_ live: [LivePeer], configured: [String]) -> [LivePeer] {
        let keys = Set(configured.map(normalize))
        return live.filter { $0.kind == "inbound" || !keys.contains(normalize($0.endpoint)) }
    }
}

// MARK: - Status section

struct StatusSection: View {
    let name: String
    let runtime: ServiceRuntime
    var extraRows: [(String, String)] = []
    let install: () async -> Void
    let start: () async -> Void
    let stop: () async -> Void
    let restart: () async -> Void
    let setBoot: (Bool) async -> Void
    var canStart: Bool = true

    var body: some View {
        Section {
            if runtime.lastRefresh == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking status…").foregroundStyle(.secondary)
                }
            } else {
                rows
            }
        } header: {
            HStack {
                Text(name)
                Spacer()
                if let busy = runtime.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
            LabeledContent("Installed") {
                HStack(spacing: 8) {
                    Text(runtime.installedVersion ?? "Not installed")
                        .foregroundStyle(runtime.isInstalled ? .primary : .secondary)
                    if !runtime.isInstalled {
                        Button("Install \(runtime.latestRelease?.version ?? "latest")") { Task { await install() } }
                    } else if runtime.updateAvailable, let v = runtime.latestRelease?.version {
                        Button("Update to \(v)") { Task { await install() } }
                    } else if runtime.latestRelease != nil {
                        Text("up to date").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if runtime.isInstalled {
                LabeledContent("Service") {
                    HStack(spacing: 6) {
                        StatusDot(color: StatusDot.color(runtime.health))
                        Text(runtime.stateText)
                        if !runtime.daemon.running, let exit = runtime.daemon.lastExit, runtime.daemon.loaded {
                            Text("last exit: \(exit)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Overlay address") {
                    if let addr = runtime.address {
                        HStack(spacing: 6) {
                            Text(addr.address).font(.body.monospaced()).textSelection(.enabled)
                            if !addr.interface.isEmpty {
                                Text(addr.interface).font(.caption).foregroundStyle(.secondary)
                            }
                            CopyButton(text: addr.address)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }

                ForEach(extraRows, id: \.0) { row in
                    LabeledContent(row.0) {
                        HStack(spacing: 6) {
                            Text(row.1).font(.caption.monospaced()).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            CopyButton(text: row.1)
                        }
                    }
                }

                Toggle("Start at boot", isOn: Binding(
                    get: { runtime.daemon.startsAtBoot },
                    set: { on in Task { await setBoot(on) } }))
                    .disabled(!runtime.daemon.plistInstalled || runtime.busy != nil)

                HStack {
                    if runtime.daemon.running {
                        Button { Task { await stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                        Button { Task { await restart() } } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                    } else {
                        Button { Task { await start() } } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStart)
                    }
                    Spacer()
                }
                .disabled(runtime.busy != nil)
            }
    }
}

// MARK: - Peer list editor

struct PeerPreset: Identifiable {
    let id = UUID()
    let title: String
    let uris: [String]
}

struct PeerListEditor: View {
    let title: String
    @Binding var peers: [String]
    let live: [LivePeer]
    let showLive: Bool
    let schemes: [String]
    let placeholder: String
    var presets: [PeerPreset] = []
    var footer: String?
    var disabled = false
    var emptyText = "No peers configured."

    @State private var newPeer = ""
    @State private var showPaste = false
    /// The peer currently being edited in place, and its working text.
    @State private var editing: String?
    @State private var editText = ""

    var body: some View {
        Section {
            if peers.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(peers, id: \.self) { peer in
                PeerRow(peer: peer, live: showLive ? PeerMatch.live(for: peer, in: live) : nil,
                        showLive: showLive,
                        valid: PeerText.isValid(peer, schemes: schemes),
                        isEditing: editing == peer,
                        editText: $editText,
                        beginEdit: { beginEdit(peer) },
                        commitEdit: commitEdit,
                        cancelEdit: { editing = nil },
                        remove: {
                            if editing == peer { editing = nil }
                            peers.removeAll { $0 == peer }
                        })
            }
            HStack {
                TextField("Add peer", text: $newPeer, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newPeer.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu {
                    Button("Paste a list of peers…") { showPaste = true }
                    if !presets.isEmpty {
                        Divider()
                        ForEach(presets) { preset in
                            Button(preset.title) { add(preset.uris) }
                        }
                    }
                    if !peers.isEmpty {
                        Divider()
                        Button("Remove all peers", role: .destructive) { peers.removeAll() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(disabled)
        .sheet(isPresented: $showPaste) {
            PastePeersSheet(schemes: schemes) { add($0) }
        }
    }

    private func addTyped() {
        let text = newPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let extracted = PeerText.extract(from: text, schemes: schemes)
        add(extracted.isEmpty ? [text] : extracted)
        newPeer = ""
    }

    private func add(_ uris: [String]) {
        for u in uris where !peers.contains(u) { peers.append(u) }
    }

    private func beginEdit(_ peer: String) {
        editText = peer
        editing = peer
    }

    /// Replaces the edited peer in place (keeping its position). An empty value
    /// removes it; a value that duplicates another peer just drops the edit.
    private func commitEdit() {
        guard let original = editing, let index = peers.firstIndex(of: original) else {
            editing = nil
            return
        }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            peers.remove(at: index)
        } else if text != original, !peers.contains(text) {
            peers[index] = text
        }
        editing = nil
    }
}

private struct PeerRow: View {
    let peer: String
    let live: LivePeer?
    let showLive: Bool
    let valid: Bool
    let isEditing: Bool
    @Binding var editText: String
    let beginEdit: () -> Void
    let commitEdit: () -> Void
    let cancelEdit: () -> Void
    let remove: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showLive {
                StatusDot(color: StatusDot.color(live?.state))
                    .help(live.map { "\($0.state.rawValue)" + ($0.lastError.map { ": \($0)" } ?? "") } ?? "not connected")
            }
            if isEditing {
                TextField("Peer", text: $editText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($focused)
                    .onSubmit(commitEdit)
                    .onExitCommand(perform: cancelEdit)
                    .onAppear { focused = true }
                Button(action: commitEdit) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Save (Return)")
                Button(action: cancelEdit) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel (Esc)")
            } else {
                Text(peer).font(.body.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEdit)
                    .help("Double-click to edit")
                if !valid {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        .help("This doesn't look like a valid peer URI for this network.")
                }
                Spacer()
                if let live {
                    if let ms = live.latencyMs {
                        Text(String(format: "%.0f ms", ms)).font(.caption).foregroundStyle(.secondary)
                    }
                    if live.rxBytes != nil || live.txBytes != nil {
                        Text("↓\(formatBytes(live.rxBytes)) ↑\(formatBytes(live.txBytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Button(action: beginEdit) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit peer")
            }
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help("Remove peer")
        }
        .contextMenu {
            Button("Edit", action: beginEdit)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(peer, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

struct PastePeersSheet: View {
    let schemes: [String]
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var found: [String] { PeerText.extract(from: text, schemes: schemes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste peers").font(.headline)
            Text("Paste any text — a public peers list, a chat message, a config snippet. Every \(schemes.joined(separator: "/"))://… address in it will be added.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("\(found.count) peer\(found.count == 1 ? "" : "s") found")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(found.count)") {
                    onAdd(found)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(found.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Simple string list editor (listen addresses)

struct StringListEditor: View {
    let label: String
    @Binding var items: [String]
    let placeholder: String

    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button { items.removeAll { $0 == item } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("", text: $newItem, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("Add", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !items.contains(t) else { return }
        items.append(t)
        newItem = ""
    }
}

// MARK: - Other live connections

struct OtherConnectionsSection: View {
    let peers: [LivePeer]

    var body: some View {
        if !peers.isEmpty {
            Section("Other live connections") {
                ForEach(peers) { p in
                    HStack(spacing: 8) {
                        StatusDot(color: StatusDot.color(p.state))
                        Text(p.endpoint).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(p.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let ms = p.latencyMs {
                            Text(String(format: "%.0f ms", ms)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("↓\(formatBytes(p.rxBytes)) ↑\(formatBytes(p.txBytes))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Log viewer

/// Full-height log viewer used by the Log tab: newest lines at the bottom,
/// refreshed every 3 seconds while visible.
struct LogView: View {
    let paths: [String]
    @State private var text = ""

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Loading…" : text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .defaultScrollAnchor(.bottom)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                // Scroll after the new text has been laid out.
                .onChange(of: text) {
                    DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            HStack {
                ForEach(paths, id: \.self) { p in
                    Button("Reveal \((p as NSString).lastPathComponent)") {
                        NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.link)
                    .disabled(!FileManager.default.fileExists(atPath: p))
                }
                Spacer()
                Text("Last 200 lines · updates every 3 s").font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { load() }.buttonStyle(.link)
            }
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func load() {
        var parts: [String] = []
        for p in paths {
            guard let t = tailFile(p, maxLines: 200), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parts.append(paths.count > 1 ? "── \(p) ──\n\(t)" : t)
        }
        let joined = parts.isEmpty ? "No log output at \(paths.joined(separator: ", "))" : parts.joined(separator: "\n\n")
        let ns = joined as NSString
        let cleaned = Self.ansi.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: ns.length),
                                                         withTemplate: "")
        text = String(cleaned.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }.map(Character.init))
    }
}

// MARK: - Tabs

enum ServiceTab: String, CaseIterable, Identifiable {
    case status, peers, node, network, log
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "Status"
        case .peers: return "Peers"
        case .node: return "Node"
        case .network: return "Network"
        case .log: return "Log"
        }
    }
}

/// Segmented tab bar on top, the selected tab's content below. The selected
/// tab is remembered per service.
struct ServiceTabs<Content: View>: View {
    let service: ServiceID
    /// Shown next to "Peers", e.g. "1/3" connected.
    var peersBadge: String?
    @ViewBuilder let content: (ServiceTab) -> Content

    @AppStorage private var tabRaw: String

    init(service: ServiceID, peersBadge: String?, @ViewBuilder content: @escaping (ServiceTab) -> Content) {
        self.service = service
        self.peersBadge = peersBadge
        self.content = content
        _tabRaw = AppStorage(wrappedValue: ServiceTab.status.rawValue, "tab." + service.rawValue)
    }

    private var tab: Binding<ServiceTab> {
        Binding(get: { ServiceTab(rawValue: tabRaw) ?? .status }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: tab) {
                ForEach(ServiceTab.allCases) { t in
                    Text(t == .peers && peersBadge != nil ? "Peers \(peersBadge!)" : t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            content(tab.wrappedValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Placeholder for tabs that need the service installed or running.
struct TabPlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "1/3" when live status is known, nil otherwise.
func peersBadge(configured: [String], live: [LivePeer], showLive: Bool) -> String? {
    guard showLive, !configured.isEmpty else { return configured.isEmpty ? nil : "\(configured.count)" }
    let up = configured.filter { PeerMatch.live(for: $0, in: live)?.state == .up }.count
    return "\(up)/\(configured.count)"
}

// MARK: - Apply bar

struct ApplyBar: View {
    let isDirty: Bool
    let busy: Bool
    let note: String
    let applyTitle: String
    let apply: () async -> Void
    let revert: () -> Void

    var body: some View {
        if isDirty {
            HStack(spacing: 12) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unsaved changes").font(.headline)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert", action: revert).disabled(busy)
                Button(applyTitle) { Task { await apply() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
                    .disabled(busy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

// MARK: - Network (ports + interfaces)

struct NetworkSection: View {
    let snapshot: NetworkSnapshot
    let running: Bool
    var unixSocketLabel: (String) -> String = { _ in "Unix socket" }

    var body: some View {
        Section {
            if !running {
                Text("The service isn't running, so nothing is listening.").foregroundStyle(.secondary)
            } else {
                Text("Listening ports").font(.subheadline.weight(.semibold))
                if snapshot.listening.isEmpty && snapshot.unixSockets.isEmpty {
                    Text("None found.").foregroundStyle(.secondary)
                }
                ForEach(snapshot.listening) { s in
                    HStack(spacing: 10) {
                        Text(s.proto)
                            .font(.caption.monospaced().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((s.proto == "TCP" ? Color.blue : Color.purple).opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 4))
                        Text(verbatim: "\(s.port)")
                            .font(.body.monospaced().weight(.medium))
                            .frame(minWidth: 54, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.purpose)
                            Text(verbatim: s.address == "all"
                                 ? s.family
                                 : "\(s.address) · \(s.family)" + (s.interface.isEmpty ? "" : " · \(s.interface)"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if s.interface == "all" {
                            Text("all interfaces").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
                ForEach(snapshot.unixSockets, id: \.self) { path in
                    HStack(spacing: 10) {
                        Text("UNIX")
                            .font(.caption.monospaced().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(unixSocketLabel(path))
                            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .textSelection(.enabled)
                }

                Text("Interfaces").font(.subheadline.weight(.semibold)).padding(.top, 4)
                if snapshot.interfaces.isEmpty {
                    Text("None found.").foregroundStyle(.secondary)
                }
                ForEach(snapshot.interfaces) { i in
                    HStack(alignment: .top, spacing: 10) {
                        StatusDot(color: i.isUp ? .green : .secondary).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(i.name).font(.body.monospaced().weight(.medium))
                                if let mtu = i.mtu {
                                    Text(verbatim: "MTU \(mtu)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(i.roles.joined(separator: " · ")).font(.caption)
                            ForEach(i.addresses, id: \.self) { a in
                                Text(a).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .textSelection(.enabled)
                }
                if snapshot.establishedCount > 0 {
                    Text("\(snapshot.establishedCount) established peer connection\(snapshot.establishedCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Network")
        } footer: {
            if running {
                Text("From netstat and ifconfig, refreshed every 5 seconds. Link-local addresses are shortened by netstat and matched to their interface by prefix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
