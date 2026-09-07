import Foundation
import Observation

/// Eve alert ids the user has already seen — read-state lives HERE, not on
/// the server (decision 2026-07-29: no ack API, ResolvedStore-style local
/// persistence). Opening the panel with the alerts section visible marks
/// everything currently shown as seen; unread is what the fetch brought in
/// since. Persisted beside settings.json, so it survives relaunches.
@MainActor
@Observable
final class AlertSeenStore {
    static let shared = AlertSeenStore()

    private(set) var seen: Set<Int> = []

    private static let fileURL = Preferences.directory.appending(path: "alerts-seen.json")

    private init() {
        load()
    }

    func isSeen(_ id: Int) -> Bool { seen.contains(id) }

    func markSeen(_ ids: [Int]) {
        guard !seen.isSuperset(of: ids) else { return }
        seen.formUnion(ids)
        save()
    }

    /// Ids are keyset-monotonic, so anything below the fetched window's floor
    /// can never come back — dropping it is pure file hygiene. Called only
    /// after a non-empty fetch: an empty (off-mesh) result must not wipe the
    /// seen-state and resurrect long-read alerts as unread.
    func prune(keepingAtOrAbove floor: Int) {
        let kept = seen.filter { $0 >= floor }
        guard kept.count != seen.count else { return }
        seen = kept
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Set<Int>.self, from: data)
        else { return }
        seen = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(seen) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
