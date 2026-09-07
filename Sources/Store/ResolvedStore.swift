import Foundation
import Observation

/// Items the user marked resolved with ⇥ — triage state, kept OUTSIDE the
/// sources themselves (a Sentry issue stays unresolved server-side; a PR stays
/// open). The contract: a freshly resolved row stays visible but dimmed for
/// the rest of the panel session (so ⇥ again can undo it), and disappears on
/// the NEXT panel open. Persisted beside settings.json, so it survives
/// relaunches.
@MainActor
@Observable
final class ResolvedStore {
    static let shared = ResolvedStore()

    /// id ("prod:…", "pr:…", "todo:…", "vit:…") → when it was resolved.
    private(set) var resolved: [String: Date] = [:]

    private static let fileURL = Preferences.directory.appending(path: "resolved.json")
    /// Entries older than this are pruned on load — a 30-day-old triage mark
    /// for an issue that long since disappeared is just file growth.
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    private init() {
        load()
    }

    func isResolved(_ id: String) -> Bool { resolved[id] != nil }

    /// ⇥ on a row: resolved ↔ unresolved.
    func toggle(_ id: String) {
        if resolved[id] != nil {
            resolved[id] = nil
        } else {
            resolved[id] = Date()
        }
        save()
    }

    /// The ids to HIDE for a panel session — everything resolved before the
    /// panel opened. Taken as a snapshot at onAppear so a mid-session resolve
    /// dims instead of vanishing.
    func snapshot() -> Set<String> { Set(resolved.keys) }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        resolved = stored.filter { $0.value >= cutoff }
        if resolved.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(resolved) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
