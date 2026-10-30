import GliffCore

/// One remote session as the view model sees it. `LiveSession` wraps the
/// bridge's `GliffSession`; tests substitute a fake.
@MainActor
protocol RemoteSession: AnyObject {
    /// Starts once. `events` runs on the main actor in wire order and ends with
    /// exactly one `.ended`, after which the session holds no callbacks.
    func start(events: @escaping @MainActor @Sendable (SessionEvent) -> Void) throws
    /// Idempotent and non-blocking; `.ended` follows once teardown completes.
    func cancel()
}

/// Builds sessions for the view model.
@MainActor
protocol SessionFactory {
    func makeSession(for request: ConnectionRequest) throws -> any RemoteSession
}

/// The real session: system OpenSSH and the bridge's protocol driver.
struct LiveSessionFactory: SessionFactory {
    func makeSession(for request: ConnectionRequest) throws -> any RemoteSession {
        // Live SSH is H.264/Single420 until full chroma lands (task 08).
        try LiveSession(target: request.target(), options: SessionOptions(chroma: [.single420]))
    }
}

/// Adapts `GliffSession` and `SessionRelay` to `RemoteSession`.
///
/// Until the VideoToolbox decoder exists (task 07), frames go to a placeholder
/// sink that consumes them without decoding: it reports each one so the server
/// keeps pacing, and the surface states that video display is not available.
final class LiveSession: RemoteSession {
    private let session: GliffSession

    init(target: ConnectionTarget, options: SessionOptions) throws {
        session = try GliffSession(target: target, options: options)
    }

    func start(events: @escaping @MainActor @Sendable (SessionEvent) -> Void) throws {
        let relay = SessionRelay(
            video: { [weak session] item in
                // The placeholder consumes the frame; no pixels are produced.
                if case .frame(let frame) = item {
                    try? session?.reportDecode(frameId: frame.frameId, outcome: .decoded)
                }
            },
            events: events)
        try session.start(delegate: relay)
    }

    func cancel() {
        session.cancel()
    }
}
