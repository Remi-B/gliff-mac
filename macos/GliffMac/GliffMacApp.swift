import AppKit
import GliffCore
import SwiftUI
import os

@main
struct GliffMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup("Gliff") {
            SessionWindow(services: appDelegate.services)
        }
        .commands { SessionCommands() }

        Settings {
            SettingsView(recents: appDelegate.services.recents)
        }
    }

    /// Read from the linked Rust core, proving the bridge is in the app.
    static let coreVersion: String = {
        let info = buildInfo()
        return "core \(info.appVersion) · protocol \(info.protocolVersion) · upstream "
            + info.upstreamRevision.prefix(12)
    }()
}

/// Shared by every window: one registry owns all sessions until they end.
@MainActor
final class AppServices {
    let registry = SessionRegistry()
    let recents = RecentConnections()
    let factory: any SessionFactory = LiveSessionFactory()
    let systemEvents = SystemEvents()

    func makeController() -> SessionController {
        let controller = SessionController(factory: factory, registry: registry, recents: recents)
        systemEvents.register(controller)
        return controller
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    /// Quitting cancels every session and waits for the bridge to reap SSH
    /// before the process exits; the bridge bounds its own teardown, and the
    /// deadline here only guards against a hang.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = services.registry.activeCount
        guard active > 0 else { return .terminateNow }
        let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "lifecycle")
        log.info("quit: cancelling \(active) session(s)")
        Task { @MainActor in
            let drained = await services.registry.cancelAllAndWait(timeout: .seconds(5))
            log.info("quit: sessions ended \(drained ? "cleanly" : "after the deadline", privacy: .public)")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
