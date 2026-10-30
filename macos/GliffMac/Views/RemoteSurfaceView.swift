import AppKit
import SwiftUI

/// The streaming session: the remote surface and an honest status line.
struct RemoteSurfaceView: View {
    @ObservedObject var controller: SessionController
    let info: SessionController.StreamInfo
    @AppStorage(Preferences.captureInputKey) private var captureInput = Preferences.captureInputDefault

    var body: some View {
        VStack(spacing: 0) {
            RemoteSurface(
                isCapturing: controller.isCapturingInput,
                onCapture: { if captureInput { controller.captureInput() } },
                onFocusLost: { controller.releaseInput() }
            )
            .overlay { placeholder }
            .accessibilityElement()
            .accessibilityLabel("Remote desktop")
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.allowsDirectInteraction)
            Divider()
            statusBar
        }
    }

    /// Video decoding and display arrive with task 07.
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 44))
                .accessibilityHidden(true)
            Text("Connected to \(info.output.isEmpty ? "the server" : info.output)")
                .font(.title3)
            Text("Video is received but not displayed yet in this build.")
                .foregroundStyle(.secondary)
            if controller.isCapturingInput {
                Text("Input capture is on, but keys and pointer are not sent yet. "
                    + "Press \(Preferences.releaseShortcutDescription) to release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label("\(info.width)×\(info.height)", systemImage: info.headless ? "rectangle.dashed" : "rectangle.on.rectangle")
                .help(info.headless ? "Virtual display" : "Mirroring \(info.output)")
            if info.reducedChroma {
                Label("Reduced colour (4:2:0)", systemImage: "circle.lefthalf.filled")
                    .help("Full-chroma video arrives in a later version; fine text colour loses detail.")
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

    private var accessibilityValue: String {
        var parts = ["\(info.width) by \(info.height)", "video not displayed yet"]
        if info.reducedChroma { parts.append("reduced colour") }
        parts.append(controller.isCapturingInput ? "input captured" : "input not captured")
        return parts.joined(separator: ", ")
    }
}

/// The AppKit view that will host the Metal layer (tasks 07–08) and receive
/// focused native input (task 09). Clicking it requests input capture;
/// losing first responder or the key window releases capture.
struct RemoteSurface: NSViewRepresentable {
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

    private func update(_ view: SurfaceView) {
        view.onCapture = onCapture
        view.onFocusLost = onFocusLost
        view.isCapturing = isCapturing
    }

    final class SurfaceView: NSView {
        var onCapture: (@MainActor () -> Void)?
        var onFocusLost: (@MainActor () -> Void)?
        var isCapturing = false {
            didSet { if isCapturing != oldValue { needsDisplay = true } }
        }
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
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
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isCapturing else { return }
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
