import SwiftUI

enum VPNStatusColor {
    static func color(_ s: VPNState) -> Color {
        switch s {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .invalid: return .red.opacity(0.6)
        case .disconnected, .unknown: return .secondary
        }
    }
}

enum VPNTab: String, CaseIterable, Identifiable {
    case status, mesh, routes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "Status"
        case .mesh: return "Mesh check"
        case .routes: return "Routes & DNS"
        }
    }
}

struct VPNView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @AppStorage("tab.vpn") private var tabRaw = VPNTab.status.rawValue

    private var tab: Binding<VPNTab> {
        Binding(get: { VPNTab(rawValue: tabRaw) ?? .status }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        if let vpn = app.vpn.service(id) {
            VStack(spacing: 0) {
                Picker("Section", selection: tab) {
                    ForEach(VPNTab.allCases) { t in
                        Text(title(t, vpn)).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

                Group {
                    switch tab.wrappedValue {
                    case .status: VPNStatusTab(vpn: vpn)
                    case .mesh: VPNMeshTab(vpn: vpn, items: app.vpn.checks[vpn.id] ?? [])
                    case .routes: VPNRoutesTab(vpn: vpn)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            TabPlaceholder(symbol: "lock.shield", title: "VPN not found",
                           message: "This VPN configuration is no longer in System Settings.")
        }
    }

    private func title(_ t: VPNTab, _ vpn: VPNService) -> String {
        guard t == .mesh else { return t.title }
        let issues = (app.vpn.checks[vpn.id] ?? []).filter { $0.severity == .problem || $0.severity == .warning }.count
        return issues > 0 ? "Mesh check (\(issues))" : t.title
    }
}

// MARK: - Status

private struct VPNStatusTab: View {
    let vpn: VPNService
    @Environment(AppModel.self) private var app

    private var busy: String? { app.vpn.busy[vpn.id] }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if let busy {
                            ProgressView().controlSize(.small)
                            Text(busy)
                        } else {
                            StatusDot(color: VPNStatusColor.color(vpn.state))
                            Text(vpn.state.title)
                        }
                    }
                }
                HStack {
                    if (vpn.isConnected || vpn.state == .connecting) && vpn.onDemand == true {
                        // macOS reconnects on-demand VPNs right after a stop; only the owning app can turn it off.
                        Button("Disconnect") {}.disabled(true)
                            .help("Connect on demand is on, so macOS would reconnect it at once. Disconnect it in the VPN's own app.")
                    } else if vpn.isConnected || vpn.state == .connecting {
                        Button("Disconnect") {
                            Task { await app.vpn.disconnect(vpn.id, meshes: { app.meshContexts() }) }
                        }
                    } else {
                        Button("Connect") {
                            Task { await app.vpn.connect(vpn.id, meshes: { app.meshContexts() }) }
                        }
                        .disabled(!vpn.enabled)
                    }
                    if let appName = app.vpn.owningAppName(vpn) {
                        Button("Open \(appName)") { app.vpn.openOwningApp(vpn) }
                    }
                    Spacer()
                }
                .disabled(busy != nil || app.isDemo)

                row("Server", vpn.server, copy: true)
                row("Type", vpn.type + (vpn.providerBundleID.map { " · \($0)" } ?? ""))
                if vpn.isConnected {
                    row("Tunnel interface", vpn.interface ?? "not found")
                    ForEach(vpn.addresses, id: \.self) { a in row("Address", a, copy: true) }
                    if let primary = vpn.isPrimary {
                        row("Carries default traffic", primary ? "Yes" : "No")
                    }
                    if !vpn.dnsServers.isEmpty {
                        row("DNS servers", vpn.dnsServers.joined(separator: ", "))
                    }
                }
                if let onDemand = vpn.onDemand {
                    row("Connect on demand", onDemand ? "On" : "Off")
                }
                if !vpn.enabled {
                    Text("This VPN is disabled in System Settings.").foregroundStyle(.secondary)
                }
                if vpn.isConnected && vpn.onDemand == true {
                    Label("Connect on demand is on, so macOS reconnects this VPN as soon as it's stopped. Disconnect it in \(app.vpn.owningAppName(vpn) ?? "the VPN's own app").",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Connect and Disconnect use `scutil --nc`, the same switch as System Settings › VPN. Choosing a server and signing in stay in the VPN's own app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let f = vpn.flags {
                Section {
                    flag("Include all networks", f.includeAllNetworks,
                         "Forces all traffic into the VPN regardless of routes — how a kill switch is usually built.")
                    flag("Exclude local networks", f.excludeLocalNetworks,
                         "LAN traffic bypasses the VPN (only matters with include all networks).")
                    flag("Enforce routes", f.enforceRoutes,
                         "The VPN's routes win even over more specific routes of other interfaces.")
                    flag("Exclude device communication", f.excludeDeviceCommunication, nil)
                    flag("Exclude cellular services", f.excludeCellularServices, nil)
                    flag("Exclude push notifications", f.excludeAPNs, nil)
                } header: {
                    Text("macOS VPN settings")
                } footer: {
                    Text("Read from \(NEPreferences.path), which any user can read. Passwords and keys stored there are not read.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(vpn.companions) { c in
                Section {
                    row("Kind", c.kind)
                    if let p = c.providerBundleID { row("Provider", p) }
                    if let mode = c.splitMode { row("Mode", mode) }
                    ForEach(c.settings.filter { $0.key != "plutoniumMode" }) { kv in
                        row(kv.key, kv.value)
                    }
                } header: {
                    Text(c.name)
                } footer: {
                    if !c.excludedIPs.isEmpty {
                        Text("Addresses listed in “ips” bypass the VPN; the Mesh check counts mesh peers in it as excluded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !vpn.vendorSettings.isEmpty {
                Section {
                    ForEach(vpn.vendorSettings) { kv in row(kv.key, kv.value) }
                } header: {
                    Text("App settings")
                } footer: {
                    Text("Shown by `scutil --nc show`. Values that look like identifiers or secrets are hidden.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, copy: Bool = false) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value ?? "—").textSelection(.enabled)
                    .font(.body.monospaced())
                if copy, let value { CopyButton(text: value) }
            }
        }
    }

    @ViewBuilder
    private func flag(_ label: String, _ value: Bool?, _ help: String?) -> some View {
        LabeledContent {
            Text(value.map { $0 ? "On" : "Off" } ?? "—")
                .foregroundStyle(value == true && label == "Include all networks" ? .orange : .primary)
        } label: {
            Text(label)
            if let help { Text(help) }
        }
    }
}

// MARK: - Mesh check

struct VPNMeshTab: View {
    let vpn: VPNService
    let items: [MeshCheckItem]

    var body: some View {
        Form {
            Section {
                if !vpn.isConnected {
                    Label("Connect \(vpn.name) to check routes and peers. Until then only its stored settings are checked.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        icon(item.severity).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).fontWeight(.medium)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Effect on Yggdrasil and Mycelium")
            } footer: {
                Text("Uses the routing table (`route -n get`) and the VPN's stored macOS settings. Per-app and per-flow rules of a VPN aren't visible in the routing table, so a peer shown as “routed into the VPN” may still bypass it if the VPN app excludes it in a way macOS doesn't expose. Refreshed every 5 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func icon(_ s: MeshCheckItem.Severity) -> some View {
        switch s {
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - Routes & DNS

struct VPNRoutesTab: View {
    let vpn: VPNService
    @State private var showRaw = false

    var body: some View {
        if !vpn.isConnected {
            TabPlaceholder(symbol: "arrow.triangle.branch", title: "\(vpn.name) isn't connected",
                           message: "Routes and DNS settings appear here while the VPN is connected.")
        } else {
            Form {
                Section {
                    if vpn.routes.isEmpty {
                        Text(vpn.interface == nil ? "The tunnel interface couldn't be found." : "No routes found.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vpn.routes) { r in
                        HStack(spacing: 10) {
                            Text(r.family == "IPv4" ? "v4" : "v6")
                                .font(.caption.monospaced().weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((r.family == "IPv4" ? Color.blue : Color.purple).opacity(0.18),
                                            in: RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.destination).font(.body.monospaced())
                                Text("via \(r.gateway) · flags \(r.flags)" + (r.scoped ? " · scoped to the interface" : ""))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .opacity(r.scoped ? 0.6 : 1)
                        .textSelection(.enabled)
                    }
                } header: {
                    Text("Routes through \(vpn.interface ?? "the tunnel")")
                } footer: {
                    Text("From `netstat -rn`, without host routes cached on use (flag W). Scoped routes (flag I) only apply to traffic bound to that interface; unscoped default routes send everything else into the VPN.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if vpn.resolvers.isEmpty {
                        Text(vpn.dnsServers.isEmpty ? "The VPN doesn't set DNS."
                                                    : "DNS servers: \(vpn.dnsServers.joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vpn.resolvers) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.isDefault ? "Default resolver (#\(r.index))"
                                 : "Resolver #\(r.index)" + (r.domain.map { " for \($0)" } ?? "")
                                   + (r.supplemental ? " · supplemental" : ""))
                                .fontWeight(.medium)
                            Text(r.nameservers.joined(separator: ", ")).font(.caption.monospaced())
                            if !r.searchDomains.isEmpty {
                                Text("search: " + r.searchDomains.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } header: {
                    Text("DNS")
                } footer: {
                    Text("From `scutil --dns`. Mesh traffic itself doesn't use DNS; only peer host names are resolved through it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !vpn.rawStatus.isEmpty {
                Section {
                    Button(showRaw ? "Hide raw status" : "Show raw status") { showRaw.toggle() }
                        .buttonStyle(.link)
                    if showRaw {
                        Text(vpn.rawStatus).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("`scutil --nc status \(vpn.id)`").font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            .formStyle(.grouped)
        }
    }
}
