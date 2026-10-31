import AppKit
import GliffCore
import os

/// One window's connection: form, session lifecycle and remote-surface state.
///
/// Every attempt gets a new `SessionID`. Events carry it, and an event from an
/// attempt other than the current one is ignored, so a replaced, disconnected
/// or closed session can never change this window's state. Sessions themselves
/// live in the shared `SessionRegistry` until they end, so input and clipboard
/// ownership (tasks 09 and 11) stay with the window that started them. Each
/// session gets its own `InputForwarder`, so capture is per window.
///
/// A session that loses its link after streaming is replaced automatically:
/// a new attempt (new `SessionID`, SSH process, handshake, decoder and input
/// state) after a bounded backoff. Only link failures are retried; setup
/// refusals, incompatible servers and the user's own disconnect are not.
/// Sleep ends the session and wake starts a new one; a network that comes
/// back cuts the current backoff short.
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
        /// Reconnecting only: waiting for the next attempt (`reconnection`),
        /// or for the Mac to wake.
        case waiting
    }

    /// An automatic reconnect series after a lost link.
    struct Reconnection: Equatable {
        /// The attempt running or about to run, from 1.
        var attempt: Int
        let limit: Int
        /// Why the previous session ended, for the user.
        var reason: String
        /// Waiting for the Mac to wake rather than for a delay.
        var awaitingWake = false
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
    /// The local layout the remote keymap follows, shown before input is used.
    @Published private(set) var keyboardLayout: KeyboardLayout?
    /// The pointer the surface shows while input is captured.
    @Published private(set) var remoteCursor = RemoteCursor.hidden
    @Published private(set) var remoteCursorPosition: CursorPosition?
    /// Capture-buffer pixels per logical output point (HelloAck), distinct
    /// from the stream's effective scale after encoder downscaling.
    @Published private(set) var cursorOutputScale: CGFloat = 1
    /// The automatic reconnect series in progress, if any.
    @Published private(set) var reconnection: Reconnection?
    /// Links lost and restored automatically in this window.
    @Published private(set) var reconnectCount = 0

    /// The settings of the current or last attempt, used by reconnect.
    private(set) var activeRequest: ConnectionRequest?
    private(set) var currentSession: SessionID?
    private var hello: ServerHello?
    private var isClosed = false
    /// The current session's input state; `nil` without a session.
    private var forwarder: InputForwarder?
    private var cursorImage: RemoteCursorImage?
    private let currentLayout: @MainActor () -> KeyboardLayout
    nonisolated(unsafe) private var layoutObserver: (any NSObjectProtocol)?
    /// The current session, for messages that are not captured input.
    private weak var session: (any RemoteSession)?
    /// The next automatic attempt, or the pending resize.
    private var pendingAttempt: (any ScheduledAction)?
    private var pendingResize: (any ScheduledAction)?
    /// When the current session started streaming.
    private var streamingSince: ContinuousClock.Instant?
    /// The surface in backing pixels and its scale, and what the current
    /// session was last asked to match.
    private var viewport: Viewport?
    private var requestedViewport: Viewport?

    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "session")
    private let factory: any SessionFactory
    private let registry: SessionRegistry
    private let recents: RecentConnections
    private let scheduler: any Scheduler
    let timing: SessionTiming

    init(
        factory: any SessionFactory, registry: SessionRegistry, recents: RecentConnections,
        request: ConnectionRequest = ConnectionRequest(),
        currentLayout: @escaping @MainActor () -> KeyboardLayout = KeyboardLayout.current,
        scheduler: any Scheduler = TaskScheduler(), timing: SessionTiming = SessionTiming()
    ) {
        self.factory = factory
        self.registry = registry
        self.recents = recents
        self.request = request
        self.currentLayout = currentLayout
        self.scheduler = scheduler
        self.timing = timing
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: KeyboardLayout.selectionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardLayoutChanged() }
        }
    }

    deinit {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
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
        // Waiting between automatic attempts: start a fresh one now.
        case .reconnecting(.waiting): return true
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
        stopReconnecting()
        start(request, phase: .connecting(.starting))
    }

    /// Replaces the current or last session with a new one, same settings.
    func reconnect() {
        guard canReconnect, let request = activeRequest else { return }
        endCurrentSession()
        stopReconnecting()
        start(request, phase: .reconnecting(.starting))
    }

    /// Cancels the session and any automatic reconnect at once; teardown
    /// completes in the background.
    func disconnect() {
        guard canDisconnect else { return }
        endCurrentSession()
        stopReconnecting()
        phase = .stopped(.disconnected)
    }

    /// Runs the waiting automatic attempt now.
    func retryNow() {
        guard case .reconnecting(.waiting) = phase, let reconnection, !reconnection.awaitingWake else { return }
        attemptReconnect()
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
        stopReconnecting()
    }

    // MARK: System events

    /// The Mac is going to sleep: end the session now, while SSH can still
    /// say goodbye, and start a new one on wake.
    func systemWillSleep() {
        guard isActive, !isClosed else { return }
        endCurrentSession()
        pendingAttempt?.cancel()
        pendingAttempt = nil
        reconnection = Reconnection(
            attempt: 1, limit: timing.attemptLimit, reason: "The Mac went to sleep.", awaitingWake: true)
        phase = .reconnecting(.waiting)
    }

    func systemDidWake() {
        guard reconnection?.awaitingWake == true, !isClosed else { return }
        reconnection?.awaitingWake = false
        attemptReconnect()
    }

    /// A network path became available: a waiting attempt need not wait.
    func networkBecameAvailable() {
        retryNow()
    }

    // MARK: Display size

    struct Viewport: Equatable {
        var width: UInt32
        var height: UInt32
        var scale: Float
    }

    /// The remote surface's size in backing pixels and its scale. Once the
    /// size holds for `timing.resizeSettle`, the server is asked to match
    /// it: a virtual display is resized at this scale, and a mirrored output
    /// is scaled to fit. The picture follows the server's next configuration.
    func surfaceChanged(pixelWidth: CGFloat, pixelHeight: CGFloat, scale: CGFloat) {
        guard pixelWidth.isFinite, pixelHeight.isFinite, scale.isFinite, scale > 0 else { return }
        // Even sizes, as the server requires; it ignores less than 320×240.
        let viewport = Viewport(
            width: UInt32(max(0, pixelWidth.rounded())) & ~1, height: UInt32(max(0, pixelHeight.rounded())) & ~1,
            scale: Float(scale))
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        scheduleResize()
    }

    private func scheduleResize() {
        pendingResize?.cancel()
        pendingResize = scheduler.after(timing.resizeSettle) { [weak self] in
            self?.pendingResize = nil
            self?.sendResize()
        }
    }

    private func sendResize() {
        guard isStreaming, let viewport, viewport != requestedViewport, let session,
            viewport.width >= 320, viewport.height >= 240
        else { return }
        if session.send(.resize(width: viewport.width, height: viewport.height, scale: viewport.scale)) {
            requestedViewport = viewport
        } else {
            // The input queue is full: try again once it has drained.
            scheduleResize()
        }
    }

    /// Fills the form from a recent connection.
    func use(_ recent: ConnectionRequest) {
        guard !isActive else { return }
        request = recent
        fieldErrors = [:]
    }

    // MARK: Input capture

    /// Where the surface sends captured input; `nil` unless capturing.
    var input: InputForwarder? { isCapturingInput ? forwarder : nil }

    func captureInput() {
        guard isStreaming, let forwarder else { return }
        keyboardLayout = forwarder.syncLayout()
        isCapturingInput = forwarder.activate()
    }

    /// The release shortcut, focus loss and every phase change end capture,
    /// and release every key and button still down on the remote.
    func releaseInput() {
        forwarder?.deactivate()
        isCapturingInput = false
    }

    /// macOS selected another input source: the remote gets its keymap now,
    /// ahead of any key typed with it.
    func keyboardLayoutChanged() {
        keyboardLayout = forwarder?.syncLayout() ?? currentLayout()
    }

    // MARK: Session lifecycle

    private func start(_ request: ConnectionRequest, phase: Phase) {
        activeRequest = request
        serverMessage = nil
        hello = nil
        setCursorImage(nil)
        remoteCursorPosition = nil
        cursorOutputScale = 1
        requestedViewport = nil
        streamingSince = nil
        do {
            let session = try factory.makeSession(for: request)
            currentSession = try registry.start(session) { [weak self] id, event in
                self?.handle(event, from: id)
            }
            self.session = session
            videoDisplay = session.videoDisplay
            forwarder = InputForwarder(
                layout: session.keyboardLayout, active: false, currentLayout: currentLayout,
                onFailure: { [weak self] in self?.inputFailed() },
                sink: { [weak session] in session?.send($0) ?? false })
            keyboardLayout = session.keyboardLayout ?? currentLayout()
            self.phase = phase
        } catch {
            currentSession = nil
            videoDisplay = nil
            stopReconnecting()
            self.phase = .failed(SessionFailure(starting: error))
        }
    }

    /// Starts the next automatic attempt of the current series.
    private func attemptReconnect() {
        pendingAttempt?.cancel()
        pendingAttempt = nil
        guard let request = activeRequest, !isClosed else { return }
        start(request, phase: .reconnecting(.starting))
    }

    /// The current session lost its link: wait, then try again, until the
    /// series reaches its limit.
    private func linkLost(_ reason: String, failure: SessionFailure?) {
        let streamedLong = streamingSince.map { scheduler.now - $0 >= timing.stableAfter } ?? false
        let attempt = (streamedLong ? 0 : reconnection?.attempt ?? 0) + 1
        guard attempt <= timing.attemptLimit else {
            stopReconnecting()
            let detail = failure.map { "\($0.message) " } ?? "\(reason) "
            phase = .failed(SessionFailure(
                title: failure?.title ?? "The connection was lost",
                message: detail + "Gliff tried \(timing.attemptLimit) times to reconnect.",
                isLinkFailure: true))
            return
        }
        reconnection = Reconnection(attempt: attempt, limit: timing.attemptLimit, reason: reason)
        phase = .reconnecting(.waiting)
        pendingAttempt = scheduler.after(timing.reconnectDelays[attempt - 1]) { [weak self] in
            self?.attemptReconnect()
        }
    }

    private func stopReconnecting() {
        pendingAttempt?.cancel()
        pendingAttempt = nil
        reconnection = nil
    }

    private func inputFailed() {
        endCurrentSession()
        phase = .failed(SessionFailure(
            title: "Input could not be delivered",
            message: "The session was disconnected to release remote keys and buttons. Reconnect to continue."))
    }

    private func endCurrentSession() {
        releaseInput()
        forwarder?.finish()
        if let id = currentSession { registry.cancel(id) }
        forgetSession()
    }

    /// Drops everything tied to the current session: its input state (no
    /// key is replayed into a later one), pictures and pending resize.
    private func forgetSession() {
        currentSession = nil
        session = nil
        videoDisplay = nil
        forwarder = nil
        pendingResize?.cancel()
        pendingResize = nil
        requestedViewport = nil
    }

    private func setCursorImage(_ image: RemoteCursorImage?) {
        cursorImage = image
        remoteCursor = RemoteCursor(image: image, headless: hello?.headless ?? true)
    }

    /// Applies an event from session `id`; stale sessions are ignored.
    func handle(_ event: SessionEvent, from id: SessionID) {
        guard id == currentSession, !isClosed else { return }
        switch event {
        case .connected(let hello):
            self.hello = hello
            cursorOutputScale = CGFloat(hello.outputs.first { $0.name == hello.output }?.scaleMilli ?? 1000) / 1000
            setCursorImage(cursorImage)
            if let request = activeRequest { recents.remember(request) }
            advance(to: .awaitingVideo)
        case .videoConfig(let config):
            if !isStreaming {
                streamingSince = scheduler.now
                if reconnection != nil { reconnectCount += 1 }
                // A series ends once a session streams long enough; until
                // then a quick failure continues it (see `linkLost`).
            }
            updateCursorOutputScale(config)
            phase = .streaming(
                StreamInfo(
                    width: config.width, height: config.height,
                    output: hello?.output ?? "", headless: hello?.headless ?? true,
                    reducedChroma: config.chroma == .single420, displaysVideo: videoDisplay != nil))
            // A new session, or a configuration that does not match the
            // surface yet (the server may still pick another size).
            if viewport != requestedViewport { scheduleResize() }
        case .serverError(let code, let message):
            serverMessage = "\(message) (code \(code))"
        case .cursorShape(let shape):
            // A malformed shape keeps the previous one.
            if let image = RemoteCursorImage(shape) { setCursorImage(image) }
        case .cursorPosition(let position):
            remoteCursorPosition = position
        case .ended(let end):
            forwarder?.finish()
            isCapturingInput = false
            // Only a link that worked, or a series already running, is
            // retried: a first attempt's failure goes to the user.
            let retrying = isStreaming || reconnection != nil
            forgetSession()
            switch end {
            case .closed where retrying:
                linkLost("The server ended the session.", failure: nil)
            case .failed(let error) where retrying && SessionFailure(error).isLinkFailure:
                let failure = SessionFailure(error)
                linkLost(failure.message, failure: failure)
            case .closed:
                stopReconnecting()
                phase = .stopped(.serverClosed)
            case .cancelled:
                stopReconnecting()
                phase = .stopped(.disconnected)
            case .failed(let error):
                stopReconnecting()
                phase = .failed(SessionFailure(error))
            }
        }
    }

    /// A virtual display takes the scale of each `Resize`, and no new
    /// `HelloAck` says so. Upstream's effective scale is the output scale
    /// times the stream's downscale, so an undownscaled stream (its width
    /// that of the requested display) gives the scale the server applied;
    /// otherwise the requested one is the best estimate. A mirrored output
    /// keeps its own scale.
    private func updateCursorOutputScale(_ config: VideoConfig) {
        guard hello?.headless == true, let requested = requestedViewport else { return }
        let undownscaled = config.width + 16 >= requested.width
        cursorOutputScale = undownscaled ? CGFloat(config.scaleMilli) / 1000 : CGFloat(requested.scale)
    }

    /// Lifecycle diagnostics: phase names and error titles, never hosts, users or paths.
    private var phaseLabel: String {
        switch phase {
        case .idle: "idle"
        case .connecting(let step): "connecting(\(step))"
        case .reconnecting(let step):
            // Reasons are fixed, redacted bridge guidance, as for failures.
            "reconnecting(\(step)) attempt \(reconnection?.attempt ?? 0)/\(reconnection?.limit ?? 0): \(reconnection?.reason ?? "")"
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
