import Foundation
import Observation

/// Firing critical episodes (`FiringWatch.episodeKey`) the user has already
/// seen in the panel — the icon's badge counts the rest. AlertSeenStore's
/// contract for the Firing rail: opening the panel marks what it shows as
/// seen, persisted beside settings.json so a relaunch does not re-badge them.
@MainActor
@Observable
final class FiringSeenStore {
    static let shared = FiringSeenStore()

    private(set) var seen: Set<String> = []

    private static let fileURL = Preferences.directory.appending(path: "firing-seen.json")

    private init() {
        load()
    }

    func isSeen(_ key: String) -> Bool { seen.contains(key) }

    func markSeen(_ keys: [String]) {
        guard !seen.isSuperset(of: keys) else { return }
        seen.formUnion(keys)
        save()
    }

    /// An episode that stopped firing never comes back (a re-fire is a new
    /// `activeAt`), so only the ones still firing are worth keeping. Called
    /// only with an answer from every evaluator — a silent one must not
    /// forget what was read.
    func prune(keeping keys: Set<String>) {
        let kept = seen.intersection(keys)
        guard kept.count != seen.count else { return }
        seen = kept
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            seen = try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            NSLog("pultik: firing-seen.json unreadable (%@) — starting empty", error.localizedDescription)
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(seen).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("pultik: firing-seen.json not saved: %@", error.localizedDescription)
        }
    }
}
