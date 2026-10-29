import GliffCore
import SwiftUI

@main
struct GliffMacApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Gliff")
                    .font(.largeTitle)
                Text("Your remote desktop, on your Mac.")
                    .foregroundStyle(.secondary)
                Text(Self.coreVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }

    /// Read from the linked Rust core, proving the bridge is in the app.
    private static let coreVersion: String = {
        let info = buildInfo()
        return "core \(info.appVersion) · protocol \(info.protocolVersion) · upstream "
            + info.upstreamRevision.prefix(12)
    }()
}
