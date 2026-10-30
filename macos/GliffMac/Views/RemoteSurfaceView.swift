import AppKit
import SwiftUI

/// The streaming session: the remote surface and an honest status line.
struct RemoteSurfaceView: View {
    @ObservedObject var controller: SessionController
    let info: SessionController.StreamInfo
    @AppStorage(Preferences.captureInputKey) private var captureInput = Preferences.captureInputDefault

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let video = controller.videoDisplay?.diagnostics
            VStack(spacing: 0) {
                RemoteSurface(
                    display: controller.videoDisplay,
                    isCapturing: controller.isCapturingInput,
                    input: controller.input,
                    cursor: controller.remoteCursor,
                    onCapture: { if captureInput { controller.captureInput() } },
                    onRelease: { controller.releaseInput() }
                )
                .overlay { overlay(video) }
                .accessibilityElement()
                .accessibilityLabel("Remote desktop")
                .accessibilityValue(accessibilityValue(video))
                .accessibilityAddTraits(.allowsDirectInteraction)
                Divider()
                statusBar(video)
            }
        }
    }

    /// Shown until the first picture.
    @ViewBuilder private func overlay(_ video: VideoDisplay.Diagnostics?) -> some View {
        let waiting = !info.displaysVideo || (video?.presented ?? 0) == 0
        VStack(spacing: 8) {
            if waiting {
                if info.displaysVideo {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "display")
                        .font(.system(size: 44))
                        .accessibilityHidden(true)
                }
                Text("Connected to \(info.output.isEmpty ? "the server" : info.output)")
                    .font(.title3)
                Text(info.displaysVideo ? "Waiting for the first picture…" : "This session does not display video.")
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    private func statusBar(_ video: VideoDisplay.Diagnostics?) -> some View {
        HStack(spacing: 12) {
            Label("\(info.width)×\(info.height)", systemImage: info.headless ? "rectangle.dashed" : "rectangle.on.rectangle")
                .help(info.headless ? "Virtual display" : "Mirroring \(info.output)")
            if info.reducedChroma {
                Label("Reduced colour (4:2:0)", systemImage: "circle.lefthalf.filled")
                    .help("Full-chroma video arrives in a later version; fine text colour loses detail.")
            }
            if let video {
                if video.recovering {
                    Label("Decode error: waiting for a keyframe", systemImage: "exclamationmark.triangle")
                        .help("The picture is frozen on the last good frame until the server sends a keyframe.")
                } else if video.failed > 0 {
                    Label("\(video.failed) decode \(video.failed == 1 ? "error" : "errors")", systemImage: "exclamationmark.triangle")
                        .help("Frames VideoToolbox could not decode in this session; each one requested a keyframe.")
                }
                if video.hardwareAccelerated == false {
                    Label("Software decoding", systemImage: "cpu")
                        .help("VideoToolbox did not provide a hardware decoder for this stream.")
                }
            }
            if let message = controller.serverMessage {
                Label(message, systemImage: "exclamationmark.bubble")
                    .lineLimit(1)
            }
            Spacer()
            if let layout = controller.keyboardLayout {
                keyboardLabel(layout)
            }
            if controller.isCapturingInput {
                Text("Release input: \(Preferences.releaseShortcutDescription)")
            } else {
                Text("Click the surface to capture input")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The layout the remote types with, visible before input is captured:
    /// physical keys only, and a warning when the remote falls back to U.S.
    @ViewBuilder private func keyboardLabel(_ layout: KeyboardLayout) -> some View {
        if layout.isSupported {
            Label(layout.name, systemImage: "keyboard")
                .help("Keys are sent as physical keys with the \(layout.xkb.description) layout on the remote. "
                    + "Input methods, dictation and the emoji picker are not sent.")
        } else {
            Label("\(layout.name): U.S. keys", systemImage: "keyboard.badge.exclamationmark")
                .foregroundStyle(.orange)
                .help("The \(layout.name) input source has no matching remote layout yet: "
                    + "keys type as on a U.S. keyboard. U.S., ABC, French and French – PC are supported.")
        }
    }

    private func accessibilityValue(_ video: VideoDisplay.Diagnostics?) -> String {
        var parts = ["\(info.width) by \(info.height)"]
        switch (info.displaysVideo, video) {
        case (true, let video?) where video.recovering: parts.append("video frozen, recovering from a decode error")
        case (true, let video?) where video.presented > 0: parts.append("video displayed")
        case (true, _): parts.append("waiting for video")
        case (false, _): parts.append("video not displayed")
        }
        if info.reducedChroma { parts.append("reduced colour") }
        parts.append(controller.isCapturingInput ? "input captured" : "input not captured")
        if let layout = controller.keyboardLayout {
            parts.append(layout.isSupported ? "keyboard \(layout.name)" : "keyboard \(layout.name) not supported, U.S. keys")
        }
        return parts.joined(separator: ", ")
    }
}

/// The AppKit view that shows the decoded pictures in a Metal layer and
/// forwards focused native input. Clicking it requests input capture (the
/// click itself stays local); losing first responder or the key window, or
/// the release shortcut, releases capture.
struct RemoteSurface: NSViewRepresentable {
    var display: VideoDisplay?
    var isCapturing: Bool
    /// Where captured input goes; `nil` unless capturing.
    var input: InputForwarder?
    var cursor: RemoteCursor
    var onCapture: @MainActor () -> Void
    var onRelease: @MainActor () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: SurfaceView, coordinator: ()) {
        view.input = nil
        view.isCapturing = false
        view.display = nil
    }

    private func update(_ view: SurfaceView) {
        view.onCapture = onCapture
        view.onRelease = onRelease
        view.input = input
        view.remoteCursor = cursor
        view.isCapturing = isCapturing
        view.display = display
    }

    final class SurfaceView: NSView {
        var onCapture: (@MainActor () -> Void)?
        /// Ends capture: release shortcut, focus loss, window closing.
        var onRelease: (@MainActor () -> Void)?
        /// Set while capturing; keys, buttons, motion and scrolling go there.
        var input: InputForwarder?
        var isCapturing = false {
            didSet {
                guard isCapturing != oldValue else { return }
                border.borderWidth = isCapturing ? 2 : 0
                // Capture from the menu or toolbar: keys come here now.
                if isCapturing, let window, window.firstResponder !== self { window.makeFirstResponder(self) }
                updateKeyMonitor()
                cursorChanged()
            }
        }
        var remoteCursor = RemoteCursor.hidden {
            didSet { if remoteCursor != oldValue { cursorChanged() } }
        }
        /// The pictures to show. Replacing it detaches the previous one.
        var display: VideoDisplay? {
            didSet {
                guard display !== oldValue else { return }
                oldValue?.setObserver(nil)
                renderer?.reset()
                attach()
            }
        }

        private let videoLayer = CAMetalLayer()
        private let border = CALayer()
        /// A redraw is scheduled because the last one found no drawable.
        private var retryPending = false
        private(set) lazy var renderer: VideoRenderer? = {
            let renderer = VideoRenderer()
            renderer?.configure(videoLayer)
            return renderer
        }()
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
        /// The local key monitor, installed only while capturing in a window.
        nonisolated(unsafe) private var keyMonitor: Any?
        private var trackingArea: NSTrackingArea?
        private var builtCursor: (cursor: RemoteCursor, scale: CGFloat, value: NSCursor)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            videoLayer.backgroundColor = NSColor.black.cgColor
            border.borderColor = NSColor.controlAccentColor.cgColor
            layer?.addSublayer(videoLayer)
            layer?.addSublayer(border)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        override func resignFirstResponder() -> Bool {
            release()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            updateKeyMonitor()
            guard let window else { return }
            observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.release() }
                }
            }
            needsLayout = true
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        /// Sizes the drawable in backing pixels and redraws the last picture.
        override func layout() {
            super.layout()
            let scale = backingScale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            border.frame = bounds
            videoLayer.contentsScale = scale
            videoLayer.drawableSize = CGSize(
                width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            CATransaction.commit()
            render()
            // The remote cursor's size follows the picture's scale.
            if isCapturing { window?.invalidateCursorRects(for: self) }
        }

        private var backingScale: CGFloat {
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        }

        // MARK: Pointer

        /// The mapping for the picture on screen; `nil` before the first one.
        var pointerMapping: PointerMapping? {
            guard let geometry = display?.latest?.geometry else { return nil }
            return PointerMapping(viewSize: bounds.size, backingScale: backingScale, frame: geometry)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseDown(with event: NSEvent) { buttonDown(event) }
        override func rightMouseDown(with event: NSEvent) { buttonDown(event) }
        override func otherMouseDown(with event: NSEvent) { buttonDown(event) }
        override func mouseUp(with event: NSEvent) { buttonUp(event) }
        override func rightMouseUp(with event: NSEvent) { buttonUp(event) }
        override func otherMouseUp(with event: NSEvent) { buttonUp(event) }
        override func mouseMoved(with event: NSEvent) { move(event) }
        // Drags keep coming outside the view and the window; they clamp.
        override func mouseDragged(with event: NSEvent) { move(event) }
        override func rightMouseDragged(with event: NSEvent) { move(event) }
        override func otherMouseDragged(with event: NSEvent) { move(event) }

        override func scrollWheel(with event: NSEvent) {
            input?.scroll(PointerEvents.scroll(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                momentumPhase: event.momentumPhase))
        }

        private func buttonDown(_ event: NSEvent) {
            guard let input else {
                // The click that captures input is not sent.
                window?.makeFirstResponder(self)
                onCapture?()
                return
            }
            move(event)
            input.button(event.buttonNumber, pressed: true)
        }

        private func buttonUp(_ event: NSEvent) {
            guard let input else { return }
            move(event)
            input.button(event.buttonNumber, pressed: false)
        }

        private func move(_ event: NSEvent) {
            guard let input, let point = pointerMapping?.remotePoint(convert(event.locationInWindow, from: nil))
            else { return }
            input.move(to: point)
        }

        // MARK: Keyboard

        /// Keys reach the forwarder through a local monitor rather than
        /// `keyDown`: it sees Command chords before menu key equivalents and
        /// key-ups that AppKit does not deliver while Command is down. It
        /// exists only while capturing and takes only this window's events
        /// while the surface is first responder.
        private func updateKeyMonitor() {
            let wanted = isCapturing && window != nil
            if wanted, keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
                    [weak self] event in
                    let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                    return consumed ? nil : event
                }
            } else if !wanted, let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        /// Forwards a key event; true when it was consumed. The release
        /// shortcut is consumed and never sent.
        func handleKey(_ event: NSEvent) -> Bool {
            guard let input, event.window === window, window?.firstResponder === self else { return false }
            switch event.type {
            case .keyDown:
                if Preferences.isReleaseShortcut(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
                    release()
                } else {
                    input.keyDown(event.keyCode, isRepeat: event.isARepeat)
                }
            case .keyUp:
                input.keyUp(event.keyCode)
            case .flagsChanged:
                input.flagsChanged(event.keyCode, modifierFlags: UInt(event.modifierFlags.rawValue))
            default:
                return false
            }
            return true
        }

        /// Ends capture now; the controller releases what the remote holds.
        private func release() {
            guard input != nil || isCapturing else { return }
            onRelease?()
            input = nil
            isCapturing = false
        }

        // MARK: Cursor

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: currentCursor())
        }

        /// The remote cursor while capturing, the arrow otherwise.
        private func currentCursor() -> NSCursor {
            guard isCapturing else { return .arrow }
            let scale = pointerMapping?.pointsPerStreamPixel ?? 1 / backingScale
            if let built = builtCursor, built.cursor == remoteCursor, built.scale == scale {
                return built.value
            }
            let cursor = remoteCursor.makeCursor(pointsPerPixel: scale)
            builtCursor = (remoteCursor, scale, cursor)
            return cursor
        }

        private func cursorChanged() {
            guard let window else { return }
            window.invalidateCursorRects(for: self)
            let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            if inside, window.isKeyWindow { currentCursor().set() }
        }

        // MARK: Pictures

        private func attach() {
            guard let display else { return }
            let target = WeakSurface(self)
            // Called off the main thread at most once per waiting picture.
            display.setObserver {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { target.view?.render() }
                }
            }
            render()
        }

        private func render() {
            guard window != nil, let display, let renderer else { return }
            // `take` marks the picture shown, and a static desktop sends no
            // other: without a drawable, try again shortly (one retry pending).
            if !renderer.draw(display.take(), in: videoLayer), !retryPending {
                retryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.retryPending = false
                        self?.render()
                    }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
    }
}

/// Lets the display's observer reach the surface without retaining it.
private final class WeakSurface: @unchecked Sendable {
    weak var view: RemoteSurface.SurfaceView?
    init(_ view: RemoteSurface.SurfaceView) { self.view = view }
}
