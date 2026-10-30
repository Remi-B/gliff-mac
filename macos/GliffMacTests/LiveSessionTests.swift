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
        var chroma = LiveSession.chroma
        func makeSession(for request: ConnectionRequest) throws -> any RemoteSession {
            try LiveSession(target: .replay(stream: stream), options: SessionOptions(chroma: chroma))
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
    /// The app advertises exactly what the native pipeline implements.
    @Test func liveSessionsAdvertiseDual420ThenSingle420() {
        #expect(LiveSession.chroma == [.dual420, .single420])
    }

    @Test(arguments: [
        "synthetic-single420", "live-cpu-single420", "synthetic-dual420", "live-cpu-dual420", "live-gpu-dual420",
    ])
    func recordedFramesAreDecodedAndAcknowledgedNatively(_ name: String) async throws {
        let session = try LiveSession(
            target: .replay(stream: try fixture(name)), options: SessionOptions(chroma: LiveSession.chroma))
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
        // Dual420: every acknowledged frame is a completed main/aux pair.
        #expect(video.pairsDecoded == (name.hasSuffix("dual420") ? video.decoded : 0))
        #expect(video.halfFailures == 0 && video.expired == 0)
        #expect(video.fullChroma == name.hasSuffix("dual420"))
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
        // A Dual420 recording offered to a client that only advertises Single420.
        let registry = SessionRegistry()
        let controller = SessionController(
            factory: ReplayFactory(stream: try fixture("synthetic-dual420"), chroma: [.single420]), registry: registry,
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

/// Opt-in acceptance against real headless SSH servers. Each JSON entry is a
/// ConnectionRequest; all fields must be present and headless must be true.
@MainActor
@Suite(.serialized) struct NativeSSHVideoTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLIFF_LIVE_TARGETS"] != nil))
    func headlessServersDecodeAndResizeNatively() async throws {
        let json = try #require(ProcessInfo.processInfo.environment["GLIFF_LIVE_TARGETS"])
        let targets = try JSONDecoder().decode([ConnectionRequest].self, from: Data(json.utf8))
        #expect(!targets.isEmpty)
        for target in targets {
            guard target.headless, target.validationErrors().isEmpty else {
                Issue.record("Live target must be valid and explicitly headless")
                continue
            }
            let session = try GliffSession(target: target.target(), options: SessionOptions(chroma: LiveSession.chroma))
            let display = VideoDisplay()
            let decoder = H264Decoder(display: display) { [weak session] id, outcome in
                try? session?.reportDecode(frameId: id, outcome: outcome)
            }
            let ended = EndFlag()
            let relay = SessionRelay(video: { decoder.handle($0) }, events: { event in
                if case .ended(let end) = event { ended.set(end) }
            })
            defer { session.cancel(); decoder.invalidate() }
            var started = false
            var failure: (any Error)?
            do {
                try session.start(delegate: relay)
                started = true
                try await waitUntil(timeout: .seconds(30)) { display.latest?.isFullChroma == true || ended.end != nil }
                let first = try #require(display.latest, "headless server must produce a Dual420 pair")
                #expect(first.isFullChroma && ended.end == nil)
                let width: UInt32 = first.geometry.width == 1280 && first.geometry.height == 800 ? 1024 : 1280
                let height: UInt32 = width == 1280 ? 800 : 768
                try session.sendInput(event: .resize(width: width, height: height, scale: 1))
                try await waitUntil(timeout: .seconds(30)) {
                    guard let frame = display.latest else { return ended.end != nil }
                    return (frame.generation > first.generation && frame.geometry.width == Int(width)
                            && frame.geometry.height == Int(height) && frame.isFullChroma) || ended.end != nil
                }
                let resized = try #require(display.latest)
                #expect(resized.generation > first.generation && resized.geometry.width == Int(width)
                        && resized.geometry.height == Int(height) && resized.isFullChroma)
                let renderer = try #require(VideoRenderer())
                for frame in [first, resized] {
                    let aux = try #require(frame.aux)
                    var gpu = try #require(renderer.convertedPixels(frame))
                    for i in stride(from: 0, to: gpu.count, by: 4) { gpu.swapAt(i, i + 2) }
                    #expect(gpu == ChromaReference.dualBGRA(main: frame.pixelBuffer, aux: aux,
                                                            width: frame.geometry.width, height: frame.geometry.height))
                }
                try await waitUntil(timeout: .seconds(10)) {
                    let stats = session.stats()
                    return stats.acksSent == stats.framesDelivered + stats.framesDropped
                        && stats.framesDelivered > 0
                }
                let stats = session.stats()
                let video = display.diagnostics
                #expect(stats.framesDelivered > 0 && stats.acksSent == stats.framesDelivered + stats.framesDropped)
                #expect(stats.framesFailed == 0 && video.failed == 0 && video.expired == 0 && video.halfFailures == 0)
                #expect(video.pairsDecoded > 0)
                print("native-live \(target.displayName): delivered \(stats.framesDelivered), dropped \(stats.framesDropped), acks \(stats.acksSent), pairs \(video.pairsDecoded), resize \(width)x\(height)")
            } catch {
                failure = error
            }
            session.cancel()
            if started {
                let deadline = ContinuousClock.now + .seconds(10)
                while ended.end == nil && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                #expect(ended.end != nil, "SSH session teardown timed out")
                if failure == nil { #expect(ended.end == .cancelled) }
            }
            decoder.invalidateAndWait()
            if let failure { throw failure }
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
