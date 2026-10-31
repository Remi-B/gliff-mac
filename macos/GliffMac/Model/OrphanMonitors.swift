import Foundation
import GliffCore
import os

/// Checks and removes a host's orphaned Gliff virtual monitors: `gliff-<pid>`
/// headless outputs whose server no longer runs (task 14). `LiveMonitorService`
/// runs the bridge's `HostMonitors`; tests substitute a fake.
protocol MonitorService: Sendable {
    /// Cancelling the calling task stops the check and its SSH process.
    func findOrphans(on request: ConnectionRequest) async throws -> OrphanCheck
    /// Removes `names`, re-checking each one's server right before.
    func remove(_ names: [String], on request: ConnectionRequest) async throws -> OrphanRemoval
}

/// A separate SSH command per call, with the session's SSH policy.
struct LiveMonitorService: MonitorService {
    func findOrphans(on request: ConnectionRequest) async throws -> OrphanCheck {
        let monitors = try HostMonitors(target: request.target())
        return try await withTaskCancellationHandler {
            try await monitors.findOrphans()
        } onCancel: {
            monitors.cancel()
        }
    }

    func remove(_ names: [String], on request: ConnectionRequest) async throws -> OrphanRemoval {
        let monitors = try HostMonitors(target: request.target())
        return try await withTaskCancellationHandler {
            try await monitors.removeOrphans(names: names)
        } onCancel: {
            monitors.cancel()
        }
    }
}

/// One window's orphaned-monitor check: run after every successful
/// connection, offered in a sheet, or removed at once when the user's
/// setting says so.
///
/// The check never delays the session: it is a separate SSH command, and it
/// is cancelled when its session ends, as is an automatic removal. A removal
/// the user confirmed runs to its end unless the window closes. Outputs the user ignored are not
/// offered again in this window.
@MainActor
final class OrphanMonitors: ObservableObject {
    struct Offer: Identifiable, Equatable {
        enum Step: Equatable {
            /// Waiting for Remove or Ignore.
            case asking
            case removing
            /// One result per output.
            case finished([OutputRemoval])
            /// The removal itself failed: SSH or the host.
            case failed(String)
        }

        let id = UUID()
        /// The session's request: the removal uses the same SSH settings.
        let request: ConnectionRequest
        let outputs: [OrphanedOutput]
        /// The host as the form names it.
        var host: String { request.displayName }
        var step = Step.asking
    }

    /// Drives the confirmation sheet.
    @Published private(set) var offer: Offer?
    /// The automatic removal's short status, shown for `noticeDuration`.
    @Published private(set) var notice: String?

    /// Running work, for tests to await.
    private(set) var check: Task<Void, Never>?
    private(set) var removal: Task<Void, Never>?
    /// The running removal follows the automatic setting, not the sheet.
    private var removalIsAutomatic = false
    /// Identifies the current check: a stale one's result is dropped.
    private var checkID = 0
    private var ignored: Set<String> = []
    private var noticeTimer: (any ScheduledAction)?
    private var isClosed = false

    /// `nil`: hosts are not checked (controllers in unrelated tests).
    private let service: (any MonitorService)?
    private let automatic: @MainActor () -> Bool
    private let scheduler: any Scheduler
    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "monitors")
    static let noticeDuration: Duration = .seconds(10)

    /// The user's setting, read at each check.
    static func automaticSetting() -> Bool {
        UserDefaults.standard.bool(forKey: Preferences.autoRemoveOrphanedMonitorsKey)
    }

    init(
        service: (any MonitorService)?, scheduler: any Scheduler,
        automatic: @escaping @MainActor () -> Bool = OrphanMonitors.automaticSetting
    ) {
        self.service = service
        self.scheduler = scheduler
        self.automatic = automatic
    }

    /// A session connected (first attempt, reconnection or mirror): check its
    /// host, unless a check, an offer or a removal is still in progress.
    func sessionConnected(_ request: ConnectionRequest) {
        guard let service, !isClosed, check == nil, offer == nil, removal == nil else { return }
        checkID += 1
        let id = checkID
        check = Task { [weak self] in
            let result: Result<OrphanCheck, any Error>
            do {
                result = .success(try await service.findOrphans(on: request))
            } catch {
                result = .failure(error)
            }
            self?.checked(result, request: request, id: id)
        }
    }

    /// The session ended: its check and automatic removal stop; an offer
    /// and a confirmed removal stay.
    func sessionEnded() {
        check?.cancel()
        check = nil
        if removalIsAutomatic {
            removal?.cancel()
            removal = nil
        }
    }

    /// The window is closing: stop everything and show nothing more.
    func close() {
        isClosed = true
        check?.cancel()
        check = nil
        removal?.cancel()
        removal = nil
        offer = nil
        clearNotice()
    }

    func removeOffered() {
        guard var offer, offer.step == .asking else { return }
        offer.step = .removing
        self.offer = offer
        startRemoval(offer.outputs, on: offer.request, automatic: false)
    }

    /// Not offered again in this window.
    func ignoreOffered() {
        guard let offer, offer.step == .asking else { return }
        ignored.formUnion(offer.outputs.map(\.name))
        log.info("orphaned monitors: ignored \(offer.outputs.count): \(Self.names(offer.outputs), privacy: .public)")
        self.offer = nil
    }

    /// Closes the sheet once the removal finished.
    func dismissOffer() {
        guard let offer else { return }
        switch offer.step {
        case .asking: ignoreOffered()
        case .removing: break
        case .finished, .failed: self.offer = nil
        }
    }

    // MARK: Steps

    private func checked(_ result: Result<OrphanCheck, any Error>, request: ConnectionRequest, id: Int) {
        // A cancelled check (session ended, window closed) shows nothing.
        guard !isClosed, id == checkID, check?.isCancelled == false else { return }
        check = nil
        let outputs: [OrphanedOutput]
        switch result {
        case .success(.found(let found)):
            outputs = found.filter { !ignored.contains($0.name) }
            log.info("orphaned monitors: \(found.count) found, \(found.count - outputs.count) ignored before: \(Self.names(found), privacy: .public)")
        case .success(.unavailable(let reason)):
            log.info("orphaned monitors: not checked: \(String(describing: reason), privacy: .public)")
            return
        case .success(.cancelled):
            return
        case .failure(let error):
            log.error("orphaned monitors: check failed: \(Self.kind(of: error), privacy: .public)")
            return
        }
        guard !outputs.isEmpty else { return }
        if automatic() {
            startRemoval(outputs, on: request, automatic: true)
        } else {
            offer = Offer(request: request, outputs: outputs)
        }
    }

    private func startRemoval(_ outputs: [OrphanedOutput], on request: ConnectionRequest, automatic: Bool) {
        guard let service else { return }
        removalIsAutomatic = automatic
        removal = Task { [weak self] in
            let result: Result<OrphanRemoval, any Error>
            do {
                result = .success(try await service.remove(outputs.map(\.name), on: request))
            } catch {
                result = .failure(error)
            }
            self?.removed(result, automatic: automatic)
        }
    }

    private func removed(_ result: Result<OrphanRemoval, any Error>, automatic: Bool) {
        guard !isClosed, removal?.isCancelled == false else { return }
        removal = nil
        let step: Offer.Step
        switch result {
        case .success(.finished(let results)):
            let count = { (outcome: RemovalOutcome) in results.filter { $0.outcome == outcome } }
            log.info("orphaned monitors: removed \(count(.removed).count) \(Self.names(count(.removed)), privacy: .public); in use \(count(.inUse).count) \(Self.names(count(.inUse)), privacy: .public); failed \(count(.failed).count) \(Self.names(count(.failed)), privacy: .public)")
            step = .finished(results)
        case .success(.unavailable(let reason)):
            log.info("orphaned monitors: removal not possible: \(String(describing: reason), privacy: .public)")
            step = .failed("Hyprland could not be reached on the host. Nothing was removed.")
        case .success(.cancelled):
            return
        case .failure(let error):
            log.error("orphaned monitors: removal failed: \(Self.kind(of: error), privacy: .public)")
            step = .failed(SessionFailure(starting: error).message)
        }
        if automatic {
            showNotice(Self.summary(step))
        } else {
            offer?.step = step
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = scheduler.after(Self.noticeDuration) { [weak self] in self?.clearNotice() }
    }

    private func clearNotice() {
        noticeTimer?.cancel()
        noticeTimer = nil
        notice = nil
    }

    // MARK: Text

    /// One line for the automatic setting's status.
    static func summary(_ step: Offer.Step) -> String {
        switch step {
        case .finished(let results):
            let removed = results.filter { $0.outcome == .removed }.count
            let inUse = results.filter { $0.outcome == .inUse }.count
            let failed = results.filter { $0.outcome == .failed }.count
            var parts = ["Removed \(removed) orphaned virtual \(removed == 1 ? "monitor" : "monitors")"]
            if inUse > 0 { parts.append("\(inUse) in use again") }
            if failed > 0 { parts.append("\(failed) could not be removed") }
            return parts.joined(separator: ", ") + "."
        case .failed:
            return "Orphaned virtual monitors could not be removed."
        case .asking, .removing:
            return ""
        }
    }

    /// Output names only: no host, user or path.
    private static func names(_ outputs: [OrphanedOutput]) -> String {
        outputs.map(\.name).joined(separator: " ")
    }

    private static func names(_ results: [OutputRemoval]) -> String {
        results.map(\.name).joined(separator: " ")
    }

    /// The error's case, never its text.
    private static func kind(of error: any Error) -> String {
        guard let error = error as? GliffError else { return "other" }
        return switch error {
        case .Transport: "transport"
        case .Setup: "setup"
        case .Protocol: "protocol"
        case .InvalidOptions: "invalid options"
        default: "other"
        }
    }
}
