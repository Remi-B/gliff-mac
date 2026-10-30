import Foundation
import GliffCore
import Testing
@testable import GliffMac

/// The view model's state machine against a fake session: connection steps,
/// failure, cancellation, stale callbacks and window closure.
@MainActor
@Suite struct SessionControllerTests {
    let factory = FakeSessionFactory()
    let registry = SessionRegistry()
    let defaults = TestDefaults()
    let controller: SessionController

    init() {
        controller = SessionController(
            factory: factory, registry: registry, recents: RecentConnections(defaults: defaults.store),
            request: ConnectionRequest(host: "desk", user: "remi"))
    }

    @Test func connectsThroughEachStepToStreaming() throws {
        controller.connect()
        #expect(controller.phase == .connecting(.starting))
        #expect(factory.requests == [ConnectionRequest(host: "desk", user: "remi")])
        #expect(factory.last.startCount == 1)
        #expect(!controller.canConnect && controller.canDisconnect && !controller.canReconnect)

        factory.last.emit(.connected(.sample))
        #expect(controller.phase == .connecting(.awaitingVideo))

        factory.last.emit(.videoConfig(.sample(width: 2560, height: 1600)))
        guard case .streaming(let info) = controller.phase else {
            Issue.record("expected streaming, got \(controller.phase)")
            return
        }
        #expect(info.width == 2560 && info.height == 1600)
        #expect(info.reducedChroma && !info.displaysVideo && info.headless)
        #expect(info.output == "HEADLESS-1")
        #expect(controller.canReconnect && controller.canDisconnect)
    }

    @Test func invalidFieldsNeverStartASession() {
        controller.request = ConnectionRequest(host: "-oProxyCommand=x", user: "a b", port: "0",
                                               identityFile: "id_ed25519", serverPath: "~/gliff-server")
        controller.connect()
        #expect(factory.requests.isEmpty)
        #expect(controller.phase == .idle)
        #expect(Set(controller.fieldErrors.keys) == Set(ConnectionRequest.Field.allCases))

        controller.request = ConnectionRequest(host: " desk ")
        controller.connect()
        #expect(controller.fieldErrors.isEmpty)
        #expect(factory.requests.map(\.host) == ["desk"])
    }

    @Test func aBridgeErrorWhileStartingIsReportedAndRetryable() {
        factory.makeError = GliffError.Transport(message: "ssh is unavailable")
        controller.connect()
        guard case .failed(let failure) = controller.phase else {
            Issue.record("expected failure, got \(controller.phase)")
            return
        }
        #expect(failure.title == "Could not connect")
        #expect(failure.recoveries == [.retry, .editConnection])
        #expect(registry.activeCount == 0)

        factory.makeError = nil
        controller.reconnect()
        #expect(controller.phase == .reconnecting(.starting))
        #expect(registry.activeCount == 1)
    }

    @Test func aStartRefusalReleasesTheSession() {
        factory.configure = { $0.startError = GliffError.AlreadyStarted }
        controller.connect()
        #expect(registry.activeCount == 0)
        #expect(controller.currentSession == nil)
        guard case .failed = controller.phase else {
            Issue.record("expected failure, got \(controller.phase)")
            return
        }
    }

    @Test func aTransportFailureOffersRetryAndEdit() {
        controller.connect()
        factory.last.emit(.connected(.sample))
        factory.last.emit(.ended(.failed(error: .Transport(message: "host key verification failed"))))
        #expect(controller.phase == .failed(
            SessionFailure(title: "Could not connect", message: "Host key verification failed.")))
        #expect(registry.activeCount == 0)
        #expect(controller.canReconnect && controller.canConnect)

        controller.editConnection()
        #expect(controller.phase == .idle)
        #expect(controller.request.host == "desk")
    }

    @Test func anIncompatibleServerCannotBeRetried() {
        controller.connect()
        factory.last.emit(.ended(.failed(error: .VersionMismatch(client: 1, server: 2, reason: "newer server"))))
        guard case .failed(let failure) = controller.phase else {
            Issue.record("expected failure, got \(controller.phase)")
            return
        }
        #expect(failure.isFatal)
        #expect(failure.recoveries == [.editConnection])
        #expect(!controller.canReconnect)
        controller.reconnect()
        #expect(factory.sessions.count == 1)
    }

    @Test func serverCloseAndServerErrorsAreShown() {
        controller.connect()
        factory.last.becomeStreaming()
        factory.last.emit(.serverError(code: 256, message: "encoder restarted"))
        #expect(controller.serverMessage == "encoder restarted (code 256)")
        #expect(controller.isStreaming)
        factory.last.emit(.ended(.closed))
        #expect(controller.phase == .stopped(.serverClosed))
        #expect(controller.canReconnect)
    }

    @Test func cancellingWhileConnectingStopsAndIgnoresTheLateEnd() {
        controller.connect()
        let session = factory.last
        controller.disconnect()
        #expect(session.cancelCount == 1)
        #expect(controller.phase == .stopped(.disconnected))
        #expect(controller.currentSession == nil)
        // The bridge still owns the session until its teardown reports the end.
        #expect(registry.activeCount == 1)

        // Late callbacks of the cancelled session change nothing.
        session.emit(.connected(.sample))
        session.emit(.videoConfig(.sample()))
        #expect(controller.phase == .stopped(.disconnected))
        session.emit(.ended(.failed(error: .Transport(message: "late"))))
        #expect(controller.phase == .stopped(.disconnected))
        #expect(registry.activeCount == 0)
    }

    @Test func reconnectReplacesTheSessionAndIgnoresTheOldOne() {
        controller.connect()
        let old = factory.last
        old.becomeStreaming()
        controller.captureInput()
        #expect(controller.isCapturingInput)

        controller.reconnect()
        let new = factory.last
        #expect(new !== old)
        #expect(old.cancelCount == 1)
        #expect(!controller.isCapturingInput)
        #expect(controller.phase == .reconnecting(.starting))
        #expect(factory.requests.count == 2 && factory.requests[0] == factory.requests[1])

        // The old session's stale events, including its end, are ignored.
        old.emit(.videoConfig(.sample(width: 800, height: 600)))
        old.emit(.serverError(code: 1, message: "stale"))
        old.emit(.ended(.closed))
        #expect(controller.phase == .reconnecting(.starting))
        #expect(controller.serverMessage == nil)

        new.becomeStreaming(width: 1280, height: 800)
        guard case .streaming(let info) = controller.phase else {
            Issue.record("expected streaming, got \(controller.phase)")
            return
        }
        #expect(info.width == 1280)
    }

    @Test func closingTheWindowWhileConnectingCancelsAndFreezesState() {
        controller.connect()
        let session = factory.last
        controller.close()
        #expect(session.cancelCount == 1)
        #expect(!controller.canConnect && !controller.canReconnect)
        let phase = controller.phase

        controller.connect()
        controller.reconnect()
        session.emit(.connected(.sample))
        session.emit(.ended(.cancelled))
        #expect(factory.sessions.count == 1)
        #expect(controller.phase == phase)
        #expect(registry.activeCount == 0)

        controller.close()  // Idempotent.
        #expect(session.cancelCount == 1)
    }

    @Test func aClosedWindowsSessionOutlivesTheControllerUntilItEnds() async throws {
        var controller: SessionController? = SessionController(
            factory: factory, registry: registry, recents: RecentConnections(defaults: defaults.store),
            request: ConnectionRequest(host: "desk"))
        weak var released: SessionController?
        released = controller
        controller!.connect()
        controller!.close()
        controller = nil
        #expect(released == nil, "the session must not retain its window's controller")
        #expect(registry.activeCount == 1)
        factory.last.emit(.ended(.cancelled))
        #expect(registry.activeCount == 0)
    }

    @Test func inputCaptureNeedsAStreamAndEndsWithIt() {
        controller.captureInput()
        #expect(!controller.isCapturingInput)
        controller.connect()
        factory.last.becomeStreaming()
        controller.captureInput()
        #expect(controller.isCapturingInput)
        controller.releaseInput()
        #expect(!controller.isCapturingInput)
        controller.captureInput()
        factory.last.emit(.ended(.closed))
        #expect(!controller.isCapturingInput)
    }

    @Test func onlyConnectedDestinationsAreRemembered() {
        let recents = RecentConnections(defaults: defaults.store)
        let controller = SessionController(
            factory: factory, registry: registry, recents: recents, request: ConnectionRequest(host: "typo"))
        controller.connect()
        factory.last.emit(.ended(.failed(error: .Transport(message: "no route"))))
        #expect(recents.entries.isEmpty)

        controller.request = ConnectionRequest(host: "desk", port: "2222")
        controller.connect()
        factory.last.emit(.connected(.sample))
        #expect(recents.entries == [ConnectionRequest(host: "desk", port: "2222")])
    }
}

/// An isolated defaults domain, removed when the test ends.
final class TestDefaults: Sendable {
    let name = "gliff-tests-\(UUID().uuidString)"
    var store: UserDefaults { UserDefaults(suiteName: name)! }
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}
