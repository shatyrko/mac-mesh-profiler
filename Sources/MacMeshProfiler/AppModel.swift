import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let yggdrasil = YggdrasilModel()
    let mycelium = MyceliumModel()
    var selection: ServiceID? = ServiceID(rawValue: UserDefaults.standard.string(forKey: "lastSelection") ?? "")
        ?? .yggdrasil {
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
    }

    func checkForUpdates() async {
        async let a: Void = yggdrasil.checkForUpdate()
        async let b: Void = mycelium.checkForUpdate()
        _ = await (a, b)
    }
}
