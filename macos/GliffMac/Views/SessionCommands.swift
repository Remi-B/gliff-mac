import SwiftUI

/// The Connection menu, acting on the key window's session.
struct SessionCommands: Commands {
    @FocusedObject private var controller: SessionController?

    var body: some Commands {
        CommandMenu("Connection") {
            Button("Connect") { controller?.connect() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(controller?.canConnect != true)
            Button("Reconnect") { controller?.reconnect() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(controller?.canReconnect != true)
            Button("Disconnect") { controller?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(controller?.canDisconnect != true)
            Divider()
            Button("Capture Input") { controller?.captureInput() }
                .disabled(controller?.isStreaming != true || controller?.isCapturingInput == true)
            Button("Release Input") { controller?.releaseInput() }
                .keyboardShortcut(Preferences.releaseShortcut)
                .disabled(controller?.isCapturingInput != true)
        }
    }
}
