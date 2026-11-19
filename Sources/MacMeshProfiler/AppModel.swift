import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let yggdrasil = YggdrasilModel()
    let mycelium = MyceliumModel()
    let vpn = VPNModel()
    let wireguard = WireGuardModel()
    var selection: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "lastSelection") ?? "")
        ?? .service(.yggdrasil) {
        didSet { UserDefaults.standard.set(selection?.rawValue, forKey: "lastSelection") }
    }

    private var pollTask: Task<Void, Never>?

    var services: [any MeshServiceModel] { [yggdrasil, mycelium] }

    func model(for id: ServiceID) -> any MeshServiceModel {
        switch id {
        case .yggdrasil: return yggdrasil
        case .mycelium: return mycelium
        }
    }

    var anyRunning: Bool { services.contains { $0.runtime.daemon.running } }

    /// `-demo YES` on the command line: sample data, no polling, no system access.
    /// Used to take README screenshots without exposing a real node.
    let isDemo = UserDefaults.standard.bool(forKey: "demo")

    init() {
        if isDemo {
            Demo.apply(to: self)
            return
        }
        pollTask = Task { [weak self] in
            await self?.refreshAll()
            Task { [weak self] in await self?.checkForUpdates() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.refreshAll()
            }
        }
    }

    func refreshAll() async {
        async let a: Void = yggdrasil.refresh()
        async let b: Void = mycelium.refresh()
        _ = await (a, b)
        // After the meshes, so the VPN check sees their current TUNs and peers.
        let meshes = meshContexts()
        await vpn.refresh(meshes: meshes)
        await wireguard.refresh(vpnInterfaces: Set(vpn.services.compactMap(\.interface)), meshes: meshes)
    }

    /// What the VPN check needs from each mesh.
    func meshContexts() -> [MeshContext] {
        func context(_ m: any MeshServiceModel, probe: String, range: String) -> MeshContext {
            let rt = m.runtime
            let liveKnown = rt.daemon.running && rt.liveNote == nil
            let up = m.configuredPeers.filter { PeerMatch.live(for: $0, in: rt.livePeers)?.state == .up }.count
            return MeshContext(name: m.id.title, running: rt.daemon.running, tun: rt.address?.interface,
                               probe: probe, overlayRange: range, configuredPeers: m.configuredPeers,
                               peersUp: liveKnown ? up : nil)
        }
        return [context(yggdrasil, probe: "200::1", range: "200::/7"),
                context(mycelium, probe: "400::1", range: "400::/7")]
    }

    func checkForUpdates() async {
        async let a: Void = yggdrasil.checkForUpdate()
        async let b: Void = mycelium.checkForUpdate()
        async let c: Void = wireguard.checkForUpdate()
        _ = await (a, b, c)
    }
}

/// A row in the sidebar: one of the mesh services, or a system VPN by its UUID.
enum SidebarItem: Hashable {
    case service(ServiceID)
    case vpn(String)
    case wireguard

    init?(rawValue: String) {
        if rawValue == "wireguard" {
            self = .wireguard
        } else if rawValue.hasPrefix("vpn:") {
            self = .vpn(String(rawValue.dropFirst(4)))
        } else if let id = ServiceID(rawValue: rawValue) {
            self = .service(id)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .service(let id): return id.rawValue
        case .vpn(let id): return "vpn:" + id
        case .wireguard: return "wireguard"
        }
    }
}
