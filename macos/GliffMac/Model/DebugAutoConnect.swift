#if DEBUG
import Foundation

/// Debug builds only: lets a live check launch the app from Finder and
/// connect without UI scripting. The request is read once from the
/// `GliffDebugAutoConnect` default (a JSON `ConnectionRequest`) and removed,
/// so it never persists; release builds do not contain this code.
@MainActor
enum DebugAutoConnect {
    static let key = "GliffDebugAutoConnect"
    private static var consumed = false

    static func apply(to controller: SessionController) {
        guard !consumed else { return }
        consumed = true
        let defaults = UserDefaults.standard
        guard let json = defaults.string(forKey: key) else { return }
        defaults.removeObject(forKey: key)
        guard let request = try? JSONDecoder().decode(ConnectionRequest.self, from: Data(json.utf8)) else {
            return
        }
        controller.request = request
        controller.connect()
    }
}
#endif
