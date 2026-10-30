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
                    onCapture: { if captureInput { controller.captureInput() } },
                    onFocusLost: { controller.releaseInput() }
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

    /// Shown until the first picture, and while input is captured, since
    /// keys and the pointer are not forwarded yet (task 09).
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
            if controller.isCapturingInput {
                Text("Input capture is on, but keys and pointer are not sent yet. "
                    + "Press \(Preferences.releaseShortcutDescription) to release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        return parts.joined(separator: ", ")
    }
}

/// The AppKit view that shows the decoded pictures in a Metal layer and will
/// receive focused native input (task 09). Clicking it requests input
/// capture; losing first responder or the key window releases capture.
struct RemoteSurface: NSViewRepresentable {
    var display: VideoDisplay?
    var isCapturing: Bool
    var onCapture: @MainActor () -> Void
    var onFocusLost: @MainActor () -> Void

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: SurfaceView, coordinator: ()) {
        view.display = nil
    }

    private func update(_ view: SurfaceView) {
        view.onCapture = onCapture
        view.onFocusLost = onFocusLost
        view.isCapturing = isCapturing
        view.display = display
    }

    final class SurfaceView: NSView {
        var onCapture: (@MainActor () -> Void)?
        var onFocusLost: (@MainActor () -> Void)?
        var isCapturing = false {
            didSet { border.borderWidth = isCapturing ? 2 : 0 }
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

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onCapture?()
        }

        override func resignFirstResponder() -> Bool {
            onFocusLost?()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.onFocusLost?() }
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
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            border.frame = bounds
            videoLayer.contentsScale = scale
            videoLayer.drawableSize = CGSize(
                width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
            CATransaction.commit()
            render()
        }

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
        }
    }
}

/// Lets the display's observer reach the surface without retaining it.
private final class WeakSurface: @unchecked Sendable {
    weak var view: RemoteSurface.SurfaceView?
    init(_ view: RemoteSurface.SurfaceView) { self.view = view }
}
