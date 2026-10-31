import AppKit
import Network

/// Forwards sleep, wake and network availability to every window's
/// controller. Controllers are held weakly: a closed window drops out.
@MainActor
final class SystemEvents {
    private var controllers: [WeakController] = []
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.each { $0.systemWillSleep() } }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.each { $0.systemDidWake() } }
            },
        ]
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: available) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        pathMonitor.cancel()
    }

    func register(_ controller: SessionController) {
        controllers.removeAll { $0.value == nil }
        controllers.append(WeakController(value: controller))
    }

    private func networkChanged(available: Bool) {
        defer { networkAvailable = available }
        // Only a path coming back matters: a lost one is detected by the
        // session itself (SSH keepalive and the server silence limit).
        guard available, !networkAvailable else { return }
        each { $0.networkBecameAvailable() }
    }

    private func each(_ action: (SessionController) -> Void) {
        controllers.removeAll { $0.value == nil }
        controllers.compactMap(\.value).forEach(action)
    }

    private struct WeakController {
        weak var value: SessionController?
    }
}
