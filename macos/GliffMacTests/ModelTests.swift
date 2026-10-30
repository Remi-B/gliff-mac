import Foundation
import GliffCore
import Testing
@testable import GliffMac

@Suite struct ConnectionRequestTests {
    @Test func emptyOptionalFieldsUseTheSSHConfiguration() {
        let request = ConnectionRequest(host: " desk ", user: " ", port: "", identityFile: "", serverPath: "")
        #expect(request.validationErrors().isEmpty)
        #expect(request.target() == .ssh(host: "desk", user: nil, port: nil, serverPath: nil,
                                         identityFile: nil, headless: true, videoMode: .auto))
        #expect(request.displayName == "desk")
    }

    @Test func everyFieldIsPassedStructured() {
        let request = ConnectionRequest(host: "10.0.0.2", user: "remi", port: "2222",
                                        identityFile: "/Users/remi/.ssh/id_ed25519",
                                        serverPath: "/opt/gliff/bin/gliff-server", headless: false,
                                        videoMode: .gpu)
        #expect(request.validationErrors().isEmpty)
        #expect(request.target() == .ssh(host: "10.0.0.2", user: "remi", port: 2222,
                                         serverPath: "/opt/gliff/bin/gliff-server",
                                         identityFile: "/Users/remi/.ssh/id_ed25519", headless: false,
                                         videoMode: .gpu))
        #expect(request.displayName == "remi@10.0.0.2:2222")
    }

    @Test(arguments: ServerVideoMode.allCases)
    func selectedEncoderModeReachesBridge(mode: ServerVideoMode) {
        let target = ConnectionRequest(host: "desk", videoMode: mode).target()
        guard case let .ssh(_, _, _, _, _, _, videoMode) = target else {
            Issue.record("connection request did not produce an SSH target")
            return
        }
        #expect(videoMode == mode.bridgeValue)
    }

    @Test(arguments: [
        (ConnectionRequest(host: ""), ConnectionRequest.Field.host),
        (ConnectionRequest(host: "-oProxyCommand=touch"), .host),
        (ConnectionRequest(host: "host name"), .host),
        (ConnectionRequest(host: "désk"), .host),
        (ConnectionRequest(host: "desk", user: "-l"), .user),
        (ConnectionRequest(host: "desk", user: "rémi"), .user),
        (ConnectionRequest(host: "desk", port: "0"), .port),
        (ConnectionRequest(host: "desk", port: "65536"), .port),
        (ConnectionRequest(host: "desk", port: "22a"), .port),
        (ConnectionRequest(host: "desk", identityFile: "~/.ssh/id"), .identityFile),
        (ConnectionRequest(host: "desk", serverPath: "~/bin/gliff-server"), .serverPath),
        (ConnectionRequest(host: "desk", serverPath: "gliff-server --stdio"), .serverPath),
        (ConnectionRequest(host: "desk", serverPath: "-x"), .serverPath),
    ])
    func invalidFieldsAreNamed(request: ConnectionRequest, field: ConnectionRequest.Field) {
        #expect(Array(request.validationErrors().keys) == [field])
    }

    /// The form's validation never accepts what the bridge would refuse.
    @Test(arguments: [
        "desk", "desk.local", "[fe80::1%en0]", "my_alias-2", "-x", "a b", "", "é",
    ])
    func formValidationMatchesTheBridge(host: String) {
        let request = ConnectionRequest(host: host)
        let bridgeAccepts = (try? GliffSession(target: .ssh(host: host, user: nil, port: nil, serverPath: nil,
                                                            identityFile: nil, headless: true, videoMode: .auto),
                                               options: SessionOptions(chroma: [.single420]))) != nil
        #expect(request.validationErrors().isEmpty == bridgeAccepts)
    }
}

@MainActor
@Suite struct RecentConnectionsTests {
    let defaults = TestDefaults()

    @Test func persistsMostRecentFirstWithoutDuplicates() {
        let recents = RecentConnections(defaults: defaults.store)
        recents.remember(ConnectionRequest(host: "a"))
        recents.remember(ConnectionRequest(host: "b", identityFile: "/k"))
        recents.remember(ConnectionRequest(host: " a "))
        #expect(recents.entries.map(\.host) == ["a", "b"])

        let reloaded = RecentConnections(defaults: defaults.store)
        #expect(reloaded.entries == recents.entries)
    }

    @Test func keepsAtMostTheLimit() {
        let recents = RecentConnections(defaults: defaults.store)
        for index in 0..<(RecentConnections.limit + 5) {
            recents.remember(ConnectionRequest(host: "host\(index)"))
        }
        #expect(recents.entries.count == RecentConnections.limit)
        #expect(recents.entries.first?.host == "host\(RecentConnections.limit + 4)")
    }

    @Test func forgettingRemovesStoredData() {
        let recents = RecentConnections(defaults: defaults.store)
        recents.remember(ConnectionRequest(host: "a"))
        recents.remember(ConnectionRequest(host: "b"))
        recents.forget(ConnectionRequest(host: "a"))
        #expect(RecentConnections(defaults: defaults.store).entries.map(\.host) == ["b"])
        recents.forgetAll()
        #expect(defaults.store.object(forKey: RecentConnections.entriesKey) == nil)
        #expect(RecentConnections(defaults: defaults.store).entries.isEmpty)
    }

    @Test func turningRememberingOffForgetsAndStops() {
        let recents = RecentConnections(defaults: defaults.store)
        recents.remember(ConnectionRequest(host: "a"))
        recents.isRemembering = false
        #expect(recents.entries.isEmpty)
        recents.remember(ConnectionRequest(host: "b"))
        #expect(recents.entries.isEmpty)
        #expect(defaults.store.object(forKey: RecentConnections.entriesKey) == nil)
        #expect(!RecentConnections(defaults: defaults.store).isRemembering)
    }

    /// Only the request's own fields are encoded: no credential can be stored.
    @Test func storesOnlyConnectionMetadata() throws {
        let recents = RecentConnections(defaults: defaults.store)
        recents.remember(ConnectionRequest(host: "a", user: "u", port: "22", identityFile: "/k", serverPath: "s"))
        let data = try #require(defaults.store.data(forKey: RecentConnections.entriesKey))
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(Set(stored[0].keys) == ["host", "user", "port", "identityFile", "serverPath", "headless", "videoMode"])
    }

    @Test func oldRecentEntriesDefaultToAutoAndModePersists() throws {
        let old = #"[{"host":"desk","user":"","port":"","identityFile":"","serverPath":"","headless":true}]"#
        defaults.store.set(Data(old.utf8), forKey: RecentConnections.entriesKey)
        let recents = RecentConnections(defaults: defaults.store)
        #expect(recents.entries.first?.videoMode == .auto)
        recents.remember(ConnectionRequest(host: "gpu", videoMode: .gpu))
        #expect(RecentConnections(defaults: defaults.store).entries.first?.videoMode == .gpu)
    }
}

@MainActor
@Suite struct SessionRegistryTests {
    @Test func quitWaitsForEverySessionToEnd() async {
        let registry = SessionRegistry()
        let sessions = [FakeSession(), FakeSession()]
        for session in sessions { _ = try? registry.start(session) { _, _ in } }
        #expect(registry.activeCount == 2)

        Task { @MainActor in
            // Teardown completes later, as the bridge reaps SSH.
            try? await Task.sleep(for: .milliseconds(50))
            sessions.forEach { $0.emit(.ended(.cancelled)) }
        }
        #expect(await registry.cancelAllAndWait(timeout: .seconds(5)))
        #expect(sessions.allSatisfy { $0.cancelCount == 1 })
        #expect(registry.activeCount == 0)
    }

    @Test func quitGivesUpAfterTheDeadline() async {
        let registry = SessionRegistry()
        let stuck = FakeSession()
        _ = try? registry.start(stuck) { _, _ in }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await registry.cancelAllAndWait(timeout: .milliseconds(100)) == false)
        #expect(clock.now - start < .seconds(2))
        #expect(registry.activeCount == 1)
    }

    @Test func quitWithoutSessionsReturnsAtOnce() async {
        #expect(await SessionRegistry().cancelAllAndWait(timeout: .seconds(5)))
    }
}

@Suite struct SessionFailureTests {
    @Test func typedErrorsMapToActionableFailures() {
        #expect(!SessionFailure(GliffError.Transport(message: "x")).isFatal)
        let protocolError: GliffError = .Protocol(message: "x")
        #expect(!SessionFailure(protocolError).isFatal)
        for error: GliffError in [
            .Incompatible(code: 1, message: "x"), .Contract(message: "x"),
            .VersionMismatch(client: 1, server: 2, reason: "x"),
        ] {
            #expect(SessionFailure(error).isFatal == isFatalIncompatibility(error: error))
            #expect(SessionFailure(error).title == "Incompatible server")
        }
        #expect(SessionFailure(GliffError.InvalidOptions(message: "port 0")).recoveries == [.editConnection])
    }

    /// The generated `localizedDescription` reflects the Swift enum; no
    /// message may show type names or associated-value syntax.
    @Test func messagesAreWrittenForPeople() {
        let errors: [GliffError] = [
            .InvalidOptions(message: "port 0"), .Unsupported(message: "dual"), .AlreadyStarted,
            .NotRunning, .Busy, .UnknownFrame(frameId: 7), .Transport(message: "no route"),
            .Contract(message: "bad config"), .VersionMismatch(client: 1, server: 2, reason: "server is newer"),
            .Incompatible(code: 3, message: "codec missing"), .Protocol(message: "unexpected message"),
        ]
        for error in errors {
            let failure = SessionFailure(error)
            for text in [failure.title, failure.message] {
                #expect(!text.contains("GliffError") && !text.contains("GliffCore") && !text.contains("("
                    + "message:"), "\(text)")
            }
        }
        let mismatch = SessionFailure(GliffError.VersionMismatch(client: 1, server: 2, reason: "server is newer"))
        #expect(mismatch.message.hasPrefix("Server is newer. The server speaks protocol 2; this app speaks protocol 1."))
    }
}
