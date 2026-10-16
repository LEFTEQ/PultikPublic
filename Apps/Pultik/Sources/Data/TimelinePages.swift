import Foundation
import Observation

// The paged history behind Semafor's timelines (vt-7781 WP4, D10): a window
// per host × lens, loaded as the view asks for a time range — the 1 h live
// edge first, older raw pages through `older`, server bins once a screen is
// zoomed out — merged and deduped across pages, held in a byte-bounded LRU,
// the newest 24 h persisted through `QueryRepository` for an instant first
// paint, and dropped by a generation-guarded `purge()` at the panel's 30 s
// tree release. Swift owns the data; the Rust timeline owns marks, layout and
// drawing (it reads `TimelineWindow`). Foundation-only:
// `tools/test-foundation.sh` builds it.

// MARK: - Keys and policy

/// One timeline flavour: CI (lanes × jobs), Estate (box × rollouts, backups
/// and cleanups), Backups (box × surface).
enum TimelineLens: String, Codable, Sendable, CaseIterable {
    case ci, estate, backups

    /// A raw page, s: Semafor's lenses — a CI day, three estate days.
    var pageS: Int { self == .ci ? 86_400 : 3 * 86_400 }
    /// A bins page, s.
    var binPageS: Int { 30 * 86_400 }
    /// How far right of now the newest page reaches, s: CI's minute, the
    /// estate's three days of scheduled runs.
    var futureS: Int { self == .ci ? 60 : 3 * 86_400 }
    /// Bins fade in at a screen this many days wide, and marks are gone at
    /// `marksUntilDays` (Semafor's `CI_ZOOM` and `MARKS_ZOOM`).
    var binsFromDays: Double { self == .ci ? 1.5 : 3 }
    var marksUntilDays: Double { self == .ci ? 2.5 : 5 }

    /// The bin width for a screen `days` wide, s.
    func bucketS(days: Double) -> Int {
        switch self {
        case .ci: days <= 7 ? 3600 : days <= 30 ? 6 * 3600 : 86_400
        case .estate, .backups: days <= 14 ? 6 * 3600 : 86_400
        }
    }

    var estateView: EstateTimelineView { self == .backups ? .backups : .estate }
}

/// One timeline's identity: whose Semafor (`host`, the server's ref) and
/// which lens.
struct TimelineKey: Hashable, Codable, Sendable {
    let host: String
    let lens: TimelineLens
}

/// What a screen needs loaded: raw items, bins of a width, or both while
/// they crossfade.
struct TimelineDensity: Equatable, Sendable {
    var raw: Bool
    /// The bins' width, s; nil = no bins.
    var bucketS: Int?

    static func of(_ lens: TimelineLens, span: TimeInterval) -> TimelineDensity {
        let days = span / 86_400
        return TimelineDensity(raw: days < lens.marksUntilDays,
                               bucketS: days >= lens.binsFromDays ? lens.bucketS(days: days) : nil)
    }
}

/// What a timeline view has on screen — the store's input from the view
/// (`StatusStore.setTimelineVisibility`). The store picks the hosts.
struct TimelineVisibility: Equatable, Sendable {
    var lens: TimelineLens
    /// The visible time range, UTC.
    var range: ClosedRange<Date>
    /// What the canvas draws at its zoom; nil = Semafor's policy for the range.
    var density: TimelineDensity?

    /// The keys a lens reads (D6, D14): CI the chip's host, plus the hosted
    /// source for the GitHub-hosted lanes when that is another host; the
    /// estate and backups every host with a Semafor, each for its boxes.
    static func keys(_ lens: TimelineLens, ciHost: String?, hostedSource: String?, hosts: [String]) -> [TimelineKey] {
        let picked = lens == .ci ? [ciHost, hostedSource].compactMap { $0 } : hosts
        var seen = Set<String>()
        return picked.filter { hosts.contains($0) && seen.insert($0).inserted }.map { TimelineKey(host: $0, lens: lens) }
    }
}

/// Everything loaded for one key, merged, deduped and sorted by (start, id).
/// Times are UTC instants (`timeIntervalSince1970`, seconds); bins are
/// `bucketS` seconds wide. A lens fills its own payload and leaves the
/// other's empty: CI `jobs` + `ciBins`; Estate and Backups `events` +
/// `estateBins` + `schedules` + `pins` (Backups has no pins).
struct TimelineWindow: Sendable {
    let key: TimelineKey
    /// Where the raw items are complete (CI by completion, the estate by
    /// time), oldest first and disjoint, never right of `now`: the future
    /// is the newest edge's scheduled marks and `schedules`.
    let covered: [ClosedRange<Date>]
    /// `TimelinePages.generation` when this was built.
    let generation: UInt64
    /// The server's clock at the newest page that reached now.
    let now: Date?
    /// Where the record begins, once a page said.
    let recordedSince: Date?
    /// Nothing live this generation: all of it is the restored snapshot,
    /// "as of `now`".
    let restored: Bool
    /// The bins' width, s, and where they are complete; nil and empty until
    /// a zoomed-out range was asked for. Bins are the server's counts: raw
    /// items never add to them, and a bin two pages carry counts once.
    let bucketS: Int?
    let binsCovered: [ClosedRange<Date>]

    /// CI: every job, finished and open (the newest edge's), each once.
    let jobs: [CITimelineJob]
    let ciBins: [CITimelineBin]
    /// Estate and Backups: every event, the scheduled future included.
    let events: [EstateTimelineEvent]
    let estateBins: [EstateTimelineBin]
    /// Timers whose repeats the renderer draws, only while their next run
    /// is in `events` (a passed one is stale and gone).
    let schedules: [EstateTimelineSchedule]
    let pins: [EstateTimelinePin]
}

// MARK: - The source

/// One page asked of a host's Semafor.
struct TimelineQuery: Hashable, Sendable {
    let key: TimelineKey
    /// Whole seconds, UTC.
    let before: Date
    /// Seconds before `before`.
    let span: Int
    /// Bins of this width (s); nil = raw items.
    let bucket: Int?
    /// The 1 h live edge (counted apart from history pages).
    let edge: Bool
}

/// A decoded page of either shape.
enum TimelinePage: Codable, Sendable, Equatable {
    case ci(CITimelinePage)
    case estate(EstateTimelinePage)

    var from: Date { switch self { case let .ci(p): p.from; case let .estate(p): p.from } }
    var to: Date { switch self { case let .ci(p): p.to; case let .estate(p): p.to } }
    var now: Date { switch self { case let .ci(p): p.now; case let .estate(p): p.now } }
    var older: Date? { switch self { case let .ci(p): p.older; case let .estate(p): p.older } }
    var recordedSince: Date? { switch self { case let .ci(p): p.recordedSince; case let .estate(p): p.recordedSince } }
    /// Semafor adds the open jobs to a page whose `before` is within a
    /// minute of its clock.
    var reachesNow: Bool { to >= now.addingTimeInterval(-60) }
    var markCount: Int {
        switch self {
        case let .ci(p): p.jobs.count + p.bins.count
        case let .estate(p): p.events.count + p.buckets.count
        }
    }
}

enum TimelineAnswer: Sendable {
    /// `bytes`: the page as received — what the LRU counts.
    case page(TimelinePage, bytes: Int)
    case failed(ProbeFailure)
    /// The host's breaker holds: nothing was asked.
    case held
}

/// Where pages come from: the store reads each host's Semafor behind its
/// breaker (`gated(.semafor(host:))`); a test answers itself.
struct TimelineSource: Sendable {
    var fetch: @MainActor @Sendable (TimelineQuery) async -> TimelineAnswer
    /// The snapshot identity of a host — its Semafor's origin; nil = that
    /// host's 24 h is not persisted.
    var identity: @MainActor @Sendable (String) -> String?
}

// MARK: - Pages

@MainActor
@Observable
final class TimelinePages {
    /// Bumped whenever a rebuilt window is published (and by a purge) — a
    /// view reads it to redraw. Windows are built off the main actor.
    private(set) var revision: UInt64 = 0
    /// Bumped by `purge()`: a load in flight across it never writes.
    @ObservationIgnored private(set) var generation: UInt64 = 0
    /// What the loaded pages weigh, encoded — the debug driver's metric.
    @ObservationIgnored private(set) var bytes = 0

    @ObservationIgnored var source: TimelineSource?
    @ObservationIgnored let byteLimit: Int
    @ObservationIgnored private let repository: QueryRepository?
    @ObservationIgnored private let clock: @MainActor () -> Date

    /// The newest edge is read again after this, s (the lane polls every 10).
    nonisolated static let edgeMinAge: TimeInterval = 5
    /// The live edge's span of the past, s (D10: the newest hour).
    nonisolated static let edgeS = 3600
    /// The newest bins page is read again after this, s, while bins show now.
    nonisolated static let binsEdgeMinAge: TimeInterval = 60
    /// The 24 h snapshot is written at most this often per key, s.
    nonisolated static let persistInterval: TimeInterval = 300
    /// The per-snapshot cap `QuerySnapshotStore` writes under, less room
    /// for its wrapper.
    nonisolated static let snapshotCap = (2 << 20) - 8192
    /// A gap is loaded this many pages at most per ask; the next ask goes on.
    nonisolated static let pagesPerGap = 16

    private enum Kind: Hashable, Sendable {
        case raw, edge, bins(Int)
    }

    private struct Stored: Sendable {
        let id: Int
        let key: TimelineKey
        let kind: Kind
        /// Fetch order: a newer copy of a mark wins; restored pages are 0.
        let seq: Int
        let page: TimelinePage
        var bytes: Int
        var used: Int
        let fetchedAt: Date
        let restored: Bool
    }

    @ObservationIgnored private var stored: [Int: Stored] = [:]
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var nextSeq = 1
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var edges: [TimelineKey: Int] = [:]
    @ObservationIgnored private var kept: [TimelineKey: Int] = [:]
    @ObservationIgnored private var bucket: [TimelineKey: Int] = [:]
    @ObservationIgnored private var asked: [TimelineKey: ClosedRange<Date>] = [:]
    @ObservationIgnored private var binsEdgeAt: [TimelineKey: Date] = [:]
    @ObservationIgnored private var restoreTried: Set<TimelineKey> = []
    @ObservationIgnored private var persistedAt: [TimelineKey: (at: Date, from: Date)] = [:]
    @ObservationIgnored private var persisting: Task<Void, Never>?
    @ObservationIgnored private var flights: [TimelineQuery: Task<TimelineAnswer, Never>] = [:]
    /// Each key's data version (bumped by every change to its pages) and
    /// the window last built, with the version it was built from.
    @ObservationIgnored private var version: [TimelineKey: UInt64] = [:]
    @ObservationIgnored private var built: [TimelineKey: (version: UInt64, window: TimelineWindow)] = [:]

    init(source: TimelineSource? = nil, byteLimit: Int = 16 << 20, repository: QueryRepository? = nil,
         clock: @escaping @MainActor () -> Date = { Date() })
    {
        self.source = source
        self.byteLimit = byteLimit
        self.repository = repository
        self.clock = clock
    }

    // MARK: Reading

    /// Everything loaded for `key`, or nil before anything is: the window
    /// last published, rebuilt off the main actor after each change (a
    /// passed scheduled run leaves with the next build — the edge's, every
    /// 10 s on screen). Built here only if none was yet.
    func window(for key: TimelineKey) -> TimelineWindow? {
        if let hit = built[key] { return hit.window }
        let pages = stored.values.filter { $0.key == key }
        guard !pages.isEmpty else { return nil }
        let window = Self.build(key, pages, width: bucket[key], generation: generation, now: clock())
        built[key] = (version[key, default: 0], window)
        return window
    }

    /// Rebuilds `key`'s window off the main actor when its pages changed
    /// since the last build, and publishes it — unless a purge or a newer
    /// change came meanwhile (that change publishes its own).
    private func publish(_ key: TimelineKey) async {
        let current = version[key, default: 0]
        guard built[key]?.version != current else { return }
        let pages = stored.values.filter { $0.key == key }
        let width = bucket[key]
        let generation = generation
        let now = clock()
        let window = pages.isEmpty ? nil : await Task.detached(priority: .userInitiated) {
            Self.build(key, pages, width: width, generation: generation, now: now)
        }.value
        guard generation == self.generation, version[key, default: 0] == current else { return }
        built[key] = window.map { (current, $0) }
        revision &+= 1
    }

    // MARK: Loading

    /// Loads what `range` is missing for `key`: the snapshot first (once a
    /// generation), the live edge when the range reaches the newest hour,
    /// raw pages back through `older` and, zoomed out, aligned bins pages.
    /// `density` is what the screen draws; nil = Semafor's zoom policy for
    /// the range's width. Concurrent asks for one page share one request.
    func request(_ key: TimelineKey, range: ClosedRange<Date>, density: TimelineDensity? = nil) async {
        let generation = generation
        await restore(key)
        guard generation == self.generation else { return }
        let density = density ?? .of(key.lens, span: range.upperBound.timeIntervalSince(range.lowerBound))
        asked[key] = range
        let inUse = touch(key, range)
        if bucket[key] != density.bucketS {
            bucket[key] = density.bucketS
            changed(key)
        }
        // The newest hour is the edge's, raw or binned.
        if range.upperBound >= clock().addingTimeInterval(-TimeInterval(Self.edgeS)) {
            await loadEdge(key, generation)
        }
        if density.raw, generation == self.generation {
            await loadRaw(key, range, generation)
        }
        if let width = density.bucketS, generation == self.generation {
            await loadBins(key, range, width, generation)
        }
        await settle(key, keeping: inUse, generation)
    }

    /// After an ask: the LRU back under its limit, every window it changed
    /// published, the snapshot written when due.
    private func settle(_ key: TimelineKey, keeping inUse: Int, _ generation: UInt64) async {
        guard generation == self.generation else { return }
        for changed in evict(keeping: inUse).union([key]) {
            await publish(changed)
        }
        guard generation == self.generation else { return }
        persistIfDue(key)
    }

    /// The live edge: the newest hour (plus the lens's future), read again
    /// once `edgeMinAge` old; and, while the screen shows bins reaching
    /// now, the newest bins page once a minute. The store's lane calls it
    /// every 10 s, only while the timeline is on screen.
    func refreshEdge(_ key: TimelineKey) async {
        let generation = generation
        await restore(key)
        guard generation == self.generation else { return }
        let inUse = tick
        await loadEdge(key, generation)
        await settle(key, keeping: inUse, generation)
    }

    private func loadEdge(_ key: TimelineKey, _ generation: UInt64) async {
        let now = clock()
        let edgeAge = edges[key].flatMap { stored[$0] }.map { now.timeIntervalSince($0.fetchedAt) }
        if edgeAge.map({ $0 >= Self.edgeMinAge }) ?? true {
            let before = Self.wholeSecond(now.addingTimeInterval(TimeInterval(key.lens.futureS)), up: true)
            let query = TimelineQuery(key: key, before: before, span: Self.edgeS + key.lens.futureS, bucket: nil, edge: true)
            let answer = await fetch(query)
            guard generation == self.generation else { return }
            if case let .page(page, bytes) = answer {
                insert(key, .edge, page, bytes: bytes)
                await publish(key)
            }
        }
        if let width = bucket[key], let range = asked[key],
           range.upperBound >= now.addingTimeInterval(-TimeInterval(width)),
           now.timeIntervalSince(binsEdgeAt[key] ?? .distantPast) >= Self.binsEdgeMinAge
        {
            binsEdgeAt[key] = now
            let size = TimeInterval(width)
            let upper = Self.align(now.addingTimeInterval(TimeInterval(key.lens.futureS)), size, up: true)
            let lower = Self.align(now.addingTimeInterval(-size), size, up: false)
            let query = TimelineQuery(key: key, before: upper, span: Int(upper.timeIntervalSince(lower)), bucket: width, edge: true)
            let answer = await fetch(query)
            guard generation == self.generation else { return }
            if case let .page(page, bytes) = answer { insert(key, .bins(width), page, bytes: bytes) }
        }
    }

    /// Drops every loaded page (the panel's 30 s tree release). A load in
    /// flight across it finds another generation and writes nothing; the
    /// snapshots stay on disk for the next first paint.
    func purge() {
        generation &+= 1
        stored.removeAll()
        edges.removeAll()
        kept.removeAll()
        bucket.removeAll()
        asked.removeAll()
        binsEdgeAt.removeAll()
        restoreTried.removeAll()
        persistedAt.removeAll()
        flights.removeAll()
        built.removeAll()
        version.removeAll()
        bytes = 0
        revision &+= 1
    }

    private func loadRaw(_ key: TimelineKey, _ range: ClosedRange<Date>, _ generation: UInt64) async {
        let now = clock()
        // A screen reaching into the last day loads the whole day: it is
        // what the snapshot keeps (D10). The edge's hour is loaded already.
        let day = now.addingTimeInterval(-86_400)
        var lower = range.upperBound >= day ? min(range.lowerBound, day) : range.lowerBound
        if let since = recordedSince(key) { lower = max(lower, since) }
        var upper = min(range.upperBound, now)
        if let id = edges[key], let edge = stored[id] { upper = min(upper, edge.page.from) }
        guard lower < upper else { return }
        for gap in Self.gaps(lower...upper, in: rawCovered(key)).reversed() {
            await fill(key, gap, bucket: nil, generation)
            guard generation == self.generation else { return }
        }
    }

    private func loadBins(_ key: TimelineKey, _ range: ClosedRange<Date>, _ width: Int, _ generation: UInt64) async {
        let now = clock()
        let size = TimeInterval(width)
        var lower = range.lowerBound
        if let since = recordedSince(key) { lower = max(lower, since) }
        let ceiling = now.addingTimeInterval(TimeInterval(key.lens.futureS))
        let upper = Self.align(min(range.upperBound, ceiling), size, up: true)
        lower = Self.align(lower, size, up: false)
        guard lower < upper else { return }
        for gap in Self.gaps(lower...upper, in: binsCovered(key, width)).reversed() {
            let aligned = Self.align(gap.lowerBound, size, up: false)...Self.align(gap.upperBound, size, up: true)
            await fill(key, aligned, bucket: width, generation)
            guard generation == self.generation else { return }
        }
    }

    /// Pages `gap` from its newer end back through `older`. Bins pages stay
    /// on the bucket's boundaries, so no bin is ever split between two.
    private func fill(_ key: TimelineKey, _ gap: ClosedRange<Date>, bucket width: Int?, _ generation: UInt64) async {
        let now = clock()
        var before = Self.wholeSecond(gap.upperBound, up: true)
        for _ in 0..<Self.pagesPerGap {
            var span: Int
            var upper = before
            if let width {
                let pageS = key.lens.binPageS
                let want = Int(before.timeIntervalSince(gap.lowerBound).rounded(.up))
                span = max(width, min(pageS, (want + width - 1) / width * width))
                span = max(span, (3600 + width - 1) / width * width)
            } else {
                let want = Int(before.timeIntervalSince(gap.lowerBound).rounded(.up))
                span = max(3600, min(key.lens.pageS, want))
                // A page reaching now carries the open jobs and the scheduled future.
                if before >= now.addingTimeInterval(-60) {
                    upper = Self.wholeSecond(now.addingTimeInterval(TimeInterval(key.lens.futureS)), up: true)
                    span += Int(upper.timeIntervalSince(before))
                }
            }
            let query = TimelineQuery(key: key, before: upper, span: span, bucket: width, edge: false)
            guard case let .page(page, bytes) = await fetch(query), generation == self.generation else { return }
            insert(key, width.map(Kind.bins) ?? .raw, page, bytes: bytes)
            await publish(key) // each page paints as it lands
            guard generation == self.generation, let older = page.older, older > gap.lowerBound, older < before else { return }
            before = older
        }
    }

    /// One request per page: a second ask joins the first. Purge forgets
    /// the flights, so an ask after it never joins one from before.
    private func fetch(_ query: TimelineQuery) async -> TimelineAnswer {
        if let flight = flights[query] { return await flight.value }
        guard let source else { return .held }
        let flight = Task { await source.fetch(query) }
        flights[query] = flight
        let answer = await flight.value
        if flights[query] == flight { flights[query] = nil }
        return answer
    }

    // MARK: Storing

    private func insert(_ key: TimelineKey, _ kind: Kind, _ page: TimelinePage, bytes: Int, restored: Bool = false) {
        let id = nextID
        nextID += 1
        let seq = restored ? 0 : nextSeq
        if !restored { nextSeq += 1 }
        tick += 1
        let new = Stored(id: id, key: key, kind: kind, seq: seq, page: page, bytes: bytes,
                         used: tick, fetchedAt: clock(), restored: restored)
        stored[id] = new
        self.bytes += bytes
        if kind == .edge {
            if let old = edges[key] { fold(old, into: key, before: page.from) }
            edges[key] = id
        } else {
            supersede(by: new)
        }
        changed(key)
    }

    /// An older page of the same kind inside the new one's range holds
    /// nothing the new one lacks (finished marks never change): it goes.
    private func supersede(by new: Stored) {
        let current = edges[new.key]
        for (id, old) in stored where id != new.id && id != current && old.key == new.key && old.kind == new.kind
            && old.seq <= new.seq && old.page.from >= new.page.from && old.page.to <= new.page.to
        {
            stored[id] = nil
            bytes -= old.bytes
            if kept[new.key] == id { kept[new.key] = nil }
        }
    }

    /// A replaced edge's finished marks that the new edge no longer reaches
    /// stay as history (Semafor's `kept`): the edge slides on, and they would
    /// otherwise leave once it passed them.
    private func fold(_ id: Int, into key: TimelineKey, before cut: Date) {
        guard let old = stored.removeValue(forKey: id) else { return }
        bytes -= old.bytes
        let upper = min(old.page.now, cut)
        guard old.page.from < upper else { return }
        let share = { (kept: Int) in old.page.markCount == 0 ? 0 : old.bytes * kept / old.page.markCount }
        let incoming: TimelinePage
        let count: Int
        switch old.page {
        case var .ci(page):
            page.jobs = page.jobs.filter { !$0.isOpen && ($0.completedAt ?? $0.queuedAt) < upper }
            page.bins = []
            page.to = upper
            count = page.jobs.count
            incoming = .ci(page)
        case var .estate(page):
            page.events = page.events.filter { !$0.isScheduled && !$0.isLive && $0.at < upper }
            page.buckets = []
            page.schedules = []
            page.to = upper
            count = page.events.count
            incoming = .estate(page)
        }
        if let keptID = kept[key], let current = stored[keptID], current.page.to >= old.page.from.addingTimeInterval(-1) {
            stored[keptID] = Stored(id: keptID, key: key, kind: .raw, seq: old.seq, page: Self.join(current.page, incoming),
                                    bytes: current.bytes + share(count), used: max(current.used, old.used),
                                    fetchedAt: old.fetchedAt, restored: false)
            bytes += share(count)
        } else {
            let keptID = nextID
            nextID += 1
            stored[keptID] = Stored(id: keptID, key: key, kind: .raw, seq: old.seq, page: incoming, bytes: share(count),
                                    used: old.used, fetchedAt: old.fetchedAt, restored: false)
            bytes += share(count)
            kept[key] = keptID
        }
    }

    /// `older` and `newer` cover adjacent or overlapping time: one page over
    /// both, `newer`'s copy of a mark winning.
    private nonisolated static func join(_ older: TimelinePage, _ newer: TimelinePage) -> TimelinePage {
        switch (older, newer) {
        case let (.ci(a), .ci(b)):
            let ids = Set(b.jobs.map(\.id))
            var page = b
            page.from = min(a.from, b.from)
            page.to = max(a.to, b.to)
            page.jobs = a.jobs.filter { !ids.contains($0.id) } + b.jobs
            return .ci(page)
        case let (.estate(a), .estate(b)):
            let ids = Set(b.events.map(\.id))
            var page = b
            page.from = min(a.from, b.from)
            page.to = max(a.to, b.to)
            page.events = a.events.filter { !ids.contains($0.id) } + b.events
            let pins = Set(b.pins.map { "\($0.box)|\($0.from.timeIntervalSince1970)" })
            page.pins = a.pins.filter { !pins.contains("\($0.box)|\($0.from.timeIntervalSince1970)") } + b.pins
            return .estate(page)
        default:
            return newer
        }
    }

    /// Pages under the range on screen are the last to go; returns the use
    /// mark of this ask.
    private func touch(_ key: TimelineKey, _ range: ClosedRange<Date>) -> Int {
        tick += 1
        for (id, page) in stored where page.key == key && page.page.from <= range.upperBound && page.page.to >= range.lowerBound {
            stored[id]?.used = tick
        }
        return tick
    }

    /// Over the byte limit, the least recently used pages go — never a
    /// current edge, never one used at or after `inUse` (the ask that ran).
    /// Returns the keys that lost pages.
    private func evict(keeping inUse: Int) -> Set<TimelineKey> {
        guard bytes > byteLimit else { return [] }
        let current = Set(edges.values)
        let victims = stored.values.filter { !current.contains($0.id) && $0.used < inUse }.sorted { $0.used < $1.used }
        var dropped = Set<TimelineKey>()
        for victim in victims {
            guard bytes > byteLimit else { break }
            stored[victim.id] = nil
            bytes -= victim.bytes
            if kept[victim.key] == victim.id { kept[victim.key] = nil }
            dropped.insert(victim.key)
        }
        dropped.forEach(changed)
        return dropped
    }

    private func changed(_ key: TimelineKey) {
        version[key, default: 0] &+= 1
    }

    // MARK: Coverage

    private func pages(_ key: TimelineKey) -> [Stored] { stored.values.filter { $0.key == key } }

    private func recordedSince(_ key: TimelineKey) -> Date? { Self.recordedSince(pages(key)) }

    private func rawCovered(_ key: TimelineKey) -> [ClosedRange<Date>] { Self.rawCovered(pages(key)) }

    private func binsCovered(_ key: TimelineKey, _ width: Int) -> [ClosedRange<Date>] {
        Self.binsCovered(pages(key), width)
    }

    private nonisolated static func recordedSince(_ pages: [Stored]) -> Date? {
        pages.compactMap(\.page.recordedSince).min()
    }

    /// Raw coverage, never right of a page's own `now`.
    private nonisolated static func rawCovered(_ pages: [Stored]) -> [ClosedRange<Date>] {
        union(pages.filter { $0.kind == .raw || $0.kind == .edge }.compactMap { page in
            let upper = min(page.page.to, page.page.now)
            return page.page.from <= upper ? page.page.from...upper : nil
        })
    }

    private nonisolated static func binsCovered(_ pages: [Stored], _ width: Int) -> [ClosedRange<Date>] {
        union(pages.filter { $0.kind == .bins(width) }.map { $0.page.from...$0.page.to })
    }

    /// Sorted, overlapping or touching ranges joined.
    nonisolated static func union(_ ranges: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound.addingTimeInterval(1) {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// What of `range` the `covered` ranges miss, oldest first; slivers
    /// under a second are not gaps.
    nonisolated static func gaps(_ range: ClosedRange<Date>, in covered: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        var out: [ClosedRange<Date>] = []
        var cursor = range.lowerBound
        for part in covered where part.upperBound > cursor && part.lowerBound < range.upperBound {
            if part.lowerBound.timeIntervalSince(cursor) >= 1 { out.append(cursor...part.lowerBound) }
            cursor = max(cursor, part.upperBound)
        }
        if range.upperBound.timeIntervalSince(cursor) >= 1 { out.append(cursor...range.upperBound) }
        return out
    }

    nonisolated static func align(_ date: Date, _ size: TimeInterval, up: Bool) -> Date {
        let steps = date.timeIntervalSince1970 / size
        return Date(timeIntervalSince1970: (up ? steps.rounded(.up) : steps.rounded(.down)) * size)
    }

    nonisolated static func wholeSecond(_ date: Date, up: Bool) -> Date { align(date, 1, up: up) }

    // MARK: Building a window

    /// A key's window from its pages — pure, so it runs off the main actor.
    private nonisolated static func build(_ key: TimelineKey, _ pages: [Stored], width: Int?, generation: UInt64,
                                          now: Date) -> TimelineWindow
    {
        let raw = pages.filter { !isBins($0.kind) }.sorted { $0.seq < $1.seq }
        // Open jobs and scheduled runs are the newest page reaching now's alone.
        let owner = raw.filter(\.page.reachesNow).max { $0.seq < $1.seq }
        let bins = width.map { width in pages.filter { $0.kind == .bins(width) }.sorted { $0.seq < $1.seq } } ?? []
        var jobs: [CITimelineJob] = []
        var ciBins: [CITimelineBin] = []
        var events: [EstateTimelineEvent] = []
        var estateBins: [EstateTimelineBin] = []
        var schedules: [EstateTimelineSchedule] = []
        var pins: [EstateTimelinePin] = []
        switch key.lens {
        case .ci:
            jobs = mergeJobs(raw.compactMap { if case let .ci(p) = $0.page { p.jobs } else { nil } },
                             open: owner.flatMap { if case let .ci(p) = $0.page { p.jobs } else { nil } } ?? [])
            ciBins = mergeBins(bins.compactMap { stored in
                if case let .ci(p) = stored.page { (p.from, p.to, p.bins) } else { nil }
            }, key: { "\($0.lane)|\($0.from.timeIntervalSince1970)" }, at: \.from)
                .sorted { ($0.from, $0.lane) < ($1.from, $1.lane) }
        case .estate, .backups:
            let estatePages = raw.compactMap { if case let .estate(p) = $0.page { p } else { nil } }
            let ownerPage: EstateTimelinePage? = owner.flatMap { if case let .estate(p) = $0.page { p } else { nil } }
            (events, schedules) = mergeEvents(estatePages, owner: ownerPage, now: now)
            pins = mergePins(estatePages.map(\.pins))
            estateBins = mergeBins(bins.compactMap { stored in
                if case let .estate(p) = stored.page { (p.from, p.to, p.buckets) } else { nil }
            }, key: { "\($0.box)|\($0.row)|\($0.surface ?? "")|\($0.scheduled)|\($0.from.timeIntervalSince1970)" }, at: \.from)
                .sorted { ($0.from, $0.box, $0.row, $0.surface ?? "") < ($1.from, $1.box, $1.row, $1.surface ?? "") }
        }
        return TimelineWindow(
            key: key, covered: rawCovered(pages), generation: generation,
            now: owner?.page.now ?? pages.map(\.page.now).max(), recordedSince: recordedSince(pages),
            restored: !pages.contains { !$0.restored }, bucketS: width,
            binsCovered: width.map { binsCovered(pages, $0) } ?? [],
            jobs: jobs, ciBins: ciBins, events: events, estateBins: estateBins, schedules: schedules, pins: pins)
    }

    private nonisolated static func isBins(_ kind: Kind) -> Bool {
        if case .bins = kind { true } else { false }
    }

    /// Finished jobs by id, the newer page's copy winning; then the owner's
    /// open jobs, except one whose finished copy is loaded — the same id (a
    /// hosted job keeps `gh-<id>`) or the same GitHub job (a fleet job's
    /// record arrives under its runner, sometimes while the webhook still
    /// says running).
    nonisolated static func mergeJobs(_ pages: [[CITimelineJob]], open: [CITimelineJob]) -> [CITimelineJob] {
        var jobs: [CITimelineJob] = []
        jobs.reserveCapacity(pages.reduce(open.count) { $0 + $1.count })
        var at: [String: Int] = [:]
        at.reserveCapacity(jobs.capacity)
        for page in pages {
            for job in page where !job.isOpen {
                if let index = at[job.id] { jobs[index] = job } else { at[job.id] = jobs.count; jobs.append(job) }
            }
        }
        var done = Set<Int64>()
        for job in jobs { if let gh = job.ghJobId { done.insert(gh) } }
        for job in open where job.isOpen && at[job.id] == nil && !(job.ghJobId.map(done.contains) ?? false) {
            at[job.id] = jobs.count
            jobs.append(job)
        }
        return byStart(jobs, start: \.queuedAt, id: \.id)
    }

    /// Events by id, the newer page's copy winning — except that a `live`
    /// copy never replaces a finished one. Scheduled runs and schedules are
    /// the owner's alone: a passed run is stale and dropped, and so is a
    /// schedule whose next run is not loaded.
    nonisolated static func mergeEvents(_ pages: [EstateTimelinePage], owner: EstateTimelinePage?, now: Date)
        -> (events: [EstateTimelineEvent], schedules: [EstateTimelineSchedule])
    {
        var events: [EstateTimelineEvent] = []
        events.reserveCapacity(pages.reduce(0) { $0 + $1.events.count })
        var at: [String: Int] = [:]
        at.reserveCapacity(events.capacity)
        for page in pages {
            for event in page.events where !event.isScheduled {
                if let index = at[event.id] {
                    if event.isLive, !events[index].isLive { continue }
                    events[index] = event
                } else {
                    at[event.id] = events.count
                    events.append(event)
                }
            }
        }
        var scheduled = Set<String>()
        for event in owner?.events ?? [] where event.isScheduled && event.at >= now && at[event.id] == nil {
            at[event.id] = events.count
            events.append(event)
            scheduled.insert(event.id)
        }
        let schedules = (owner?.schedules ?? []).filter { $0.periodS > 0 && scheduled.contains($0.nextID) }
        return (byStart(events, start: \.at, id: \.id), schedules)
    }

    /// Sorted by (start, id) through an index sort: the marks are large
    /// values, cheap to gather once and costly to swap.
    private nonisolated static func byStart<Mark>(_ marks: [Mark], start: KeyPath<Mark, Date>,
                                                  id: KeyPath<Mark, String>) -> [Mark]
    {
        let keys = marks.map { $0[keyPath: start].timeIntervalSince1970 }
        let order = marks.indices.sorted { lhs, rhs in
            keys[lhs] != keys[rhs] ? keys[lhs] < keys[rhs] : marks[lhs][keyPath: id] < marks[rhs][keyPath: id]
        }
        return order.map { marks[$0] }
    }

    /// One band per pin (box, start), the newer page's winning — it may
    /// have learnt where the pin ended.
    nonisolated static func mergePins(_ pages: [[EstateTimelinePin]]) -> [EstateTimelinePin] {
        var byStart: [String: EstateTimelinePin] = [:]
        for page in pages { for pin in page { byStart["\(pin.box)|\(pin.from.timeIntervalSince1970)"] = pin } }
        return byStart.values.sorted { ($0.from, $0.box) < ($1.from, $1.box) }
    }

    /// Bins pages in fetch order, each the whole truth for its range: a
    /// newer page replaces every bin it covers, so a bin is counted once
    /// however its pages overlap.
    nonisolated static func mergeBins<Bin>(_ pages: [(from: Date, to: Date, bins: [Bin])], key: (Bin) -> String,
                                           at: KeyPath<Bin, Date>) -> [Bin]
    {
        var byKey: [String: Bin] = [:]
        for page in pages {
            byKey = byKey.filter { $0.value[keyPath: at] < page.from || $0.value[keyPath: at] >= page.to }
            for bin in page.bins { byKey[key(bin)] = bin }
        }
        return Array(byKey.values)
    }

    // MARK: The 24 h snapshot

    nonisolated static func snapshotResource(_ lens: TimelineLens) -> QueryResource<TimelineSnapshot> {
        QueryResource(name: "semafor.timeline.\(lens.rawValue)", staleAfter: 60, keep: 4)
    }

    private func snapshotKey(_ key: TimelineKey) -> QueryKey? {
        source?.identity(key.host).map { QueryKey(resource: Self.snapshotResource(key.lens).name, identity: $0) }
    }

    /// Once a generation, before the first read: the key's last 24 h from
    /// disk, as pages older than any live one.
    private func restore(_ key: TimelineKey) async {
        guard let repository, !restoreTried.contains(key) else { return }
        restoreTried.insert(key)
        guard let queryKey = snapshotKey(key) else { return }
        let generation = generation
        guard let held = await repository.held(Self.snapshotResource(key.lens), key: queryKey, remember: false),
              generation == self.generation, held.value.lens == key.lens else { return }
        insert(key, .raw, held.value.raw, bytes: held.value.rawBytes, restored: true)
        if let hourly = held.value.hourly {
            insert(key, .bins(3600), hourly, bytes: held.value.hourlyBytes, restored: true)
        }
        await publish(key) // the first paint, before Semafor answers
    }

    /// The newest 24 h, written once a live edge holds it — again every
    /// `persistInterval`, or sooner once the loaded day grew an hour (the
    /// edge lands before the rest of the day) — fitted under the snapshot
    /// cap off the main actor.
    private func persistIfDue(_ key: TimelineKey) {
        guard let repository, let queryKey = snapshotKey(key),
              let window = window(for: key), !window.restored, let serverNow = window.now,
              let newest = window.covered.last, newest.upperBound >= serverNow.addingTimeInterval(-120),
              let edgeID = edges[key], let edge = stored[edgeID], !edge.restored else { return }
        let now = clock()
        let from = max(newest.lowerBound, serverNow.addingTimeInterval(-86_400))
        if let last = persistedAt[key], now.timeIntervalSince(last.at) < Self.persistInterval,
           from > last.from.addingTimeInterval(-3600) { return }
        persistedAt[key] = (now, from)
        let candidate = TimelineSnapshot.Candidate(window: window, from: from, to: edge.page.to)
        let resource = Self.snapshotResource(key.lens)
        let cap = Self.snapshotCap
        // One write after another: a later day never lands under an earlier
        // hour. Disk only — a purge meanwhile leaves the next paint the newest.
        let previous = persisting
        persisting = Task.detached(priority: .utility) {
            await previous?.value
            guard let fitted = candidate.fitted(cap: cap) else {
                NSLog("pultik: timeline %@/%@ 24 h snapshot does not fit %d bytes — not written",
                      key.host, key.lens.rawValue, cap)
                return
            }
            await repository.persist(resource, key: queryKey, value: fitted.snapshot, at: now)?.value
        }
    }
}

// MARK: - Snapshot

/// One key's newest 24 h on disk (D10): raw to the edge — open jobs and the
/// scheduled future included — and, when a raw day would pass the 2 MiB
/// snapshot cap, the day's older part as hourly bins counted from the raw
/// marks (the server's rules: CI by completion, hosted jobs uncounted).
struct TimelineSnapshot: Codable, Sendable {
    var lens: TimelineLens
    var raw: TimelinePage
    /// The raw part's share of the LRU when restored, bytes.
    var rawBytes: Int
    var hourly: TimelinePage?
    var hourlyBytes: Int

    /// What a window holds from `from` to the edge's `to`.
    struct Candidate: Sendable {
        let window: TimelineWindow
        let from: Date
        let to: Date

        /// The snapshot and its encoded size, raw from `rawFrom` on.
        func make(rawFrom: Date) -> TimelineSnapshot {
            let now = window.now ?? to
            let hour = TimelinePages.align(from, 3600, up: false)
            let lens = window.key.lens
            switch lens {
            case .ci:
                let jobs = window.jobs.filter { $0.isOpen || ($0.completedAt ?? $0.queuedAt) >= rawFrom }
                let raw = TimelinePage.ci(CITimelinePage(from: rawFrom, to: to, now: now, older: nil,
                                                         recordedSince: window.recordedSince, jobs: jobs, bins: []))
                guard rawFrom > from else { return TimelineSnapshot(lens: lens, raw: raw, rawBytes: 0, hourly: nil, hourlyBytes: 0) }
                var bins: [String: CITimelineBin] = [:]
                for job in window.jobs where !job.hosted && !job.isOpen {
                    guard let done = job.completedAt, done >= hour, done < rawFrom else { continue }
                    let start = TimelinePages.align(done, 3600, up: false)
                    let key = "\(job.lane)|\(start.timeIntervalSince1970)"
                    var bin = bins[key] ?? CITimelineBin(lane: job.lane, from: start, count: 0, failures: 0, cancelled: 0)
                    bin.count += 1
                    if job.result == "failed" { bin.failures += 1 }
                    if job.result == "cancelled" { bin.cancelled += 1 }
                    bins[key] = bin
                }
                let hourly = TimelinePage.ci(CITimelinePage(from: hour, to: rawFrom, now: now, older: nil,
                                                            recordedSince: window.recordedSince, jobs: [],
                                                            bins: bins.values.sorted { ($0.from, $0.lane) < ($1.from, $1.lane) }))
                return TimelineSnapshot(lens: lens, raw: raw, rawBytes: 0, hourly: hourly, hourlyBytes: 0)
            case .estate, .backups:
                let events = window.events.filter { $0.at >= rawFrom }
                let raw = TimelinePage.estate(EstateTimelinePage(from: rawFrom, to: to, now: now, older: nil,
                                                                 recordedSince: window.recordedSince, events: events,
                                                                 buckets: [], pins: window.pins, schedules: window.schedules))
                guard rawFrom > from else { return TimelineSnapshot(lens: lens, raw: raw, rawBytes: 0, hourly: nil, hourlyBytes: 0) }
                var bins: [String: EstateTimelineBin] = [:]
                for event in window.events where !event.isScheduled && event.at >= hour && event.at < rawFrom {
                    let start = TimelinePages.align(event.at, 3600, up: false)
                    let row = lens == .backups ? "backups" : event.row
                    let surface = lens == .backups ? event.surface : nil
                    let key = "\(event.box)|\(row)|\(surface ?? "")|\(start.timeIntervalSince1970)"
                    var bin = bins[key] ?? EstateTimelineBin(box: event.box, row: row, from: start, count: 0, failures: 0,
                                                             scheduled: false, surface: surface)
                    bin.count += 1
                    if event.result == "fail" { bin.failures += 1 }
                    bins[key] = bin
                }
                let hourly = TimelinePage.estate(EstateTimelinePage(
                    from: hour, to: rawFrom, now: now, older: nil, recordedSince: window.recordedSince, events: [],
                    buckets: bins.values.sorted { ($0.from, $0.box, $0.row) < ($1.from, $1.box, $1.row) }, pins: [],
                    schedules: []))
                return TimelineSnapshot(lens: lens, raw: raw, rawBytes: 0, hourly: hourly, hourlyBytes: 0)
            }
        }

        /// The whole day raw when it fits `cap`; else raw over a shorter
        /// newest part (whole hours) and hourly bins before it. Nil when not
        /// even the newest hour fits.
        func fitted(cap: Int) -> (snapshot: TimelineSnapshot, bytes: Int)? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var rawFrom = from
            for _ in 0..<8 {
                var snapshot = make(rawFrom: rawFrom)
                guard let rawData = try? encoder.encode(snapshot.raw) else { return nil }
                let hourlyData = (try? snapshot.hourly.map { try encoder.encode($0) }) ?? nil
                snapshot.rawBytes = rawData.count
                snapshot.hourlyBytes = hourlyData?.count ?? 0
                let total = rawData.count + snapshot.hourlyBytes + 256
                if total <= cap { return (snapshot, total) }
                let edge = window.now ?? to
                let kept = edge.timeIntervalSince(rawFrom) * Double(cap) * 0.9 / Double(rawData.count)
                let next = TimelinePages.align(edge.addingTimeInterval(-kept), 3600, up: true)
                guard next > rawFrom, next < edge else { return nil }
                rawFrom = next
            }
            return nil
        }
    }
}
