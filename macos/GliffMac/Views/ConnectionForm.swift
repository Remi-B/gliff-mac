import AppKit
import SwiftUI

/// The connection form, recent hosts and the result of the last session.
struct ConnectionForm: View {
    @ObservedObject var controller: SessionController
    @EnvironmentObject private var recents: RecentConnections
    @FocusState private var focus: ConnectionRequest.Field?

    var body: some View {
        HStack(spacing: 0) {
            Form {
                if case .stopped(let reason) = controller.phase {
                    Section { stoppedBanner(reason) }
                }
                Section {
                    field(.host, "Host", text: $controller.request.host, prompt: "host, address or SSH alias")
                    field(.user, "User", text: $controller.request.user, prompt: "from SSH config")
                    field(.port, "Port", text: $controller.request.port, prompt: "from SSH config")
                    identityRow
                } header: {
                    Text("SSH destination")
                } footer: {
                    Text("""
                        Gliff runs your system OpenSSH with your config, agent and keys. It never asks \
                        for or stores a password. Connect once with ssh in Terminal to verify the host key.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Server") {
                    field(.serverPath, "Server", text: $controller.request.serverPath, prompt: "gliff-server")
                    Toggle("Use a virtual display", isOn: $controller.request.headless)
                        .help("Off mirrors the server's current output instead")
                    Picker("Video encoder", selection: $controller.request.videoMode) {
                        ForEach(ServerVideoMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .help("Auto lets the server choose. CPU selects CPU encoding; GPU prefers GPU and may fall back to CPU.")
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Connect") { controller.connect() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!controller.canConnect)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
            .onAppear { focus = .host }

            if !recents.entries.isEmpty {
                Divider()
                RecentConnectionsList(controller: controller)
                    .frame(width: 220)
            }
        }
    }

    private func field(
        _ field: ConnectionRequest.Field, _ label: String, text: Binding<String>, prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: text, prompt: Text(prompt))
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .onSubmit { controller.connect() }
            if let error = controller.fieldErrors[field] {
                errorText(error)
            }
        }
    }

    private var identityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Identity file") {
                HStack {
                    Text(controller.request.identityFile.isEmpty
                        ? "From SSH config or agent" : controller.request.identityFile)
                        .foregroundStyle(controller.request.identityFile.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…", action: chooseIdentity)
                    if !controller.request.identityFile.isEmpty {
                        Button("Clear") { controller.request.identityFile = "" }
                            .accessibilityLabel("Clear identity file")
                    }
                }
            }
            if let error = controller.fieldErrors[.identityFile] {
                errorText(error)
            }
        }
    }

    private func errorText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(text)")
    }

    @ViewBuilder private func stoppedBanner(_ reason: SessionController.StopReason) -> some View {
        HStack {
            Label(
                reason == .serverClosed ? "The server ended the session." : "Disconnected.",
                systemImage: reason == .serverClosed ? "info.circle" : "checkmark.circle")
            Spacer()
            if controller.canReconnect {
                Button("Reconnect") { controller.reconnect() }
            }
        }
    }

    /// Lets the user pick a private key; only its path is kept.
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH identity file"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            controller.request.identityFile = url.path(percentEncoded: false)
        }
    }
}

/// Destinations that connected before; selecting one fills the form.
struct RecentConnectionsList: View {
    @ObservedObject var controller: SessionController
    @EnvironmentObject private var recents: RecentConnections

    var body: some View {
        List {
            Section("Recent") {
                ForEach(recents.entries, id: \.self) { entry in
                    Button {
                        controller.use(entry)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.displayName)
                            if !entry.identityFile.isEmpty {
                                Text((entry.identityFile as NSString).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Fills the connection form")
                    .contextMenu {
                        Button("Forget \(entry.displayName)") { recents.forget(entry) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button("Clear Recent Hosts") { recents.forgetAll() }
                .buttonStyle(.link)
                .padding(8)
        }
    }
}
