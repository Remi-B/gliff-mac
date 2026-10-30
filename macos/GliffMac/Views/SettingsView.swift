import SwiftUI

/// Preference keys and the release shortcut, shared by views and commands.
enum Preferences {
    static let captureInputKey = "captureInputOnClick"
    static let captureInputDefault = true
    static let shareClipboardKey = "shareClipboard"

    /// Releases keyboard and pointer capture (task 09's default). The menu item
    /// is enabled only while capturing, so the keys reach local controls
    /// otherwise; input forwarding must consume it and never send it.
    static let releaseShortcut = KeyboardShortcut(.escape, modifiers: .shift)
    static let releaseShortcutDescription = "⇧⎋"
}

struct SettingsView: View {
    @ObservedObject var recents: RecentConnections
    @AppStorage(Preferences.captureInputKey) private var captureInput = Preferences.captureInputDefault
    @AppStorage(Preferences.shareClipboardKey) private var shareClipboard = false

    var body: some View {
        Form {
            Section {
                Toggle("Capture keyboard and pointer when clicking the remote desktop", isOn: $captureInput)
                Text("""
                    Press \(Preferences.releaseShortcutDescription) to release input at any time. \
                    Sending input to the server arrives in a later version.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Input")
            }
            Section {
                Toggle("Share the clipboard with the server", isOn: $shareClipboard)
                    .disabled(true)
                Text("Clipboard sharing is not available yet; nothing is shared.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Clipboard")
            }
            Section {
                Toggle("Remember recent hosts", isOn: Binding(
                    get: { recents.isRemembering },
                    set: { recents.isRemembering = $0 }))
                HStack {
                    Text(recents.entries.isEmpty
                        ? "No recent hosts."
                        : "\(recents.entries.count) recent host\(recents.entries.count == 1 ? "" : "s").")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget All") { recents.forgetAll() }
                        .disabled(recents.entries.isEmpty)
                }
                Text("Only destinations, identity file paths and server options are stored, never passwords or keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recent hosts")
            }
            Section {
                LabeledContent("Build", value: GliffMacApp.coreVersion)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
