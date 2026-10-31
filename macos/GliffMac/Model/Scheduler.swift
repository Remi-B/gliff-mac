import Foundation

/// A cancellable action scheduled on the main actor.
@MainActor
protocol ScheduledAction: AnyObject {
    func cancel()
}

/// Delays for reconnect backoff and resize settling; tests substitute a
/// manual clock so timing is deterministic.
@MainActor
protocol Scheduler {
    var now: ContinuousClock.Instant { get }
    /// Runs `action` on the main actor after `delay`, unless cancelled first.
    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction
}

/// The real clock: a main-actor task per action.
struct TaskScheduler: Scheduler {
    var now: ContinuousClock.Instant { .now }

    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        TaskAction(Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        })
    }

    private final class TaskAction: ScheduledAction {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}

/// Reconnect backoff and resize settling.
struct SessionTiming: Equatable, Sendable {
    /// The wait before each automatic reconnect attempt; its count is the
    /// attempt limit.
    var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
    /// A session that streamed this long before failing starts a fresh
    /// series of attempts; a shorter one continues the current series, so a
    /// server failing right after each start cannot loop forever.
    var stableAfter: Duration = .seconds(30)
    /// How long a surface size must hold before the server is asked to match.
    var resizeSettle: Duration = .milliseconds(200)

    var attemptLimit: Int { reconnectDelays.count }
}
