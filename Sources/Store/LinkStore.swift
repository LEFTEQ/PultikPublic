import Foundation
import Observation

/// A bookmarked link, plus the full record of when it was opened.
///
/// The whole sequence is kept, not a counter: a counter can only ever answer
/// "how often, forever", which drifts further from "what am I using now" the
/// longer it runs. Keeping timestamps lets the ordering ask a question with a
/// window on it, and lets that window change later without losing history.
struct SavedLink: Codable, Identifiable {
    var id: String
    var url: String
    var title: String
    var createdAt: Date
    var opens: [Date] = []

    /// What the list sorts by: opens inside the trailing week.
    func recentOpens(since: Date) -> Int {
        opens.reduce(into: 0) { count, date in if date >= since { count += 1 } }
    }

    var totalOpens: Int { opens.count }
}

/// Bookmarks, stored beside settings.json in Application Support.
///
/// A separate file on purpose: this one is written on every click, and settings
/// is written by the Settings window — sharing a file would mean each could
/// clobber the other's in-memory copy on save.
@MainActor
@Observable
final class LinkStore {
    static let shared = LinkStore()

    private(set) var links: [SavedLink] = []

    static let fileURL = Preferences.directory.appending(path: "links.json")

    /// The ordering window. Weekly by request: long enough to survive a quiet
    /// day, short enough that last month's project stops outranking today's.
    private static let window: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        load()
    }

    /// Most-used this week first; ties and never-opened links fall back to
    /// lifetime opens, then to newest, so a fresh link is visible immediately
    /// instead of sinking below everything with a week of history.
    var ordered: [SavedLink] {
        let since = Date().addingTimeInterval(-Self.window)
        return links.sorted { lhs, rhs in
            let (l, r) = (lhs.recentOpens(since: since), rhs.recentOpens(since: since))
            if l != r { return l > r }
            if lhs.totalOpens != rhs.totalOpens { return lhs.totalOpens > rhs.totalOpens }
            return lhs.createdAt > rhs.createdAt
        }
    }

    @discardableResult
    func add(url rawURL: String, title rawTitle: String?) -> Result<SavedLink, LinkError> {
        guard let normalized = Self.normalize(rawURL) else { return .failure(.badURL) }
        if let existing = links.first(where: { $0.url == normalized }) {
            return .failure(.duplicate(existing.title))
        }
        let link = SavedLink(
            id: UUID().uuidString,
            url: normalized,
            title: Self.cleanTitle(rawTitle) ?? Self.titleFromURL(normalized),
            createdAt: Date()
        )
        links.append(link)
        save()
        return .success(link)
    }

    func remove(id: String) {
        links.removeAll { $0.id == id }
        save()
    }

    /// Fuzzy delete for `/rm-link <text>` — matches title or URL.
    func remove(matching text: String) -> SavedLink? {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty,
              let hit = links.first(where: {
                  $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
              })
        else { return nil }
        remove(id: hit.id)
        return hit
    }

    func recordOpen(id: String) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].opens.append(Date())
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            links = try decoder.decode([SavedLink].self, from: data)
        } catch {
            // Don't overwrite a file we failed to read — keep it for inspection
            // and start empty rather than silently destroying the bookmarks.
            NSLog("pultik: links.json unreadable (%@) — leaving it in place",
                  error.localizedDescription)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: Preferences.directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(links).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("pultik: could not save links.json — %@", error.localizedDescription)
        }
    }

    // MARK: - URL handling

    /// Accepts what a person actually pastes: "boards.example.invalid", "http://x.dev",
    /// "https://…". Anything without a dot (or a scheme) is rejected — that is
    /// a typo'd command, not a host.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            guard text.contains("."), !text.hasPrefix(".") else { return nil }
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host(), host.contains(".") else {
            return nil
        }
        return text
    }

    private static func cleanTitle(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "https://grafana.ops.example.invalid/d/abc" → "grafana.ops.example.invalid"
    private static func titleFromURL(_ url: String) -> String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum LinkError: Error {
    case badURL
    case duplicate(String)

    var message: String {
        switch self {
        case .badURL: "not a link — try /add-link grafana.ops.example.invalid"
        case .duplicate(let title): "already saved as “\(title)”"
        }
    }
}
