import Foundation

/// The apps shelf (downloads.example.invalid, `exampleapp-apps` releases.go) — Prod's
/// Releases section (copilot shell D9: Shipping lives inside Prod). One
/// public, tokenless index read, `GET /api/releases`: every app with its
/// latest release, newest first. The index carries every release with its
/// notes (~350 KB); the panel keeps the latest of each and reads it on
/// entering Prod at most every `ShelfRelease.staleAfter`, never on a poll.
actor AppsShelfClient {
    static let shared = AppsShelfClient()
    /// settings.json `shelfURL` over the profile's (example: downloads.example.invalid;
    /// `RuntimeConfig`); nil = no shelf, and nothing is read.
    static var origin: URL? {
        RuntimeConfig.current.shelf
    }

    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 10)
    }

    /// `origin`: the shelf the caller keyed its cache on, so a settings
    /// reload mid-flight never files one shelf's releases under another.
    func releases(from origin: URL) async throws -> [ShelfRelease] {
        let (data, response) = try await session.data(from: origin.appending(path: "api/releases"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status) }
        return try ShelfRelease.decodeIndex(data, origin: origin)
    }
}

/// One shipped version on the shelf: an app's latest release, its platform
/// builds of the same version and commit folded into one row ("Vitrinka
/// CLI 5.21.0 · 6 platforms").
struct ShelfRelease: Codable, Equatable, Identifiable, Sendable {
    struct Build: Codable, Equatable, Sendable {
        let appID: String
        let platform: String
        let url: URL
        let size: Int64
    }

    /// What the builds were folded by — name, version and commit (else the
    /// app) — so two rows of one version never share an id.
    let key: String
    /// The app's name without its platform suffix.
    let name: String
    let version: String
    let channel: String
    let publishedAt: Date
    /// The build's git commit, when the publisher recorded one.
    let commit: String?
    let notes: String
    let builds: [Build]
    /// How many releases the shelf holds for the first build's app.
    let history: Int

    var id: String { key }
    /// The shelf's deep-linkable detail sheet (`/app/:id`).
    /// A row exists only once a shelf answered; example's names the page
    /// should the shelf be switched off while it is drawn.
    var pageURL: URL {
        (AppsShelfClient.origin ?? URL(string: PultikProfile.example.shelfURL)!).appending(path: "app/\(builds[0].appID)")
    }

    static let staleAfter: TimeInterval = 600

    /// `name (darwin arm64)` → `name`: platform builds of one version share
    /// a row only when their version and commit match too.
    static func baseName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return name }
        return String(name[..<open.lowerBound])
    }

    static func decodeIndex(_ data: Data, origin: URL) throws -> [ShelfRelease] {
        let apps = try JSONDecoder().decode(Index.self, from: data).apps
        var order: [String] = []
        var groups: [String: ShelfRelease] = [:]
        for app in apps {
            guard let latest = app.latest, let url = URL(string: latest.url, relativeTo: origin)?.absoluteURL else { continue }
            let name = baseName(app.name)
            let key = "\(name)|\(latest.version)|\(latest.commit ?? app.id)"
            let build = Build(appID: app.id, platform: app.platform, url: url, size: latest.size)
            if let existing = groups[key] {
                groups[key] = ShelfRelease(key: key, name: name, version: existing.version, channel: existing.channel,
                                           publishedAt: max(existing.publishedAt, latest.date), commit: existing.commit,
                                           notes: existing.notes, builds: existing.builds + [build],
                                           history: existing.history)
            } else {
                order.append(key)
                groups[key] = ShelfRelease(key: key, name: name, version: latest.version, channel: latest.channel,
                                           publishedAt: latest.date, commit: latest.commit, notes: latest.notes,
                                           builds: [build], history: app.releases?.count ?? 1)
            }
        }
        return order.compactMap { groups[$0] }.sorted { $0.publishedAt > $1.publishedAt }
    }

    private struct Index: Decodable {
        let apps: [App]
    }

    private struct App: Decodable {
        let id: String
        let name: String
        let platform: String
        let latest: Entry?
        /// Only counted: the history's notes are most of the payload.
        let releases: [Counted]?
    }

    private struct Counted: Decodable {}

    /// `ts` is Unix seconds; `url` is root-relative.
    private struct Entry: Decodable {
        let version: String
        let channel: String
        let ts: Int64
        let commit: String?
        let notes: String
        let size: Int64
        let url: String

        var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    }
}
