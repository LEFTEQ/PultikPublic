import Foundation

/// Compact search metadata, independent of checks/reviews and HTTP validators.
/// Scope keys are canonical; only complete successful queries can suppress a fetch.
struct GitHubPRIndex: Codable {
    struct Record: Codable {
        var pr: ArchivedPR
        var fetchedAt: Date
    }
    struct Query: Codable {
        var ids: [String]
        var fetchedAt: Date
    }
    struct Coverage: Codable {
        var nextPage = 2
        var headFetchedAt: Date = .distantPast
        var finished = false
        var backfillDue = false
    }
    struct Answer {
        let hits: [ArchivedPR]
        let fetchedAt: Date?
        let isFresh: Bool
    }

    private(set) var records: [String: Record] = [:]
    private var queries: [String: Query] = [:]
    private var queryOrder: [String] = []
    private var lookups: [String: Date] = [:]
    private var aliases: [String: String] = [:]
    private(set) var coverage: [String: Coverage] = [:]
    static let recordLimit = 3_000
    static let queryLimit = 64
    static let pageLimit = 10
    static let maximumBytes = 4 * 1024 * 1024

    static func number(in query: String) -> Int? {
        let text = query.hasPrefix("#") ? String(query.dropFirst()) : query
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let number = Int(text), number > 0 else { return nil }
        return number
    }

    static func key(query: String, repos: [String]) -> String {
        let scope = Set(repos.map { $0.lowercased() }).sorted().joined(separator: ",")
        let term = number(in: query).map { "#\($0)" } ?? query
        // Preserve qualifier/text case: GitHub has case-sensitive query values.
        return scope + "|" + term
    }

    func contains(repo: String, in repos: [String]) -> Bool {
        let scope = Set(repos.map { $0.lowercased() })
        return scope.contains(repo.lowercased()) || scope.contains { aliases[$0] == repo.lowercased() }
    }

    mutating func answer(query: String, repos: [String], now: Date) -> Answer {
        let key = Self.key(query: query, repos: repos)
        let cached = queries[key]
        if cached != nil {
            queryOrder.removeAll { $0 == key }
            queryOrder.append(key)
        }
        let scope = Set(repos.flatMap { [$0.lowercased(), aliases[$0.lowercased()] ?? $0.lowercased()] })
        let number = Self.number(in: query)
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // Qualifiers keep their server semantics. A cached query is safe; an
        // arbitrary qualifier is never interpreted as a plain title filter.
        let local = number != nil || !query.contains(":")
            ? records.values.filter { record in
                guard scope.contains(record.pr.repoSlug.lowercased()) else { return false }
                if let number { return record.pr.number == number }
                let text = [record.pr.title, record.pr.repoSlug, record.pr.branch ?? ""]
                    .joined(separator: " ").lowercased()
                return terms.allSatisfy { text.contains($0) }
            } : []
        var matches = Dictionary(uniqueKeysWithValues: local.map { ($0.pr.id.lowercased(), $0) })
        for id in cached?.ids ?? [] {
            if let record = records[id], scope.contains(record.pr.repoSlug.lowercased()) {
                matches[id] = record
            }
        }
        let rows = matches.values.sorted { $0.pr.updatedAt > $1.pr.updatedAt }
        let ttl: TimeInterval = cached?.ids.isEmpty == true ? 60 : 300
        let intact = cached.map { $0.ids.allSatisfy { records[$0] != nil } } ?? false
        let fresh = number.map { reposNeedingLookup(number: $0, repos: repos, now: now).isEmpty }
            ?? (intact && cached.map { now.timeIntervalSince($0.fetchedAt) < ttl } == true)
        return Answer(hits: Array(rows.prefix(number == nil ? 50 : Self.recordLimit).map(\.pr)),
                      fetchedAt: cached?.fetchedAt ?? rows.map(\.fetchedAt).min(),
                      isFresh: fresh)
    }

    func reposNeedingLookup(number: Int, repos: [String], now: Date) -> [String] {
        repos.filter { repo in
            let id = "\(repo)#\(number)".lowercased()
            let canonical = "\(aliases[repo.lowercased()] ?? repo.lowercased())#\(number)"
            guard let at = lookups[id] ?? records[canonical]?.fetchedAt else { return true }
            return now.timeIntervalSince(at) >= (records[canonical] == nil ? 60 : 300)
        }
    }

    mutating func rememberLookup(number: Int, repos: [String], hits: [ArchivedPR], now: Date) {
        ingest(hits, now: now)
        let found = Set(hits.map { $0.id.lowercased() })
        for repo in repos {
            let id = "\(repo)#\(number)".lowercased()
            lookups[id] = now
            let canonical = "\(aliases[repo.lowercased()] ?? repo.lowercased())#\(number)"
            if !found.contains(canonical) { records.removeValue(forKey: canonical) }
        }
        if lookups.count > 512 {
            for victim in lookups.sorted(by: { $0.value < $1.value }).prefix(lookups.count - 512) {
                lookups.removeValue(forKey: victim.key)
            }
        }
    }

    mutating func ingest(_ hits: [ArchivedPR], now: Date) {
        for pr in hits {
            if let source = pr.sourceRepoSlug { aliases[source.lowercased()] = pr.repoSlug.lowercased() }
            let id = pr.id.lowercased()
            let redirectedID = pr.sourceRepoSlug.map { "\($0)#\(pr.number)".lowercased() }
            let redirected = redirectedID.flatMap { $0 == id ? nil : records.removeValue(forKey: $0) }
            // An older archive page must not overwrite a just-updated PR.
            if let previous = records[id], previous.pr.updatedAt > pr.updatedAt { continue }
            var metadata = pr
            // Search responses omit the branch; preserve the richer lookup
            // metadata instead of making local branch filters forget it.
            if metadata.branch == nil { metadata.branch = records[id]?.pr.branch ?? redirected?.pr.branch }
            records[id] = Record(pr: metadata, fetchedAt: now)
        }
        if records.count > Self.recordLimit {
            let victims = records.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(records.count - Self.recordLimit)
            for victim in victims { records.removeValue(forKey: victim.key) }
        }
    }

    mutating func remember(query: String, repos: [String], hits: [ArchivedPR], complete: Bool, now: Date) {
        // Exact-number freshness belongs to rememberLookup, which knows
        // which repositories actually answered. Combined retained rows do not.
        guard Self.number(in: query) == nil else { return }
        ingest(hits, now: now)
        guard complete else { return } // failures/partial answers are never negative cache entries
        let key = Self.key(query: query, repos: repos)
        queries[key] = Query(ids: hits.map { $0.id.lowercased() }, fetchedAt: now)
        queryOrder.removeAll { $0 == key }
        queryOrder.append(key)
        while queryOrder.count > Self.queryLimit {
            queries.removeValue(forKey: queryOrder.removeFirst())
        }
    }

    /// One bounded page per turn. Heads reconcile reopened/merged PRs;
    /// old pages resume across launches, with a hard ten-page ceiling per repo.
    func archivePage(repo: String, now: Date) -> Int? {
        let state = coverage[repo.lowercased()] ?? Coverage()
        if state.backfillDue, !state.finished { return state.nextPage }
        if now.timeIntervalSince(state.headFetchedAt) >= 300 { return 1 }
        return state.finished ? nil : state.nextPage
    }

    mutating func rememberPage(repo: String, page: Int, hits: [ArchivedPR], now: Date) {
        ingest(hits, now: now)
        let key = repo.lowercased()
        var state = coverage[key] ?? Coverage()
        if page == 1 {
            if hits.count == 100, state.finished, state.nextPage <= Self.pageLimit {
                // Revisit the previously short last page after growth, but
                // never reopen coverage stopped by the hard page ceiling.
                state.finished = false
                state.nextPage = max(2, state.nextPage - 1)
            }
            state.headFetchedAt = now
            state.backfillDue = true
        }
        else { state.nextPage = page + 1; state.backfillDue = false }
        if hits.count < 100 || page >= Self.pageLimit { state.finished = true }
        coverage[key] = state
    }
}

/// Disk I/O stays off the UI actor. No tokens or HTTP bodies are persisted.
actor GitHubPRIndexDisk {
    private let directory: URL
    private var savedRevisions: [String: Int] = [:]
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pultik/GitHub", isDirectory: true)) {
        self.directory = directory
    }

    func load(identity: String) -> GitHubPRIndex {
        let url = directory.appendingPathComponent(identity + ".json")
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= GitHubPRIndex.maximumBytes else { return GitHubPRIndex() }
            return try JSONDecoder().decode(GitHubPRIndex.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return GitHubPRIndex()
        } catch {
            NSLog("pultik: PR metadata cache could not load: %@", error.localizedDescription)
            return GitHubPRIndex()
        }
    }

    func save(_ index: GitHubPRIndex, identity: String, revision: Int) {
        guard revision > savedRevisions[identity, default: -1] else { return }
        do {
            let data = try JSONEncoder().encode(index)
            guard data.count <= GitHubPRIndex.maximumBytes else {
                NSLog("pultik: PR metadata cache exceeds disk limit; keeping memory snapshot")
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: directory.appendingPathComponent(identity + ".json"), options: .atomic)
            savedRevisions[identity] = revision
            // Token rotations must not accumulate an unbounded disk archive.
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != identity + ".json" }
                .sorted {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                }
            for old in files.dropFirst(2) {
                try FileManager.default.removeItem(at: old)
                savedRevisions.removeValue(forKey: old.deletingPathExtension().lastPathComponent)
            }
        } catch {
            NSLog("pultik: PR metadata cache could not save: %@", error.localizedDescription)
        }
    }
}
