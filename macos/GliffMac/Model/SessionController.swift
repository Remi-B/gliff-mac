import Foundation
import GliffCore
import os

/// One window's connection: form, session lifecycle and remote-surface state.
///
/// Every attempt gets a new `SessionID`. Events carry it, and an event from an
/// attempt other than the current one is ignored, so a replaced, disconnected
/// or closed session can never change this window's state. Sessions themselves
/// live in the shared `SessionRegistry` until they end, so input and clipboard
/// ownership (tasks 09 and 11) stay with the window that started them.
///
/// Networking, decoding and teardown run in the bridge; this type only reacts
/// to main-actor events and never blocks.
@MainActor
final class SessionController: ObservableObject {
    enum Phase: Equatable {
        /// No session yet: the connection form.
        case idle
        /// Starting SSH and the Gliff handshake for a first attempt.
        case connecting(ConnectionStep)
        /// The same, replacing a previous session with the same settings.
        case reconnecting(ConnectionStep)
        /// The server sent a video configuration; the remote surface is live.
        case streaming(StreamInfo)
        case failed(SessionFailure)
        case stopped(StopReason)
    }

    enum ConnectionStep: Equatable {
        /// SSH is connecting and the server is starting.
        case starting
        /// The server answered; waiting for its first video configuration.
        case awaitingVideo
    }

    enum StopReason: Equatable {
        /// The user disconnected.
        case disconnected
        /// The server ended the session.
        case serverClosed
    }

    /// What the surface shows about the stream, without bridge types.
    struct StreamInfo: Equatable {
        var width: UInt32
        var height: UInt32
        var output: String
        var headless: Bool
        /// 4:2:0 chroma: text and fine colour detail lose resolution.
        var reducedChroma: Bool
        /// The session decodes and shows video (`videoDisplay`).
        var displaysVideo: Bool
    }

    @Published var request: ConnectionRequest
    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { log.info("\(self.phaseLabel, privacy: .public) \(self.sessionLabel, privacy: .public)") } }
    }
    /// Shown next to the fields after a connection attempt.
    @Published private(set) var fieldErrors: [ConnectionRequest.Field: String] = [:]
    /// The last non-fatal message the server sent during this session.
    @Published private(set) var serverMessage: String?
    /// Whether the remote surface owns keyboard and pointer input.
    @Published private(set) var isCapturingInput = false
    /// The current session's decoded pictures, for the remote surface.
    @Published private(set) var videoDisplay: VideoDisplay?

    /// The settings of the current or last attempt, used by reconnect.
    private(set) var activeRequest: ConnectionRequest?
    private(set) var currentSession: SessionID?
    private var hello: ServerHello?
    private var isClosed = false

    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "session")
    private let factory: any SessionFactory
    private let registry: SessionRegistry
    private let recents: RecentConnections

    init(
        factory: any SessionFactory, registry: SessionRegistry, recents: RecentConnections,
        request: ConnectionRequest = ConnectionRequest()
    ) {
        self.factory = factory
        self.registry = registry
        self.recents = recents
        self.request = request
    }

    // MARK: State for views

    var isActive: Bool {
        switch phase {
        case .connecting, .reconnecting, .streaming: true
        case .idle, .failed, .stopped: false
        }
    }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    var canConnect: Bool { !isActive && !isClosed }
    var canDisconnect: Bool { isActive }
    var canReconnect: Bool {
        guard activeRequest != nil, !isClosed else { return false }
        switch phase {
        case .streaming, .stopped: return true
        case .failed(let failure): return !failure.isFatal
        case .idle, .connecting, .reconnecting: return false
        }
    }

    // MARK: Actions

    /// Validates the form and starts a session with it.
    func connect() {
        guard canConnect else { return }
        let request = request.normalized
        fieldErrors = request.validationErrors()
        guard fieldErrors.isEmpty else { return }
        start(request, phase: .connecting(.starting))
    }

    /// Replaces the current or last session with a new one, same settings.
    func reconnect() {
        guard canReconnect, let request = activeRequest else { return }
        endCurrentSession()
        start(request, phase: .reconnecting(.starting))
    }

    /// Cancels the session; its teardown completes in the background.
    func disconnect() {
        guard canDisconnect else { return }
        endCurrentSession()
        phase = .stopped(.disconnected)
    }

    /// Returns to the connection form after a failure or a stop.
    func editConnection() {
        guard !isActive else { return }
        phase = .idle
    }

    /// The window is closing: cancel and ignore everything that follows.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        endCurrentSession()
    }

    /// Fills the form from a recent connection.
    func use(_ recent: ConnectionRequest) {
        guard !isActive else { return }
        request = recent
        fieldErrors = [:]
    }

    // MARK: Input capture (forwarding arrives with task 09)

    func captureInput() {
        guard isStreaming else { return }
        isCapturingInput = true
    }

    /// The release shortcut, focus loss and every phase change end capture.
    func releaseInput() {
        isCapturingInput = false
    }

    // MARK: Session lifecycle

    private func start(_ request: ConnectionRequest, phase: Phase) {
        activeRequest = request
        serverMessage = nil
        hello = nil
        do {
            let session = try factory.makeSession(for: request)
            currentSession = try registry.start(session) { [weak self] id, event in
                self?.handle(event, from: id)
            }
            videoDisplay = session.videoDisplay
            self.phase = phase
        } catch {
            currentSession = nil
            videoDisplay = nil
            self.phase = .failed(SessionFailure(starting: error))
        }
    }

    private func endCurrentSession() {
        releaseInput()
        if let id = currentSession { registry.cancel(id) }
        currentSession = nil
        videoDisplay = nil
    }

    /// Applies an event from session `id`; stale sessions are ignored.
    func handle(_ event: SessionEvent, from id: SessionID) {
        guard id == currentSession, !isClosed else { return }
        switch event {
        case .connected(let hello):
            self.hello = hello
            if let request = activeRequest { recents.remember(request) }
            advance(to: .awaitingVideo)
        case .videoConfig(let config):
            phase = .streaming(
                StreamInfo(
                    width: config.width, height: config.height,
                    output: hello?.output ?? "", headless: hello?.headless ?? true,
                    reducedChroma: config.chroma == .single420, displaysVideo: videoDisplay != nil))
        case .serverError(let code, let message):
            serverMessage = "\(message) (code \(code))"
        case .cursorShape, .cursorPosition:
            // Cursor presentation arrives with the remote surface (tasks 07 and 09).
            break
        case .ended(let end):
            currentSession = nil
            videoDisplay = nil
            releaseInput()
            switch end {
            case .closed: phase = .stopped(.serverClosed)
            case .cancelled: phase = .stopped(.disconnected)
            case .failed(let error): phase = .failed(SessionFailure(error))
            }
        }
    }

    /// Lifecycle diagnostics: phase names and error titles, never hosts, users or paths.
    private var phaseLabel: String {
        switch phase {
        case .idle: "idle"
        case .connecting(let step): "connecting(\(step))"
        case .reconnecting(let step): "reconnecting(\(step))"
        case .streaming(let info): "streaming(\(info.width)x\(info.height))"
        // Failure messages are the bridge's fixed, redacted setup guidance.
        case .failed(let failure): "failed(\(failure.title): \(failure.message))"
        case .stopped(let reason): "stopped(\(reason))"
        }
    }

    private var sessionLabel: String { currentSession.map(String.init(describing:)) ?? "no-session" }

    private func advance(to step: ConnectionStep) {
        switch phase {
        case .connecting: phase = .connecting(step)
        case .reconnecting: phase = .reconnecting(step)
        default: break
        }
    }
}
