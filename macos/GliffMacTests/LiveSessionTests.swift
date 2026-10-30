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
