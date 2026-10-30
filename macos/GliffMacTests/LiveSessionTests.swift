import Combine
import Foundation
import GliffCore
import Testing
@testable import GliffMac

/// The same view model driven by the real bridge session (a recorded server
/// stream instead of SSH), without any upstream protocol type in the app.
@MainActor
@Suite struct LiveSessionTests {
    struct ReplayFactory: SessionFactory {
        let stream: Data
        func makeSession(for request: ConnectionRequest) throws -> any RemoteSession {
            try LiveSession(target: .replay(stream: stream), options: SessionOptions(chroma: [.single420]))
        }
    }

    let defaults = TestDefaults()

    @Test func aRecordedServerStreamsThenCloses() async throws {
        let registry = SessionRegistry()
        let controller = SessionController(
            factory: ReplayFactory(stream: try fixture("live-cpu-single420")), registry: registry,
            recents: RecentConnections(defaults: defaults.store), request: ConnectionRequest(host: "replay"))
        var phases: [String] = []
        let observation = controller.$phase.sink { phases.append(Self.name($0)) }
        defer { observation.cancel() }

        controller.connect()
        try await waitUntil { registry.activeCount == 0 }
        #expect(controller.phase == .stopped(.serverClosed))
        #expect(phases.first == "idle")
        #expect(phases.contains("streaming"))
        #expect(phases.last == "stopped")
    }

    /// Real bridge, real VideoToolbox: every frame the bridge delivered is
    /// acknowledged from a native decode completion, and pictures appear.
    @Test(arguments: ["synthetic-single420", "live-cpu-single420"])
    func recordedFramesAreDecodedAndAcknowledgedNatively(_ name: String) async throws {
        let session = try LiveSession(
            target: .replay(stream: try fixture(name)), options: SessionOptions(chroma: [.single420]))
        let display = try #require(session.videoDisplay)
        let ended = EndFlag()
        display.setObserver { ended.wake() }
        try session.start { event in
            if case .ended(let end) = event { ended.set(end) }
        }
        try await waitUntil { ended.end != nil }
        #expect(ended.end == .closed)
        let stats = session.stats
        let video = display.diagnostics
        #expect(stats.framesDelivered > 0)
        #expect(video.decoded == stats.framesDelivered)
        #expect(video.failed == 0 && stats.framesFailed == 0 && stats.keyframeRequests == 0)
        // Delivered frames are acked on native completion, dropped ones at once.
        #expect(stats.acksSent == stats.framesDelivered + stats.framesDropped)
        #expect(ended.wakes > 0, "pictures reached the display")
        // The decoder is invalidated on its queue right after the end.
        try await waitUntil { display.latest == nil }
    }

    @Test func cancellingARealSessionEndsItAndReleasesIt() async throws {
        let registry = SessionRegistry()
        let controller = SessionController(
            factory: ReplayFactory(stream: try fixture("live-cpu-single420")), registry: registry,
            recents: RecentConnections(defaults: defaults.store), request: ConnectionRequest(host: "replay"))
        for _ in 0..<20 {
            controller.connect()
            controller.disconnect()
            #expect(controller.phase == .stopped(.disconnected))
        }
        #expect(await registry.cancelAllAndWait(timeout: .seconds(10)))
        #expect(registry.activeCount == 0)
    }

    @Test func unsupportedStreamsFailWithAnIncompatibleServer() async throws {
        // The dual-chroma recording requires Dual420, which the app does not advertise yet.
        let registry = SessionRegistry()
        let controller = SessionController(
            factory: ReplayFactory(stream: try fixture("synthetic-dual420")), registry: registry,
            recents: RecentConnections(defaults: defaults.store), request: ConnectionRequest(host: "replay"))
        controller.connect()
        try await waitUntil { registry.activeCount == 0 }
        guard case .failed(let failure) = controller.phase else {
            Issue.record("expected failure, got \(controller.phase)")
            return
        }
        #expect(failure.isFatal)
    }

    private static func name(_ phase: SessionController.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .streaming: "streaming"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}

private func fixture(_ name: String) throws -> Data {
    // GliffMacTests/LiveSessionTests.swift → repository root.
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    return try Data(contentsOf: root.appending(path: "tests/fixtures/streams/\(name).gliffstream"))
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

/// Records a session's end and display wake-ups, from any thread.
private final class EndFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _end: SessionEnd?
    private var _wakes = 0
    var end: SessionEnd? { lock.withLock { _end } }
    var wakes: Int { lock.withLock { _wakes } }
    func set(_ end: SessionEnd) { lock.withLock { _end = end } }
    func wake() { lock.withLock { _wakes += 1 } }
}
