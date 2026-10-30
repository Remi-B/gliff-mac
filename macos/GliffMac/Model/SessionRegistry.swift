import Foundation
import GliffCore

/// Identifies one session attempt. A window's controller compares it with its
/// current attempt to ignore callbacks from sessions it already replaced.
struct SessionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64
    var description: String { "session-\(rawValue)" }
}

/// Owns every started session until its `.ended` event, whatever happens to
/// the window that started it.
///
/// A closed window or a replaced attempt only cancels its session; the
/// registry keeps the session alive until the bridge reports the end, which
/// comes after SSH is reaped. Quitting cancels every session and waits for
/// those ends, with a deadline, so the app never leaves SSH children behind.
@MainActor
final class SessionRegistry {
    private var nextID: UInt64 = 0
    private var sessions: [SessionID: any RemoteSession] = [:]
    private var nextWaiter: UInt64 = 0
    private var drainWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

    /// Sessions that have started and not yet ended.
    var activeCount: Int { sessions.count }

    /// Starts `session` and forwards its events to `forward` with its
    /// identity. The registry keeps `session` until `.ended` has been forwarded.
    func start(
        _ session: any RemoteSession,
        forward: @escaping @MainActor (SessionID, SessionEvent) -> Void
    ) throws -> SessionID {
        nextID += 1
        let id = SessionID(rawValue: nextID)
        sessions[id] = session
        do {
            try session.start { [weak self] event in
                forward(id, event)
                if case .ended = event { self?.finish(id) }
            }
        } catch {
            sessions[id] = nil
            throw error
        }
        return id
    }

    /// Cancels one session; it stays registered until it ends.
    func cancel(_ id: SessionID) {
        sessions[id]?.cancel()
    }

    /// Cancels every session and returns `true` once all have ended, or
    /// `false` when `timeout` passes first.
    func cancelAllAndWait(timeout: Duration) async -> Bool {
        for session in sessions.values { session.cancel() }
        if sessions.isEmpty { return true }
        nextWaiter += 1
        let waiter = nextWaiter
        return await withCheckedContinuation { continuation in
            drainWaiters[waiter] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.drainWaiters.removeValue(forKey: waiter)?.resume(returning: false)
            }
        }
    }

    private func finish(_ id: SessionID) {
        sessions[id] = nil
        guard sessions.isEmpty else { return }
        let waiters = drainWaiters.values
        drainWaiters = [:]
        waiters.forEach { $0.resume(returning: true) }
    }
}
