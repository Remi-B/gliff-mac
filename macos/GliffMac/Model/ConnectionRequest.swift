import Foundation
import GliffCore

/// What the connection form edits: SSH destination and server options only.
///
/// Authentication is the user's OpenSSH configuration, agent and keys. There is
/// deliberately no password or private-key text field, and nothing here is a
/// credential: an identity file is a path, never key material.
struct ConnectionRequest: Codable, Equatable, Hashable, Sendable {
    /// A hostname, address or `~/.ssh/config` alias.
    var host = ""
    /// Empty uses the SSH configuration's user.
    var user = ""
    /// Empty uses the SSH configuration's port.
    var port = ""
    /// An absolute path to a private key file, or empty for config/agent keys.
    var identityFile = ""
    /// The remote executable; empty runs `gliff-server` from the remote PATH.
    var serverPath = ""
    /// Ask the server for a virtual display instead of mirroring an output.
    var headless = true
    /// Server-side encoder. Auto omits `--video` (the server decides); CPU and GPU pass it.
    var videoMode: ServerVideoMode = .auto

    enum Field: String, CaseIterable, Sendable {
        case host, user, port, identityFile, serverPath
    }

    /// One message per invalid field, mirroring the bridge's own validation so
    /// the form can say which field is wrong before anything starts.
    func validationErrors() -> [Field: String] {
        var errors: [Field: String] = [:]
        let host = trimmed(self.host)
        if host.isEmpty {
            errors[.host] = "Enter a host name, address or SSH config alias."
        } else if host.hasPrefix("-") {
            errors[.host] = "A host cannot start with “-”."
        } else if !host.unicodeScalars.allSatisfy(Self.hostCharacters.contains) {
            errors[.host] = "Use only letters, digits and . - _ : [ ] %."
        }
        let user = trimmed(self.user)
        if !user.isEmpty {
            if user.hasPrefix("-") {
                errors[.user] = "A user name cannot start with “-”."
            } else if !user.unicodeScalars.allSatisfy(Self.userCharacters.contains) {
                errors[.user] = "Use only ASCII letters, digits, “.”, “_” or “-”."
            }
        }
        let port = trimmed(self.port)
        if !port.isEmpty, UInt16(port).map({ $0 == 0 }) ?? true {
            errors[.port] = "Enter a port from 1 to 65535, or leave it empty."
        }
        let identity = trimmed(identityFile)
        if !identity.isEmpty,
            !identity.hasPrefix("/") || identity.unicodeScalars.contains(where: Self.isControl)
        {
            errors[.identityFile] = "Choose an identity file, or leave it empty to use your SSH agent and config."
        }
        let server = trimmed(serverPath)
        if !server.isEmpty {
            if server.hasPrefix("~") {
                errors[.serverPath] = "“~” is not expanded: use an absolute path or a command on the remote PATH."
            } else if server.hasPrefix("-") {
                errors[.serverPath] = "A server path cannot start with “-”."
            } else if server.unicodeScalars.contains(where: { Self.isControl($0) || $0.properties.isWhitespace }) {
                errors[.serverPath] = "A server path cannot contain spaces or control characters."
            }
        }
        return errors
    }

    /// The bridge target; call only once `validationErrors()` is empty. The
    /// bridge validates again and its typed error is reported if it disagrees.
    func target() -> ConnectionTarget {
        .ssh(
            host: trimmed(host),
            user: nonEmpty(user),
            port: nonEmpty(port).flatMap(UInt16.init),
            serverPath: nonEmpty(serverPath),
            identityFile: nonEmpty(identityFile),
            headless: headless,
            videoMode: videoMode.bridgeValue)
    }

    /// `user@host:port`, for titles and the recent hosts list.
    var displayName: String {
        var name = trimmed(host)
        if let user = nonEmpty(user) { name = "\(user)@\(name)" }
        if let port = nonEmpty(port) { name += ":\(port)" }
        return name
    }

    /// The same destination and options with surrounding spaces removed.
    var normalized: ConnectionRequest {
        ConnectionRequest(
            host: trimmed(host), user: trimmed(user), port: trimmed(port),
            identityFile: trimmed(identityFile), serverPath: trimmed(serverPath), headless: headless,
            videoMode: videoMode)
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case host, user, port, identityFile, serverPath, headless, videoMode
    }

    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%")
    private static let userCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}

/// Older saved entries have no `videoMode`; they decode as Auto, the previous
/// behaviour. Declared in an extension to keep the memberwise initializer.
extension ConnectionRequest {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decode(String.self, forKey: .host)
        user = try values.decode(String.self, forKey: .user)
        port = try values.decode(String.self, forKey: .port)
        identityFile = try values.decode(String.self, forKey: .identityFile)
        serverPath = try values.decode(String.self, forKey: .serverPath)
        headless = try values.decode(Bool.self, forKey: .headless)
        videoMode = try values.decodeIfPresent(ServerVideoMode.self, forKey: .videoMode) ?? .auto
    }
}

enum ServerVideoMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, cpu, gpu
    var id: Self { self }
    var bridgeValue: GliffCore.VideoMode {
        switch self {
        case .auto: .auto
        case .cpu: .cpu
        case .gpu: .gpu
        }
    }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .cpu: "CPU"
        case .gpu: "GPU"
        }
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func nonEmpty(_ value: String) -> String? {
    let value = trimmed(value)
    return value.isEmpty ? nil : value
}
