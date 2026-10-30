import Foundation

/// Connection metadata the user reached successfully, most recent first.
///
/// Only the fields of `ConnectionRequest` are stored: destinations, an
/// identity file path and server options, never a credential. Entries can be
/// forgotten one by one or all at once, and turning remembering off forgets
/// everything.
@MainActor
final class RecentConnections: ObservableObject {
    static let limit = 10
    static let entriesKey = "recentConnections"
    static let rememberKey = "rememberRecentConnections"

    @Published private(set) var entries: [ConnectionRequest]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.entriesKey)
            .flatMap { try? JSONDecoder().decode([ConnectionRequest].self, from: $0) } ?? []
    }

    /// Whether successful connections are remembered; `false` forgets them all.
    var isRemembering: Bool {
        get { defaults.object(forKey: Self.rememberKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.rememberKey)
            if !newValue { forgetAll() }
        }
    }

    /// Moves `request` to the front, once it has actually connected.
    func remember(_ request: ConnectionRequest) {
        guard isRemembering else { return }
        let request = request.normalized
        entries.removeAll { $0 == request }
        entries.insert(request, at: 0)
        entries = Array(entries.prefix(Self.limit))
        save()
    }

    func forget(_ request: ConnectionRequest) {
        entries.removeAll { $0 == request }
        save()
    }

    func forgetAll() {
        entries = []
        defaults.removeObject(forKey: Self.entriesKey)
    }

    private func save() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.entriesKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }
}
