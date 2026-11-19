import Foundation

enum ServiceID: String, CaseIterable, Identifiable, Hashable {
    case yggdrasil, mycelium
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yggdrasil: return "Yggdrasil"
        case .mycelium: return "Mycelium"
        }
    }
    var symbol: String {
        switch self {
        case .yggdrasil: return "tree"
        case .mycelium: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Live, mostly read-only state shared by both service models.
struct ServiceRuntime {
    var installedVersion: String?
    var latestRelease: Release?
    var daemon = DaemonStatus()
    var address: InterfaceAddress?
    var livePeers: [LivePeer] = []
    /// Listening ports and interfaces in use (empty while stopped).
    var network = NetworkSnapshot()
    /// Why live peer info is unavailable, if it is.
    var liveNote: String?
    /// Where live peer info comes from when it isn't the daemon's own API.
    var liveSource: String?
    /// Human description of the operation in progress (nil when idle).
    var busy: String?
    var lastError: String?
    var lastRefresh: Date?

    var isInstalled: Bool { installedVersion != nil }

    var updateAvailable: Bool {
        guard let installed = installedVersion, let latest = latestRelease?.version else { return false }
        return isNewer(latest, than: installed)
    }

    var stateText: String {
        if !isInstalled { return "Not installed" }
        if daemon.running { return daemon.pid.map { "Running (pid \($0))" } ?? "Running" }
        if daemon.loaded { return "Loaded, not running" }
        if !daemon.plistInstalled { return "No launch daemon" }
        return "Stopped"
    }

    enum Health { case running, stopped, degraded, missing }

    var health: Health {
        if !isInstalled { return .missing }
        if daemon.running { return .running }
        if daemon.loaded { return .degraded }
        return .stopped
    }
}

/// What the menu bar and sidebar need from either service.
@MainActor
protocol MeshServiceModel: AnyObject {
    var id: ServiceID { get }
    var runtime: ServiceRuntime { get set }
    func start() async
    func stop() async
    func restart() async
    func refresh() async
}

extension MeshServiceModel {
    /// Wraps an operation with busy/error bookkeeping, then refreshes status.
    func perform(_ label: String, _ body: () async throws -> Void) async {
        guard runtime.busy == nil else { return }
        runtime.busy = label
        runtime.lastError = nil
        do {
            try await body()
        } catch AdminError.cancelled {
            // The password prompt was dismissed: nothing to report.
        } catch {
            runtime.lastError = error.localizedDescription
        }
        runtime.busy = nil
        await refresh()
    }
}
