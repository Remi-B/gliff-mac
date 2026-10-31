import CryptoKit
import Foundation
import GliffCore
import Testing

/// Exercises the generated bindings through the real static library: a
/// constructor, typed errors, asynchronous callbacks, buffer transfer,
/// decode feedback and repeated cancel/drop cycles.
@Suite struct BridgeTests {
    @Test func buildInfoComesFromTheLinkedLibrary() {
        let info = buildInfo()
        #expect(info.protocolVersion == 1)
        #expect(info.upstreamRevision.count == 40)
        #expect(!info.appVersion.isEmpty)
    }

    @Test func invalidTargetsAndOptionsThrowTypedErrors() throws {
        let options = SessionOptions(chroma: [.single420])
        for host in ["", "-oProxyCommand=touch /tmp/x", "host name"] {
            #expect(throws: GliffError.self) {
                _ = try GliffSession(target: .ssh(host: host, user: nil, port: nil, serverPath: nil, identityFile: nil, headless: true, output: nil, videoMode: .auto),
                                     options: options)
            }
        }
        do {
            _ = try GliffSession(target: .ssh(host: "host", user: nil, port: 0, serverPath: nil, identityFile: nil, headless: true, output: nil, videoMode: .auto),
                                 options: options)
            Issue.record("port 0 was accepted")
        } catch let GliffError.InvalidOptions(message) {
            #expect(message.contains("port"))
        }
        #expect(throws: GliffError.self) {
            _ = try GliffSession(target: .replay(stream: Data([1])), options: SessionOptions(chroma: []))
        }
        #expect(throws: GliffError.self) {
            _ = try GliffSession(target: .replay(stream: Data()), options: options)
        }
    }

    @Test func sshCancelledBeforeStartupEndsWithoutConnecting() async throws {
        let session = try GliffSession(target: .ssh(host: "example", user: nil, port: nil,
            serverPath: nil, identityFile: nil, headless: true, output: nil, videoMode: .auto), options: SessionOptions(chroma: [.single420]))
        session.cancel()
        let recorder = Recorder()
        try session.start(delegate: recorder)
        #expect(await recorder.ended() == .cancelled)
        #expect(session.state() == .closed)
    }

    @Test(arguments: Fixture.all)
    func replayDeliversEveryFrameInOrderAndAcksIt(fixture: Fixture) async throws {
        let options = SessionOptions(chroma: [.dual420, .single420])
        let session = try GliffSession(target: .replay(stream: fixture.stream), options: options)
        let recorder = Recorder()
        // Decode asynchronously, as VideoToolbox does, on another queue.
        let decoder = DispatchQueue(label: "test.decoder")
        recorder.onFrame = { [weak session] frame in
            decoder.asyncAfter(deadline: .now() + .microseconds(200)) {
                try? session?.reportDecode(frameId: frame.frameId, outcome: .decoded)
            }
        }
        try session.start(delegate: recorder)
        #expect(throws: GliffError.AlreadyStarted) { try session.start(delegate: Recorder()) }
        let end = await recorder.ended()
        #expect(end == .closed)

        // Frames of a replaced decoder generation that were still queued are
        // discarded (and acked) instead of delivered; the rest arrive in order.
        let frames = recorder.frames
        let expected = Dictionary(uniqueKeysWithValues: fixture.frames.map { ($0.frameId, $0) })
        #expect(frames.map(\.frameId) == frames.map(\.frameId).sorted())
        for frame in frames {
            let reference = try #require(expected[frame.frameId])
            #expect(frame.generation == reference.generation)
            #expect(frame.revision == reference.revision)
            #expect(frame.keyframe == reference.keyframe)
            #expect(sha256(frame.main) == reference.mainSHA256)
            #expect(frame.aux.map(sha256) == reference.auxSHA256)
        }
        #expect(frames.count >= fixture.frames.count - 4)
        #expect(recorder.configs.map(\.revision) == fixture.configRevisions)
        #expect(recorder.hello != nil)
        #expect(recorder.notOnDeliveryThread == 0)

        let stats = session.stats()
        #expect(stats.framesDelivered == UInt64(frames.count))
        #expect(stats.framesDelivered + stats.framesDropped == UInt64(fixture.frames.count))
        #expect(stats.acksSent == UInt64(fixture.frames.count))
        #expect(stats.pongsSent >= 1)
        #expect(stats.peakInFlightFrames <= 4)
        #expect(throws: GliffError.NotRunning) {
            try session.sendInput(event: .key(keycode: 30, pressed: true))
        }
    }

    @Test func aSlowConsumerStallsTheReaderInsteadOfBuffering() async throws {
        let fixture = try #require(Fixture.all.first { $0.name == "live-cpu-single420" })
        let options = SessionOptions(chroma: [.single420], maxInFlightFrames: 2)
        let session = try GliffSession(target: .replay(stream: fixture.stream), options: options)
        let recorder = Recorder()
        let decoder = DispatchQueue(label: "test.slow-decoder")
        recorder.onFrame = { [weak session] frame in
            Thread.sleep(forTimeInterval: 0.002)  // A slow callback.
            decoder.asyncAfter(deadline: .now() + .milliseconds(3)) {
                try? session?.reportDecode(frameId: frame.frameId, outcome: .decoded)
            }
        }
        try session.start(delegate: recorder)
        #expect(await recorder.ended() == .closed)
        let stats = session.stats()
        #expect(stats.peakInFlightFrames <= 2)
        #expect(stats.acksSent == UInt64(fixture.frames.count))
    }

    @Test func aDecodeFailureRequestsOneKeyframe() async throws {
        let fixture = try #require(Fixture.all.first { $0.name == "synthetic-single420" })
        let session = try GliffSession(
            target: .replay(stream: fixture.stream), options: SessionOptions(chroma: [.single420]))
        let recorder = Recorder()
        recorder.onFrame = { [weak session] frame in
            let outcome: DecodeOutcome = frame.frameId == 1 ? .failed : .decoded
            try? session?.reportDecode(frameId: frame.frameId, outcome: outcome)
        }
        try session.start(delegate: recorder)
        #expect(await recorder.ended() == .closed)
        let stats = session.stats()
        #expect(stats.framesFailed == 1)
        #expect(stats.keyframeRequests == 1)
        // Predicted frames after the failure are dropped until the next IDR.
        #expect(stats.framesDropped > 0)
        #expect(stats.acksSent == UInt64(fixture.frames.count))
        #expect(throws: GliffError.NotRunning) {
            try session.reportDecode(frameId: 1, outcome: .decoded)
        }
    }

    @Test func repeatedCancelAndDropCyclesReleaseTheDelegate() async throws {
        let fixture = try #require(Fixture.all.first { $0.name == "live-gpu-dual420" })
        let options = SessionOptions(chroma: [.dual420])
        for cycle in 0..<100 {
            var recorder: Recorder? = Recorder()
            weak var released = recorder
            var session: GliffSession? = try GliffSession(
                target: .replay(stream: fixture.stream), options: options)
            // Never report decodes: the session stalls on its budget until cancelled.
            try session!.start(delegate: recorder!)
            if cycle.isMultiple(of: 2) {
                session!.cancel()
                session!.cancel()  // Idempotent.
            }
            session = nil  // Dropping the last reference cancels.
            let end = await recorder!.ended()
            #expect(end == .cancelled || end == .closed)
            let callbacks = recorder!.callbackCount
            try await Task.sleep(for: .milliseconds(2))
            #expect(recorder!.callbackCount == callbacks, "a callback followed on_ended")
            recorder = nil
            // Rust released the Swift delegate after on_ended.
            try await waitUntil { released == nil }
        }
    }

    @Test @MainActor func theRelaySplitsVideoFromMainActorEvents() async throws {
        let fixture = try #require(Fixture.all.first { $0.name == "synthetic-dual420" })
        let session = try GliffSession(
            target: .replay(stream: fixture.stream), options: SessionOptions(chroma: [.dual420]))
        let videoOffMain = OSAllocatedCounter()
        let ended = AsyncStream<SessionEnd>.makeStream()
        var events: [String] = []
        let relay = SessionRelay(
            video: { [weak session] item in
                if !Thread.isMainThread { videoOffMain.increment() }
                if case .frame(let frame) = item {
                    try? session?.reportDecode(frameId: frame.frameId, outcome: .decoded)
                }
            },
            events: { event in
                MainActor.assertIsolated()
                switch event {
                case .connected: events.append("connected")
                case .videoConfig: events.append("config")
                case .ended(let end):
                    events.append("ended")
                    ended.continuation.yield(end)
                default: break
                }
            })
        try session.start(delegate: relay)
        var iterator = ended.stream.makeAsyncIterator()
        #expect(await iterator.next() == .closed)
        #expect(events.first == "connected")
        #expect(events.last == "ended")
        #expect(events.filter { $0 == "config" }.count == fixture.configRevisions.count)
        // Configs and frames all reached the video handler off the main thread.
        let delivered = Int(session.stats().framesDelivered)
        #expect(videoOffMain.value == fixture.configRevisions.count + delivered)
    }

    @Test @MainActor func cursorCoalescingKeepsPositionsAroundOtherEvents() async {
        var seen: [String] = []
        let relay = SessionRelay(video: { _ in }, events: { event in
            switch event {
            case .cursorPosition(let p): seen.append("pos \(Int(p.x))")
            case .cursorShape(let s): seen.append("shape \(s.id)")
            case .serverError: seen.append("error")
            default: break
            }
        })
        let position = { (x: Double) in CursorPosition(x: x, y: 0, shapeId: 1, visible: true) }
        // The main actor is busy (this test runs on it) while the delivery
        // thread calls the relay, so every post waits in the main queue.
        DispatchQueue.global().sync {
            relay.onCursorPosition(position: position(1))
            relay.onCursorPosition(position: position(2))
            relay.onCursorShape(shape: CursorShape(id: 7, width: 1, height: 1, hotX: 0, hotY: 0, argb: nil))
            relay.onCursorPosition(position: position(3))
            relay.onCursorPosition(position: position(4))
            relay.onServerError(code: 256, message: "setup")
        }
        for _ in 0..<200 where seen.count < 4 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(seen == ["pos 2", "shape 7", "pos 4", "error"])
    }
}

// MARK: - Helpers

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func currentThreadName() -> String {
    var name = [CChar](repeating: 0, count: 64)
    pthread_getname_np(pthread_self(), &name, name.count)
    return String(cString: name)
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
}

final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A delegate recording every callback, from the delivery thread.
final class Recorder: SessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [EncodedFrame] = []
    private var _configs: [VideoConfig] = []
    private var _hello: ServerHello?
    private var _end: SessionEnd?
    private var _callbacks = 0
    private var _offThread = 0
    private var waiters: [CheckedContinuation<SessionEnd, Never>] = []
    var onFrame: @Sendable (EncodedFrame) -> Void = { _ in }

    var frames: [EncodedFrame] { lock.withLock { _frames } }
    var configs: [VideoConfig] { lock.withLock { _configs } }
    var hello: ServerHello? { lock.withLock { _hello } }
    var callbackCount: Int { lock.withLock { _callbacks } }
    var notOnDeliveryThread: Int { lock.withLock { _offThread } }

    private func record(_ body: () -> Void) {
        lock.withLock {
            _callbacks += 1
            if currentThreadName() != "gliff-delivery" { _offThread += 1 }
            body()
        }
    }

    func onConnected(hello: ServerHello) { record { _hello = hello } }
    func onVideoConfig(config: VideoConfig) { record { _configs.append(config) } }
    func onFrame(frame: EncodedFrame) {
        record { _frames.append(frame) }
        onFrame(frame)
    }
    func onCursorShape(shape: CursorShape) { record {} }
    func onCursorPosition(position: CursorPosition) { record {} }
    func onServerError(code: UInt16, message: String) { record {} }
    func onEnded(end: SessionEnd) {
        let waiting = lock.withLock {
            _callbacks += 1
            _end = end
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume(returning: end) }
    }

    func ended() async -> SessionEnd {
        await withCheckedContinuation { continuation in
            let end: SessionEnd? = lock.withLock {
                if let end = _end { return end }
                waiters.append(continuation)
                return nil
            }
            if let end { continuation.resume(returning: end) }
        }
    }
}

struct Fixture: Sendable, CustomTestStringConvertible {
    struct Frame: Sendable {
        let frameId: UInt64
        let generation: UInt32
        let revision: UInt32
        let keyframe: Bool
        let mainSHA256: String
        let auxSHA256: String?
    }

    let name: String
    let stream: Data
    let frames: [Frame]
    let configRevisions: [UInt32]
    var testDescription: String { name }

    static let all: [Fixture] = [
        "synthetic-single420", "synthetic-dual420", "live-cpu-single420", "live-cpu-dual420",
        "live-gpu-dual420",
    ].map(load)

    private static func load(_ name: String) -> Fixture {
        // Tests/GliffCoreTests/BridgeTests.swift → repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let dir = root.appending(path: "tests/fixtures/streams")
        let manifest = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appending(path: "\(name).json"))) as! [String: Any]
        let stream = try! Data(contentsOf: dir.appending(path: manifest["file"] as! String))
        let frames = (manifest["frames"] as! [[String: Any]]).map {
            Frame(
                frameId: ($0["frame_id"] as! NSNumber).uint64Value,
                generation: ($0["generation"] as! NSNumber).uint32Value,
                revision: ($0["revision"] as! NSNumber).uint32Value,
                keyframe: $0["keyframe"] as! Bool,
                mainSHA256: $0["main_sha256"] as! String,
                auxSHA256: $0["aux_sha256"] as? String)
        }
        let configs = (manifest["configs"] as! [[String: Any]]).map {
            ($0["revision"] as! NSNumber).uint32Value
        }
        return Fixture(name: name, stream: stream, frames: frames, configRevisions: configs)
    }
}
