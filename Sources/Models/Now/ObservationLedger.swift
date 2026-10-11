import Foundation

/// Bounded, identity-keyed need episodes (D14): when Pultík first saw each
/// need, and when a complete read stopped listing it. It gives a source
/// without an onset a first-observed one that survives relaunch (drawn
/// hollow), and feeds the Handled section ("cleared HH:MM").
///
/// Source resolution only. Local triage — ⇥ "dismissed" in `ResolvedStore` —
/// is a different fact and never lands here: a dismissed need is still open
/// at its source.
struct ObservationLedger: Equatable, Sendable {
    /// Handled needs stay listed this long; an entry no read has touched for
    /// this long is forgotten.
    static let retention: TimeInterval = 24 * 3600
    static let defaultCap = 2000

    let cap: Int
    private(set) var entries: [String: Entry] = [:]

    struct Entry: Codable, Equatable, Sendable {
        let source: NowSource
        /// The need as last observed — what Handled draws once it is gone.
        var need: NowNeed
        /// 1 for the first active spell; a need that clears and returns
        /// starts the next.
        var episode: Int
        var firstObservedAt: Date
        var lastObservedAt: Date
        var clearedAt: Date?
        var clearedBy: Clearing?

        var isActive: Bool { clearedAt == nil }
        var episodeID: String { "\(need.needID)#\(episode)" }
    }

    enum Clearing: String, Codable, Sendable {
        /// The source reported a terminal instant.
        case source
        /// A complete read no longer listed it; `clearedAt` is that poll.
        case noLongerObserved
    }

    init(cap: Int = defaultCap) {
        self.cap = cap
    }

    static func key(_ source: NowSource, _ needID: String) -> String {
        "\(source.key)|\(needID)"
    }

    /// Folds one read in and returns its needs stamped with their episode,
    /// observed onsets moved back to the episode's first observation. Only a
    /// complete read clears: a need its source no longer lists moves to
    /// Handled at the source's terminal instant, else at `now`.
    mutating func record(_ read: NowRead, now: Date) -> [NowNeed] {
        var listed = Set<String>()
        var stamped: [NowNeed] = []
        for var need in read.needs {
            let key = Self.key(read.source, need.needID)
            guard listed.insert(key).inserted else { continue }
            var entry = entries[key] ?? Entry(source: read.source, need: need, episode: 1, firstObservedAt: now,
                                              lastObservedAt: now)
            if !entry.isActive {
                entry.episode += 1
                entry.firstObservedAt = now
                entry.clearedAt = nil
                entry.clearedBy = nil
            }
            entry.lastObservedAt = max(entry.lastObservedAt, now)
            if need.onset.isObserved { need.onset = .observed(entry.firstObservedAt) }
            need.episodeID = entry.episodeID
            entry.need = need
            entries[key] = entry
            stamped.append(need)
        }
        if read.coverage == .complete {
            for (key, var entry) in entries where entry.source == read.source && entry.isActive && !listed.contains(key) {
                if let finished = read.finished[entry.need.needID] {
                    entry.clearedAt = finished
                    entry.clearedBy = .source
                } else {
                    entry.clearedAt = now
                    entry.clearedBy = .noLongerObserved
                }
                entries[key] = entry
            }
        }
        evict(now: now)
        return stamped
    }

    /// What `source` still has open: everything a complete read listed, plus
    /// what a partial or failed read could not see — missing is not resolved
    /// — less what began before its feed's `horizon`, out of its view.
    func open(_ source: NowSource, now: Date = Date()) -> [NowNeed] {
        entries.values.filter { entry in
            entry.source == source && entry.isActive
                && source.feed.horizon.map { now.timeIntervalSince(entry.need.onset.date) <= $0 } ?? true
        }.map(\.need)
    }

    /// Drops `feed`'s entries — all of them, or every identity but `keeping`
    /// — without handling any: a hidden source or another account's needs
    /// are not resolutions, and must not come back on the next launch.
    /// True when anything was dropped.
    @discardableResult
    mutating func forget(_ feed: NowFeed, keeping: NowSource? = nil) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value.source.feed != feed || $0.value.source == keeping }
        return entries.count != before
    }

    /// Needs cleared within the window, latest first — the Handled section,
    /// never ranked or counted.
    func handled(now: Date) -> [Entry] {
        let floor = now.addingTimeInterval(-Self.retention)
        let cleared: [(entry: Entry, at: Date)] = entries.values.compactMap { entry in
            guard let at = entry.clearedAt, at >= floor else { return nil }
            return (entry, at)
        }
        return cleared
            .sorted { lhs, rhs in lhs.at != rhs.at ? lhs.at > rhs.at : lhs.entry.episodeID < rhs.entry.episodeID }
            .map(\.entry)
    }

    /// Drops what aged past the window, then trims to the cap: cleared
    /// entries go before active ones, oldest first.
    mutating func evict(now: Date) {
        let floor = now.addingTimeInterval(-Self.retention)
        entries = entries.filter { ($0.value.clearedAt ?? $0.value.lastObservedAt) >= floor }
        guard entries.count > cap else { return }
        let kept = entries.sorted { lhs, rhs in
            if lhs.value.isActive != rhs.value.isActive { return lhs.value.isActive }
            let left = lhs.value.clearedAt ?? lhs.value.lastObservedAt
            let right = rhs.value.clearedAt ?? rhs.value.lastObservedAt
            return left != right ? left > right : lhs.key < rhs.key
        }.prefix(cap)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

// MARK: - Disk

extension ObservationLedger {
    /// The file's own version: another one starts empty rather than half-decoding.
    static let fileVersion = 1
    static let fileName = "observations.json"

    /// `~/Library/Caches/Pultik/Now/` — rebuildable state, so Caches.
    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches")
        return caches.appending(path: "Pultik/Now", directoryHint: .isDirectory)
    }

    private struct File: Codable {
        let version: Int
        let entries: [Entry]
    }

    /// A missing file is a first launch; an unreadable one or another
    /// version starts empty and says so in the log.
    static func load(from directory: URL, cap: Int = defaultCap) -> ObservationLedger {
        var ledger = ObservationLedger(cap: cap)
        let url = directory.appending(path: fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return ledger
        } catch {
            NSLog("pultik: now ledger unreadable at %@ — starting empty: %@", url.path, String(describing: error))
            return ledger
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version == fileVersion else {
                NSLog("pultik: now ledger v%d, this build reads v%d — starting empty", file.version, fileVersion)
                return ledger
            }
            for entry in file.entries {
                ledger.entries[key(entry.source, entry.need.needID)] = entry
            }
        } catch {
            NSLog("pultik: now ledger corrupt at %@ — starting empty: %@", url.path, String(describing: error))
        }
        return ledger
    }

    /// Atomic replace, so a crash mid-write leaves the previous file.
    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ordered = entries.sorted { $0.key < $1.key }.map(\.value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(File(version: Self.fileVersion, entries: ordered))
        try data.write(to: directory.appending(path: Self.fileName), options: .atomic)
    }
}
