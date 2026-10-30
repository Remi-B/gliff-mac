import GliffCore

/// A session error as the interface presents it.
struct SessionFailure: Equatable, Sendable {
    enum Recovery: Equatable, Sendable {
        /// Start a new session with the same settings.
        case retry
        /// Return to the connection form.
        case editConnection
    }

    let title: String
    let message: String
    /// The server or protocol cannot work with this client: retrying the
    /// same settings would fail the same way.
    let isFatal: Bool

    var recoveries: [Recovery] { isFatal ? [.editConnection] : [.retry, .editConnection] }

    init(title: String, message: String, isFatal: Bool = false) {
        self.title = title
        self.message = message
        self.isFatal = isFatal
    }

    /// Maps the bridge's typed errors. Transport messages are already fixed,
    /// redacted setup guidance (no raw SSH output or key material). Messages
    /// are written here: the generated `localizedDescription` is a Swift
    /// reflection of the enum case, not user-facing text.
    init(_ error: GliffError) {
        switch error {
        case .InvalidOptions(let message):
            self.init(title: "Check the connection settings", message: Self.sentence(message), isFatal: true)
        case .Transport(let message):
            self.init(title: "Could not connect", message: Self.sentence(message))
        case .VersionMismatch(let client, let server, let reason):
            self.init(
                title: "Incompatible server",
                message: Self.sentence(reason)
                    + " The server speaks protocol \(server); this app speaks protocol \(client)."
                    + Self.installHint,
                isFatal: true)
        case .Incompatible(let code, let message):
            self.init(
                title: "Incompatible server",
                message: Self.sentence(message) + " (Server code \(code).)" + Self.installHint,
                isFatal: true)
        case .Contract(let message):
            self.init(
                title: "Incompatible server",
                message: Self.sentence(message) + Self.installHint,
                isFatal: true)
        case .Unsupported(let message):
            self.init(title: "Not supported", message: Self.sentence(message), isFatal: true)
        case .Protocol(let message):
            self.init(title: "The session failed", message: Self.sentence(message))
        case .AlreadyStarted:
            self.init(title: "The session failed", message: "The session was already started.")
        case .NotRunning:
            self.init(title: "The session failed", message: "The session is not running.")
        case .Busy:
            self.init(title: "The session failed", message: "The session is too busy to accept more input.")
        case .UnknownFrame(let frameId):
            self.init(title: "The session failed", message: "Frame \(frameId) was not awaiting a decode report.")
        }
    }

    private static let installHint = " Install a gliff-server version this app supports."

    /// Any other error thrown while starting a session.
    init(starting error: any Error) {
        if let error = error as? GliffError {
            self.init(error)
        } else {
            self.init(title: "Could not start the session", message: Self.sentence(error.localizedDescription))
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let text = first.uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }
}
