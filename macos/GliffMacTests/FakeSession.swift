import GliffCore
@testable import GliffMac

/// A session the test drives by hand: it records calls and emits events.
@MainActor
final class FakeSession: RemoteSession {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var events: (@MainActor @Sendable (SessionEvent) -> Void)?
    var startError: (any Error)?
    /// Ends with `.cancelled` as soon as it is cancelled, like a quick teardown.
    var endsOnCancel = false

    func start(events: @escaping @MainActor @Sendable (SessionEvent) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        self.events = events
    }

    func cancel() {
        cancelCount += 1
        if endsOnCancel { emit(.ended(.cancelled)) }
    }

    /// Delivers `event` as the bridge relay would; nothing after `.ended`.
    func emit(_ event: SessionEvent) {
        guard let events else { return }
        if case .ended = event { self.events = nil }
        events(event)
    }

    /// The handshake and first configuration of a working server.
    func becomeStreaming(width: UInt32 = 1920, height: UInt32 = 1080) {
        emit(.connected(.sample))
        emit(.videoConfig(.sample(width: width, height: height)))
    }
}

/// Hands out fake sessions in order and remembers the requests.
@MainActor
final class FakeSessionFactory: SessionFactory {
    private(set) var sessions: [FakeSession] = []
    private(set) var requests: [ConnectionRequest] = []
    var makeError: (any Error)?
    var configure: (FakeSession) -> Void = { _ in }

    func makeSession(for request: ConnectionRequest) throws -> any RemoteSession {
        requests.append(request)
        if let makeError { throw makeError }
        let session = FakeSession()
        configure(session)
        sessions.append(session)
        return session
    }

    var last: FakeSession { sessions.last! }
}

extension ServerHello {
    static let sample = ServerHello(
        headless: true, output: "HEADLESS-1",
        outputs: [OutputInfo(name: "HEADLESS-1", width: 1920, height: 1080, scaleMilli: 1000)],
        features: [])
}

extension VideoConfig {
    static func sample(width: UInt32 = 1920, height: UInt32 = 1080, generation: UInt32 = 1) -> VideoConfig {
        VideoConfig(
            generation: generation, revision: 1, rebuild: true, chroma: .single420, pipeline: .cpu,
            width: width, height: height, viewWidth: width, viewHeight: height, scaleMilli: 1000, fpsCap: 60)
    }
}
