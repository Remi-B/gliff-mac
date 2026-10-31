import AppKit
import SwiftUI

/// The root of one window: its own controller, and so its own session.
struct SessionWindow: View {
    @StateObject private var controller: SessionController
    private let recents: RecentConnections

    init(services: AppServices) {
        _controller = StateObject(wrappedValue: services.makeController())
        recents = services.recents
    }

    var body: some View {
        content
            .frame(minWidth: 640, minHeight: 420)
            .navigationTitle(title)
            .toolbar { SessionToolbar(controller: controller) }
            .focusedSceneObject(controller)
            .environmentObject(recents)
            .background(WindowCloseObserver { controller.close() })
            .onDisappear { controller.close() }
            #if DEBUG
            .onAppear { DebugAutoConnect.apply(to: controller) }
            #endif
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle, .stopped:
            ConnectionForm(controller: controller)
        case .connecting(let step), .reconnecting(let step):
            ConnectingView(controller: controller, step: step)
        case .streaming(let info):
            RemoteSurfaceView(controller: controller, info: info)
        case .failed(let failure):
            FailureView(controller: controller, failure: failure)
        }
    }

    private var title: String {
        let name = controller.activeRequest?.displayName ?? ""
        switch controller.phase {
        case .idle: return "Gliff"
        case .connecting, .reconnecting: return "Connecting to \(name)"
        case .streaming: return name
        case .failed, .stopped: return name.isEmpty ? "Gliff" : name
        }
    }
}

struct SessionToolbar: ToolbarContent {
    @ObservedObject var controller: SessionController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if controller.isStreaming {
                Button {
                    if controller.isCapturingInput { controller.releaseInput() } else { controller.captureInput() }
                } label: {
                    Label(
                        controller.isCapturingInput ? "Release Input" : "Capture Input",
                        systemImage: controller.isCapturingInput ? "keyboard.fill" : "keyboard")
                }
                .help(controller.isCapturingInput
                    ? "Give the keyboard and pointer back to this Mac (\(Preferences.releaseShortcutDescription))"
                    : "Send the keyboard and pointer to the remote desktop")
            }
            if controller.canReconnect {
                Button {
                    controller.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .help("Start a new session with the same settings")
            }
            if controller.canDisconnect {
                Button {
                    controller.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .help("End the session")
            }
        }
    }
}

/// Progress while SSH connects and the server starts.
struct ConnectingView: View {
    @ObservedObject var controller: SessionController
    let step: SessionController.ConnectionStep

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(headline)
                .font(.title3)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if step == .waiting, controller.reconnection?.awaitingWake == false {
                    Button("Try Now") { controller.retryNow() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) { controller.disconnect() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        let name = controller.activeRequest?.displayName ?? ""
        if case .reconnecting = controller.phase { return "Reconnecting to \(name)…" }
        return "Connecting to \(name)…"
    }

    private var detail: String {
        let step = switch step {
        case .starting: "Opening SSH with your keys and agent, then starting gliff-server."
        case .awaitingVideo: "The server answered. Waiting for its video stream."
        case .waiting where controller.reconnection?.awaitingWake == true: "Waiting for the Mac to wake."
        case .waiting: "Waiting before the next attempt."
        }
        guard let reconnection = controller.reconnection else { return step }
        return "\(reconnection.reason)\nAttempt \(reconnection.attempt) of \(reconnection.limit). \(step)"
    }
}

/// An error with the actions that can recover from it.
struct FailureView: View {
    @ObservedObject var controller: SessionController
    let failure: SessionFailure

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: failure.isFatal ? "exclamationmark.octagon" : "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(failure.isFatal ? .red : .orange)
                .accessibilityHidden(true)
            Text(failure.title)
                .font(.title2)
            Text(failure.message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            HStack {
                ForEach(failure.recoveries, id: \.self) { recovery in
                    switch recovery {
                    case .retry:
                        Button("Try Again") { controller.reconnect() }
                            .keyboardShortcut(.defaultAction)
                    case .editConnection:
                        Button("Edit Connection") { controller.editConnection() }
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Calls `onClose` when the hosting window closes, backing up `onDisappear`
/// with AppKit's own notification.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: (@MainActor () -> Void)?
        // Written on the main actor only; read in deinit once no one else can.
        nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
