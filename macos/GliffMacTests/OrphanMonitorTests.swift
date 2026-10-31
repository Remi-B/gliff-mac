import Foundation
import GliffCore
import Testing
@testable import GliffMac

/// Answers checks and removals from stubs, records requests, and can hold a
/// call until its task is cancelled.
final class FakeMonitorService: MonitorService, @unchecked Sendable {
    private let lock = NSLock()
    private var _checks: [ConnectionRequest] = []
    private var _removals: [[String]] = []
    private var _cancelled = 0
    private var _found: [OrphanedOutput] = []
    var check: (@Sendable () throws -> OrphanCheck)?
    var removal: (@Sendable ([String]) throws -> OrphanRemoval)?
    /// Calls wait until cancelled instead of answering.
    var holds = false
    /// Only removals wait until cancelled.
    var holdsRemovals = false

    var checks: [ConnectionRequest] { lock.withLock { _checks } }
    var removals: [[String]] { lock.withLock { _removals } }
    var cancelled: Int { lock.withLock { _cancelled } }
    /// What the next checks find; removed outputs disappear from it.
    var found: [OrphanedOutput] {
        get { lock.withLock { _found } }
        set { lock.withLock { _found = newValue } }
    }

    func findOrphans(on request: ConnectionRequest) async throws -> OrphanCheck {
        lock.withLock { _checks.append(request) }
        try await holdIfAsked()
        if let check { return try check() }
        return .found(outputs: found)
    }

    func remove(_ names: [String], on request: ConnectionRequest) async throws -> OrphanRemoval {
        lock.withLock { _removals.append(names) }
        try await holdIfAsked(removal: true)
        if let removal { return try removal(names) }
        lock.withLock { _found.removeAll { names.contains($0.name) } }
        return .finished(results: names.map { OutputRemoval(name: $0, outcome: .removed) })
    }

    private func holdIfAsked(removal: Bool = false) async throws {
        guard holds || (removal && holdsRemovals) else { return }
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            lock.withLock { _cancelled += 1 }
            throw error
        }
    }
}

extension OrphanedOutput {
    static func gliff(_ pid: Int, enabled: Bool = true) -> OrphanedOutput {
        OrphanedOutput(name: "gliff-\(pid)", width: 1920, height: 1080, enabled: enabled)
    }
}

/// The orphaned-monitor check after each connection, its sheet, Ignore, the
/// automatic setting and cancellation, against fake sessions and a fake host.
@MainActor
@Suite struct OrphanMonitorTests {
    let factory = FakeSessionFactory()
    let registry = SessionRegistry()
    let defaults = TestDefaults()
    let clock = ManualScheduler()
    let service = FakeMonitorService()

    private func controller(
        request: ConnectionRequest = ConnectionRequest(host: "desk"), automatic: Bool = false
    ) -> SessionController {
        SessionController(
            factory: factory, registry: registry, recents: RecentConnections(defaults: defaults.store),
            request: request,
            currentLayout: { KeyboardLayout(sourceID: "com.apple.keylayout.US", name: "U.S.") },
            scheduler: clock, timing: SessionTiming(), monitorService: service,
            removesMonitorsAutomatically: { automatic })
    }

    /// The current check finishing.
    private func settle(_ controller: SessionController) async {
        await controller.monitors.check?.value
        await controller.monitors.removal?.value
    }

    /// The link drops after streaming and the automatic attempt connects.
    private func reconnect(_ controller: SessionController) {
        factory.last.emit(.ended(.failed(error: .Transport(message: "lost"))))
        // Past the longest backoff: the series' next attempt runs.
        clock.advance(by: .seconds(16))
        factory.last.becomeStreaming()
    }

    @Test func eachConnectionIsCheckedWithoutDelayingTheSession() async {
        service.found = [.gliff(41, enabled: false)]
        let controller = controller()
        controller.connect()
        #expect(service.checks.isEmpty)
        factory.last.emit(.connected(.sample))
        // The session moves on while the check runs.
        #expect(controller.phase == .connecting(.awaitingVideo))
        #expect(controller.monitors.check != nil)
        await settle(controller)
        #expect(service.checks.map(\.host) == ["desk"])
        #expect(controller.monitors.offer?.outputs == [.gliff(41, enabled: false)])
        #expect(controller.monitors.offer?.host == "desk")
        #expect(controller.monitors.offer?.step == .asking)

        // Answered, then the next (automatic) connection is checked again.
        controller.monitors.ignoreOffered()
        factory.last.emit(.videoConfig(.sample()))
        reconnect(controller)
        await settle(controller)
        #expect(service.checks.count == 2)
    }

    @Test func mirrorSessionsAreCheckedWithTheirOwnSettings() async {
        let request = ConnectionRequest(host: "desk", user: "remi", headless: false, output: "DP-1")
        let controller = controller(request: request)
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        #expect(service.checks == [request.normalized])
        // Nothing found: nothing shown.
        #expect(controller.monitors.offer == nil)
        #expect(controller.monitors.notice == nil)
    }

    @Test func removeShowsEachResultThenCloses() async {
        service.found = [.gliff(41), .gliff(42), .gliff(43)]
        service.removal = { names in
            .finished(results: [
                OutputRemoval(name: names[0], outcome: .removed),
                OutputRemoval(name: names[1], outcome: .inUse),
                OutputRemoval(name: names[2], outcome: .failed),
            ])
        }
        let controller = controller()
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        controller.monitors.removeOffered()
        #expect(controller.monitors.offer?.step == .removing)
        await settle(controller)
        #expect(service.removals == [["gliff-41", "gliff-42", "gliff-43"]])
        guard case .finished(let results) = controller.monitors.offer?.step else {
            Issue.record("no result")
            return
        }
        #expect(results.map(\.outcome) == [.removed, .inUse, .failed])
        #expect(OrphanMonitors.summary(.finished(results))
            == "Removed 1 orphaned virtual monitor, 1 in use again, 1 could not be removed.")
        controller.monitors.dismissOffer()
        #expect(controller.monitors.offer == nil)
    }

    @Test func ignoredOutputsAreNotOfferedAgainInThatWindow() async {
        service.found = [.gliff(41)]
        let first = controller()
        first.connect()
        factory.last.becomeStreaming()
        await settle(first)
        first.monitors.ignoreOffered()
        #expect(first.monitors.offer == nil)
        #expect(service.removals.isEmpty)

        // Only what was not ignored is offered after the next connection.
        reconnect(first)
        await settle(first)
        #expect(service.checks.count == 2)
        #expect(first.monitors.offer == nil)
        service.found = [.gliff(41), .gliff(42)]
        reconnect(first)
        await settle(first)
        #expect(first.monitors.offer?.outputs == [.gliff(42)])

        // Another window asks again.
        let second = controller()
        second.connect()
        factory.last.becomeStreaming()
        await settle(second)
        #expect(second.monitors.offer?.outputs == [.gliff(41), .gliff(42)])
    }

    @Test func theAutomaticSettingRemovesWithoutAsking() async {
        service.found = [.gliff(41), .gliff(42)]
        let controller = controller(automatic: true)
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        #expect(controller.monitors.offer == nil)
        #expect(service.removals == [["gliff-41", "gliff-42"]])
        #expect(controller.monitors.notice == "Removed 2 orphaned virtual monitors.")
        clock.advance(by: OrphanMonitors.noticeDuration)
        #expect(controller.monitors.notice == nil)

        // A failed removal says so, briefly.
        service.found = [.gliff(43)]
        service.removal = { _ in throw GliffError.Transport(message: "lost") }
        reconnect(controller)
        await settle(controller)
        #expect(controller.monitors.notice == "Orphaned virtual monitors could not be removed.")
    }

    @Test func theCheckEndsWithItsSession() async {
        service.found = [.gliff(41)]
        service.holds = true
        let controller = controller()
        controller.connect()
        factory.last.becomeStreaming()
        let check = controller.monitors.check
        controller.disconnect()
        await check?.value
        #expect(service.cancelled == 1)
        #expect(controller.monitors.offer == nil)

        // A link loss cancels it too; the next connection checks again.
        controller.connect()
        factory.last.becomeStreaming()
        let lost = controller.monitors.check
        factory.last.emit(.ended(.failed(error: .Transport(message: "lost"))))
        await lost?.value
        #expect(service.cancelled == 2)
        service.holds = false
        clock.advance(by: .seconds(1))
        factory.last.becomeStreaming()
        await settle(controller)
        #expect(controller.monitors.offer?.outputs == [.gliff(41)])
    }

    @Test func anAutomaticRemovalEndsWithItsSessionAConfirmedOneDoesNot() async {
        service.found = [.gliff(41)]
        let automatic = controller(automatic: true)
        service.holdsRemovals = true
        automatic.connect()
        factory.last.becomeStreaming()
        await automatic.monitors.check?.value
        let removal = automatic.monitors.removal
        #expect(removal != nil)
        automatic.disconnect()
        await removal?.value
        #expect(service.cancelled == 1)
        #expect(automatic.monitors.removal == nil)
        #expect(automatic.monitors.notice == nil)

        let confirmed = controller()
        confirmed.connect()
        factory.last.becomeStreaming()
        await confirmed.monitors.check?.value
        confirmed.monitors.removeOffered()
        confirmed.disconnect()
        #expect(confirmed.monitors.removal?.isCancelled == false)
        #expect(confirmed.monitors.offer?.step == .removing)
        confirmed.close()
    }

    @Test func closingTheWindowCancelsARemoval() async {
        service.found = [.gliff(41)]
        let controller = controller()
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        service.holds = true
        controller.monitors.removeOffered()
        let removal = controller.monitors.removal
        controller.close()
        await removal?.value
        #expect(service.cancelled == 1)
        #expect(controller.monitors.offer == nil)
        #expect(controller.monitors.notice == nil)
    }

    @Test func unavailableHostsAndFailedChecksShowNothing() async {
        for answer in [
            OrphanCheck.unavailable(reason: .noHyprctl), .unavailable(reason: .noHyprland),
            .unavailable(reason: .hyprctlFailed), .cancelled,
        ] {
            service.check = { answer }
            let controller = controller()
            controller.connect()
            factory.last.becomeStreaming()
            await settle(controller)
            #expect(controller.monitors.offer == nil, "\(answer)")
            #expect(controller.monitors.notice == nil)
            controller.close()
        }
        service.check = { throw GliffError.Setup(message: "host key") }
        let controller = controller()
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        #expect(controller.monitors.offer == nil)
        #expect(controller.isStreaming)
    }

    @Test func aPendingOfferIsNotCheckedAgain() async {
        service.found = [.gliff(41)]
        let controller = controller()
        controller.connect()
        factory.last.becomeStreaming()
        await settle(controller)
        let offer = controller.monitors.offer
        reconnect(controller)
        await settle(controller)
        #expect(service.checks.count == 1)
        #expect(controller.monitors.offer == offer)
    }

    @Test func noServiceNoCheck() async {
        let controller = SessionController(
            factory: factory, registry: registry, recents: RecentConnections(defaults: defaults.store),
            request: ConnectionRequest(host: "desk"), scheduler: clock)
        controller.connect()
        factory.last.becomeStreaming()
        #expect(controller.monitors.check == nil)
    }

    @Test func rowsShowSizeStateAndResult() {
        #expect(OrphanMonitorSheet.detail(.gliff(1), result: nil) == "1920×1080")
        #expect(OrphanMonitorSheet.detail(.gliff(1, enabled: false), result: nil) == "1920×1080, disabled")
        #expect(OrphanMonitorSheet.detail(
            OrphanedOutput(name: "gliff-1", width: 0, height: 0, enabled: true), result: nil) == "Size unknown")
        #expect(OrphanMonitorSheet.detail(.gliff(1), result: .inUse) == "In use again, kept")
        #expect(OrphanMonitorSheet.removalNote(count: 1).hasPrefix("Removing it moves its"))
        #expect(OrphanMonitorSheet.removalNote(count: 2).hasPrefix("Removing them moves their"))
        #expect(OrphanMonitors.summary(.finished([OutputRemoval(name: "gliff-1", outcome: .removed)]))
            == "Removed 1 orphaned virtual monitor.")
    }
}
