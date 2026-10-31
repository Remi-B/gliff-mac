import Foundation
import GliffCore
import Testing
@testable import GliffMac

/// A clock the test advances by hand: scheduled actions run only when due.
@MainActor
final class ManualScheduler: Scheduler {
    private(set) var now = ContinuousClock.now
    private var actions: [(due: ContinuousClock.Instant, action: Action)] = []

    final class Action: ScheduledAction {
        let run: @MainActor () -> Void
        var cancelled = false
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        func cancel() { cancelled = true }
    }

    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        let scheduled = Action(action)
        actions.append((now + delay, scheduled))
        return scheduled
    }

    /// Actions waiting and not cancelled.
    var pending: Int { actions.filter { !$0.action.cancelled }.count }

    /// Moves time forward, running what falls due in order.
    func advance(by duration: Duration) {
        let end = now + duration
        while let next = actions.enumerated().filter({ !$0.element.action.cancelled && $0.element.due <= end })
            .min(by: { $0.element.due < $1.element.due })
        {
            actions.remove(at: next.offset)
            now = max(now, next.element.due)
            next.element.action.run()
        }
        now = end
        actions.removeAll { $0.action.cancelled }
    }
}

/// Automatic reconnection, sleep/wake, network return and resize requests,
/// against fake sessions and a manual clock.
@MainActor
@Suite struct ReconnectionTests {
    let factory = FakeSessionFactory()
    let registry = SessionRegistry()
    let defaults = TestDefaults()
    let clock = ManualScheduler()
    let controller: SessionController

    init() {
        controller = SessionController(
            factory: factory, registry: registry, recents: RecentConnections(defaults: defaults.store),
            request: ConnectionRequest(host: "desk"), currentLayout: { KeyboardLayout(sourceID: "com.apple.keylayout.US", name: "U.S.") },
            scheduler: clock, timing: SessionTiming())
    }

    private func streaming() {
        controller.connect()
        factory.last.becomeStreaming()
    }

    private static let lost = SessionEnd.failed(error: .Transport(message: "the server stopped responding for 15 seconds"))

    @Test func aLostLinkIsRetriedWithBackoffUntilItStreamsAgain() {
        streaming()
        let first = factory.last
        first.emit(.ended(Self.lost))
        #expect(controller.phase == .reconnecting(.waiting))
        #expect(controller.reconnection == .init(
            attempt: 1, limit: 5, reason: "The server stopped responding for 15 seconds."))
        #expect(registry.activeCount == 0)

        // Nothing starts before the first delay.
        clock.advance(by: .milliseconds(999))
        #expect(factory.sessions.count == 1)
        clock.advance(by: .milliseconds(1))
        #expect(factory.sessions.count == 2)
        #expect(controller.phase == .reconnecting(.starting))

        // An unreachable host during the series waits longer each time.
        factory.last.emit(.ended(.failed(error: .Transport(message: "SSH could not reach the host"))))
        #expect(controller.reconnection?.attempt == 2)
        clock.advance(by: .milliseconds(1999))
        #expect(factory.sessions.count == 2)
        clock.advance(by: .milliseconds(1))
        #expect(factory.sessions.count == 3)

        factory.last.becomeStreaming(width: 1280, height: 800)
        #expect(controller.isStreaming)
        #expect(controller.reconnectCount == 1)
        #expect(factory.requests.allSatisfy { $0 == factory.requests[0] })
        // The old sessions' late events change nothing.
        first.emit(.videoConfig(.sample(width: 640, height: 480)))
        guard case .streaming(let info) = controller.phase else { Issue.record("\(controller.phase)"); return }
        #expect(info.width == 1280)
    }

    @Test func theSeriesGivesUpAfterItsLimitWithTheLastError() {
        streaming()
        factory.last.emit(.ended(Self.lost))
        for attempt in 1...5 {
            #expect(controller.reconnection?.attempt == attempt)
            clock.advance(by: .seconds(16))
            #expect(factory.sessions.count == attempt + 1)
            factory.last.emit(.ended(.failed(error: .Transport(message: "SSH could not reach the host"))))
        }
        guard case .failed(let failure) = controller.phase else { Issue.record("\(controller.phase)"); return }
        #expect(failure.message.contains("could not reach the host") && failure.message.contains("tried 5 times"))
        #expect(controller.reconnection == nil && clock.pending == 0)
        #expect(controller.canReconnect)
        clock.advance(by: .seconds(60))
        #expect(factory.sessions.count == 6)
    }

    @Test func setupRefusalsAndIncompatibleServersStopTheSeries() {
        for error in [GliffError.Setup(message: "SSH key authentication failed"),
                      .VersionMismatch(client: 1, server: 2, reason: "newer server")] {
            streaming()
            factory.last.emit(.ended(Self.lost))
            clock.advance(by: .seconds(1))
            factory.last.emit(.ended(.failed(error: error)))
            guard case .failed = controller.phase else { Issue.record("\(controller.phase)"); return }
            #expect(controller.reconnection == nil && clock.pending == 0)
            controller.editConnection()
        }
    }

    @Test func aFirstAttemptIsNeverRetriedAutomatically() {
        controller.connect()
        factory.last.emit(.ended(.failed(error: .Transport(message: "SSH could not reach the host"))))
        guard case .failed = controller.phase else { Issue.record("\(controller.phase)"); return }
        #expect(clock.pending == 0)
    }

    @Test func aServerThatClosesAfterStreamingIsRetried() {
        streaming()
        factory.last.emit(.ended(.closed))
        #expect(controller.reconnection?.reason == "The server ended the session.")
        clock.advance(by: .seconds(1))
        #expect(factory.sessions.count == 2)
    }

    @Test func quickFailuresAfterReconnectingContinueTheSeries() {
        streaming()
        factory.last.emit(.ended(Self.lost))
        clock.advance(by: .seconds(1))
        factory.last.becomeStreaming()
        clock.advance(by: .seconds(5))
        factory.last.emit(.ended(.closed))
        #expect(controller.reconnection?.attempt == 2)
        clock.advance(by: .seconds(2))
        factory.last.becomeStreaming()
        // Stable for 30 seconds: the next loss starts a fresh series.
        clock.advance(by: .seconds(30))
        factory.last.emit(.ended(Self.lost))
        #expect(controller.reconnection?.attempt == 1)
    }

    @Test(arguments: [false, true])
    func disconnectOrCloseCancelsTheBackoffImmediately(close: Bool) {
        streaming()
        factory.last.emit(.ended(Self.lost))
        #expect(clock.pending == 1)
        if close { controller.close() } else { controller.disconnect() }
        #expect(clock.pending == 0 && controller.reconnection == nil)
        if !close { #expect(controller.phase == .stopped(.disconnected)) }
        clock.advance(by: .seconds(60))
        #expect(factory.sessions.count == 1)
    }

    @Test func disconnectDuringAnAttemptCancelsItAndStops() {
        streaming()
        factory.last.emit(.ended(Self.lost))
        clock.advance(by: .seconds(1))
        let attempt = factory.last
        controller.disconnect()
        #expect(attempt.cancelCount == 1)
        attempt.emit(.ended(.cancelled))
        #expect(controller.phase == .stopped(.disconnected))
        clock.advance(by: .seconds(60))
        #expect(factory.sessions.count == 2)
    }

    @Test func networkReturnAndTryNowSkipTheWait() {
        streaming()
        factory.last.emit(.ended(Self.lost))
        controller.networkBecameAvailable()
        #expect(factory.sessions.count == 2 && clock.pending == 0)
        factory.last.emit(.ended(.failed(error: .Transport(message: "SSH could not reach the host"))))
        controller.retryNow()
        #expect(factory.sessions.count == 3)
        // Not waiting: nothing happens.
        controller.networkBecameAvailable()
        #expect(factory.sessions.count == 3)
    }

    @Test func sleepEndsTheSessionAndWakeStartsANewOne() throws {
        streaming()
        let asleep = factory.last
        controller.captureInput()
        try #require(controller.input).keyDown(UInt16(0x00), isRepeat: false)
        controller.systemWillSleep()
        #expect(asleep.cancelCount == 1)
        #expect(asleep.inputs.last == .key(keycode: 30, pressed: false))
        #expect(controller.phase == .reconnecting(.waiting))
        #expect(controller.reconnection?.awaitingWake == true)
        // No timer and no network event starts a session while asleep.
        controller.networkBecameAvailable()
        clock.advance(by: .seconds(60))
        #expect(factory.sessions.count == 1)

        controller.systemDidWake()
        #expect(factory.sessions.count == 2)
        #expect(controller.phase == .reconnecting(.starting))
        // The new session starts with no key held and nothing replayed.
        factory.last.becomeStreaming()
        #expect(factory.last.inputs.isEmpty)
        // The asleep session's late end is ignored.
        asleep.emit(.ended(.cancelled))
        #expect(controller.isStreaming)
    }

    @Test func sleepWithoutASessionDoesNothing() {
        controller.systemWillSleep()
        controller.systemDidWake()
        #expect(controller.phase == .idle && factory.sessions.isEmpty)
    }

    // MARK: Resize

    @Test func resizeRequestsWaitForTheSizeToSettle() {
        streaming()
        let session = factory.last
        controller.surfaceChanged(pixelWidth: 2000, pixelHeight: 1200, scale: 2)
        clock.advance(by: .milliseconds(100))
        controller.surfaceChanged(pixelWidth: 2401, pixelHeight: 1351, scale: 2)
        clock.advance(by: .milliseconds(199))
        #expect(session.inputs.isEmpty)
        clock.advance(by: .milliseconds(1))
        // Even sizes in backing pixels, at the display's scale.
        #expect(session.inputs == [.resize(width: 2400, height: 1350, scale: 2)])

        // The same size again is not resent; a Retina move (scale only) is.
        controller.surfaceChanged(pixelWidth: 2400, pixelHeight: 1350, scale: 2)
        session.emit(.videoConfig(.sample(width: 2400, height: 1350, generation: 2)))
        clock.advance(by: .seconds(1))
        #expect(session.inputs.count == 1)
        controller.surfaceChanged(pixelWidth: 1200, pixelHeight: 675, scale: 1)
        clock.advance(by: .milliseconds(200))
        #expect(session.inputs.last == .resize(width: 1200, height: 674, scale: 1))
    }

    @Test func tooSmallOrUnstreamedSurfacesAreNotSent() {
        controller.connect()
        controller.surfaceChanged(pixelWidth: 1920, pixelHeight: 1080, scale: 2)
        clock.advance(by: .seconds(1))
        #expect(factory.last.inputs.isEmpty)
        // Streaming starts: the settled size goes out then.
        factory.last.becomeStreaming()
        clock.advance(by: .milliseconds(200))
        #expect(factory.last.inputs == [.resize(width: 1920, height: 1080, scale: 2)])
        controller.surfaceChanged(pixelWidth: 300, pixelHeight: 200, scale: 2)
        clock.advance(by: .seconds(1))
        #expect(factory.last.inputs.count == 1)
    }

    @Test func aReconnectedSessionGetsTheCurrentSize() {
        streaming()
        controller.surfaceChanged(pixelWidth: 1600, pixelHeight: 1000, scale: 2)
        clock.advance(by: .milliseconds(200))
        factory.last.emit(.ended(Self.lost))
        clock.advance(by: .seconds(1))
        let second = factory.last
        second.becomeStreaming()
        clock.advance(by: .milliseconds(200))
        #expect(second.inputs == [.resize(width: 1600, height: 1000, scale: 2)])
    }

    /// A virtual display resized from scale 1 to 2 changes the cursor's
    /// output scale with it; a mirrored output keeps HelloAck's.
    @Test func theCursorFollowsTheVirtualDisplaysNewScale() {
        streaming()
        #expect(controller.cursorOutputScale == 1)
        controller.surfaceChanged(pixelWidth: 2400, pixelHeight: 1350, scale: 2)
        clock.advance(by: .milliseconds(200))
        var config = VideoConfig.sample(width: 2400, height: 1350, generation: 2)
        config.scaleMilli = 2000
        factory.last.emit(.videoConfig(config))
        #expect(controller.cursorOutputScale == 2)
        // The encoder downscaled the stream: the requested scale stands.
        controller.surfaceChanged(pixelWidth: 1600, pixelHeight: 900, scale: 1.5)
        clock.advance(by: .milliseconds(200))
        config = VideoConfig.sample(width: 1280, height: 720, generation: 3)
        config.scaleMilli = 1200
        factory.last.emit(.videoConfig(config))
        #expect(controller.cursorOutputScale == 1.5)

        controller.disconnect()
        controller.reconnect()
        factory.last.emit(.connected(ServerHello(
            headless: false, output: "DP-1",
            outputs: [OutputInfo(name: "DP-1", width: 3840, height: 2160, scaleMilli: 2000)], features: [])))
        factory.last.emit(.videoConfig(.sample()))
        controller.surfaceChanged(pixelWidth: 1000, pixelHeight: 600, scale: 2)
        clock.advance(by: .milliseconds(200))
        config = VideoConfig.sample(width: 1000, height: 562, generation: 2)
        config.scaleMilli = 520
        factory.last.emit(.videoConfig(config))
        #expect(controller.cursorOutputScale == 2)
    }

    @Test func aFullInputQueueRetriesTheResize() {
        streaming()
        factory.last.acceptsInput = false
        controller.surfaceChanged(pixelWidth: 1600, pixelHeight: 1000, scale: 2)
        clock.advance(by: .milliseconds(200))
        #expect(factory.last.inputs.isEmpty && clock.pending == 1)
        factory.last.acceptsInput = true
        clock.advance(by: .milliseconds(200))
        #expect(factory.last.inputs == [.resize(width: 1600, height: 1000, scale: 2)])
    }
}
