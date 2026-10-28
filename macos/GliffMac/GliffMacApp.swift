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
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
