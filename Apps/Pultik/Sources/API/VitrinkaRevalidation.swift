import Foundation

/// Conditional reads for vitrinka's two polled me doors (vt-9725).
///
/// `/api/v1/me/work` and `/api/v1/me/ripe` answer a weak ETag and a 304 with
/// no body while the workspace has not moved (vitrinka#1427). The polling
/// session keeps no HTTP cache (`PollingSession`), so this remembers the
/// validator and body of each 200, keyed by workspace and path with its
/// query, and turns a 304 back into that body. Pure: the client captures the
/// entry it sent before the network await and hands it back here, so an
/// identity change or eviction during the await never mixes answers.
struct VitrinkaValidatorCache {
    struct Entry: Equatable {
        let etag: String
        let body: Data
    }

    /// What a response means for the caller.
    enum Outcome: Equatable {
        /// The answer's body: a 2xx's own, or a 304's remembered one.
        case body(Data)
        /// A 304 for a request that sent no validator: never a failure, read
        /// again unconditionally.
        case refetch
        /// Any other status, for the caller to classify.
        case status(Int)
    }

    static let revalidatedPaths: Set<String> = ["/api/v1/me/work", "/api/v1/me/ripe"]
    /// Workspaces × doors × query shapes stay far below this; a key set that
    /// grows past it (workspaces come and go) starts over rather than grows.
    static let entryLimit = 64

    private(set) var identity: String?
    private var entries: [String: Entry] = [:]

    var count: Int { entries.count }

    /// The cache key of a revalidated read, nil for every other path.
    static func key(path: String, workspace: String?) -> String? {
        guard let components = URLComponents(string: path),
              revalidatedPaths.contains(components.path) else { return nil }
        return (workspace ?? "") + "\u{0}" + path
    }

    /// Forget every answer when the credential or workspace identity moves:
    /// one person's body never answers another's 304.
    mutating func bind(identity: String?) {
        guard identity != self.identity else { return }
        entries.removeAll()
        self.identity = identity
    }

    func entry(for key: String) -> Entry? { entries[key] }

    /// Settles a response. `sent` is the entry whose ETag went out as
    /// If-None-Match, `identity` the one bound when the request left.
    mutating func resolve(
        key: String, sent: Entry?, identity: String?, status: Int, etag: String?, body: Data
    ) -> Outcome {
        let current = identity == self.identity
        switch status {
        case 304:
            guard let sent else { return .refetch }
            if current { remember(key, sent) }
            return .body(sent.body)
        case 200..<300:
            if current {
                if let etag, !etag.isEmpty { remember(key, Entry(etag: etag, body: body)) }
                else { entries[key] = nil }
            }
            return .body(body)
        default:
            return .status(status)
        }
    }

    private mutating func remember(_ key: String, _ entry: Entry) {
        if entries[key] == nil, entries.count >= Self.entryLimit { entries.removeAll() }
        entries[key] = entry
    }
}

/// Which shape of `/me/work` a workspace is read in (vt-9725). The compact
/// rows are a fraction of the full ones, but only a server whose compact
/// rows carry `project` and `url` can feed the rail. A workspace whose
/// compact answer does not decode is read in full from then on, for the
/// process lifetime: an older or self-hosted server never blanks the rail.
struct VitrinkaWorkReadMode {
    static let compactPath = "/api/v1/me/work?compact=1"
    static let fullPath = "/api/v1/me/work"

    private(set) var fullReads: Set<String> = []

    func path(for workspace: String) -> String {
        fullReads.contains(workspace) ? Self.fullPath : Self.compactPath
    }

    /// Decodes a `/me/work` answer read through `path`. A compact answer
    /// that does not decode moves the workspace to full reads and asks for
    /// one (`.fullRead`); a full answer that does not decode is the error.
    mutating func decode(_ data: Data, readThrough path: String, workspace: String) -> Decoded {
        do { return .work(try JSONDecoder().decode(VitrinkaMyWork.self, from: data)) }
        catch {
            guard path == Self.compactPath else { return .unreadable(error) }
            fullReads.insert(workspace)
            return .fullRead
        }
    }

    enum Decoded {
        case work(VitrinkaMyWork)
        case fullRead
        case unreadable(Error)
    }
}
