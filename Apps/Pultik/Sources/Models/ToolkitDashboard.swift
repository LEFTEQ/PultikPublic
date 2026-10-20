import Foundation

/// `toolkit catalog dashboard --json`'s `data` (docs/specs/2026-10-20-toolkit-module-brief.md
/// § Wire contract, v1): the installed release's catalog of skills, bundled workflows and
/// guard rules, and what was measured of them in three local-calendar windows. Toolkit owns
/// the aggregation (vitr:dec/19kqjqz); the panel only projects and draws it. Measured
/// activity is named skill invocations and guard deny receipts, plus ONE generic total of
/// Workflow-tool launches never attributed to a script (vitr:dec/gqzr90g). A source that
/// was not available stays nil or unavailable, never a zero. Foundation-only: the
/// Foundation harness holds the contract (`Tests/ToolkitDashboardTests.swift`).
///
/// Wire changes are additive: unknown fields are dropped (never persisted), an unknown
/// kind is kept in the inventory but drawn in no list, and Go's `null` slices read as empty.
struct ToolkitDashboard: Codable, Sendable, Equatable {
    /// The `data.version` this app reads; any other is refused, never guessed.
    static let supportedVersion = 1

    let version: Int
    let generatedAt: Date
    /// The Toolkit release whose catalog this is.
    let release: String
    /// tokentime's last index run, not the generation time; nil = never indexed.
    let indexedAt: Date?
    let inventory: [Item]
    let windows: [Window]
    /// Coverage gaps the provider named (a guard ledger read failure, …).
    let issues: [String]

    init(version: Int = supportedVersion, generatedAt: Date, release: String, indexedAt: Date?,
         inventory: [Item], windows: [Window], issues: [String] = []) {
        self.version = version
        self.generatedAt = generatedAt
        self.release = release
        self.indexedAt = indexedAt
        self.inventory = inventory
        self.windows = windows
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, release, indexedAt, inventory, windows, issues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        release = try c.decodeIfPresent(String.self, forKey: .release) ?? ""
        indexedAt = try c.decodeIfPresent(Date.self, forKey: .indexedAt)
        inventory = try c.decodeIfPresent([Item].self, forKey: .inventory) ?? []
        windows = try c.decodeIfPresent([Window].self, forKey: .windows) ?? []
        issues = try c.decodeIfPresent([String].self, forKey: .issues) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(release, forKey: .release)
        try c.encodeIfPresent(indexedAt, forKey: .indexedAt)
        try c.encode(inventory, forKey: .inventory)
        try c.encode(windows, forKey: .windows)
        try c.encode(issues, forKey: .issues)
    }

    /// One catalog entry. `id` is globally unique: `skill:<catalog-id>`,
    /// `workflow:<owner>/<script-stem>`, `guard:<rule-id>`.
    struct Item: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable, CaseIterable {
            case skill, workflow, `guard`
        }

        let id: String
        /// Raw, so a kind a later provider adds still decodes.
        let kind: String
        let name: String
        var description: String?
        /// Where it lives in the release (a SKILL.md, a workflow script, the rule registry).
        var source: String?
        /// A workflow's owning skill, a guard's applet.
        var owner: String?
        /// The catalog status (`stable`, `experimental`, …) — never "enabled here".
        var status: String?
        var family: String?
        /// A guard's hook event (`PreToolUse`, …).
        var event: String?

        var itemKind: Kind? { Kind(rawValue: kind) }

        init(id: String, kind: String, name: String, description: String? = nil, source: String? = nil,
             owner: String? = nil, status: String? = nil, family: String? = nil, event: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.description = description
            self.source = source
            self.owner = owner
            self.status = status
            self.family = family
            self.event = event
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, name, description, source, owner, status, family, event
        }

        /// Go writes an unset string as `""`: it reads as absent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) throws -> String? {
                try c.decodeIfPresent(String.self, forKey: key).flatMap { $0.isEmpty ? nil : $0 }
            }
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            name = try text(.name) ?? id
            description = try text(.description)
            source = try text(.source)
            owner = try text(.owner)
            status = try text(.status)
            family = try text(.family)
            event = try text(.event)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encodeIfPresent(source, forKey: .source)
            try c.encodeIfPresent(owner, forKey: .owner)
            try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(family, forKey: .family)
            try c.encodeIfPresent(event, forKey: .event)
        }
    }

    /// One local-calendar window, `from` through `to` (the generation time).
    struct Window: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let label: String
        let from: Date
        let to: Date
        /// tokentime answered for this window.
        let skillsAvailable: Bool
        /// Every transcript byte up to `to` was indexed; false = partial counts.
        let skillsComplete: Bool
        /// Transcript bytes not indexed yet.
        let pendingBytes: Int
        /// The guard ledger was read.
        let guardsAvailable: Bool
        /// The ledger covered the whole window and read without an I/O
        /// failure; false = the counts are a floor (a retention edge, a read
        /// cut short). Absent on the wire: false — a ledger without
        /// unreadable receipts proves nothing about retention, I/O or when
        /// recording began.
        let guardsComplete: Bool
        /// Receipts skipped as unreadable: the guard counts are partial.
        let guardMalformed: Int
        /// Every Skill-tool call, catalog skill or not; nil = unavailable.
        let skillCalls: Int?
        /// Every Workflow-tool call, never attributed to a bundled script; nil = unavailable.
        let workflowCalls: Int?
        /// Guard deny receipts; nil = unavailable.
        let guardBlocks: Int?
        /// Measured named counts (skills and guards only). An id absent from
        /// it is zero only while its source is available.
        let activity: [Activity]
        /// The part of `skillCalls` no catalog skill names, as Toolkit measured
        /// it; nil = unknown (absent on the wire: `otherTotal` derives it).
        let unmatchedSkillCalls: Int?
        /// The part of `guardBlocks` no catalog rule names; nil = unknown.
        let unmatchedGuardBlocks: Int?

        init(id: String, label: String, from: Date, to: Date, skillsAvailable: Bool, skillsComplete: Bool,
             pendingBytes: Int = 0, guardsAvailable: Bool, guardsComplete: Bool = true, guardMalformed: Int = 0,
             skillCalls: Int?, workflowCalls: Int?, guardBlocks: Int?, activity: [Activity],
             unmatchedSkillCalls: Int? = nil, unmatchedGuardBlocks: Int? = nil) {
            self.unmatchedSkillCalls = unmatchedSkillCalls
            self.unmatchedGuardBlocks = unmatchedGuardBlocks
            self.id = id
            self.label = label
            self.from = from
            self.to = to
            self.skillsAvailable = skillsAvailable
            self.skillsComplete = skillsComplete
            self.pendingBytes = pendingBytes
            self.guardsAvailable = guardsAvailable
            self.guardsComplete = guardsComplete
            self.guardMalformed = guardMalformed
            self.skillCalls = skillCalls
            self.workflowCalls = workflowCalls
            self.guardBlocks = guardBlocks
            self.activity = activity
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, from, to, skillsAvailable, skillsComplete, pendingBytes, guardsAvailable,
                 guardsComplete, guardMalformed, skillCalls, workflowCalls, guardBlocks, activity,
                 unmatchedSkillCalls, unmatchedGuardBlocks
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
            from = try c.decode(Date.self, forKey: .from)
            to = try c.decode(Date.self, forKey: .to)
            skillsAvailable = try c.decodeIfPresent(Bool.self, forKey: .skillsAvailable) ?? false
            skillsComplete = try c.decodeIfPresent(Bool.self, forKey: .skillsComplete) ?? false
            pendingBytes = try c.decodeIfPresent(Int.self, forKey: .pendingBytes) ?? 0
            guardsAvailable = try c.decodeIfPresent(Bool.self, forKey: .guardsAvailable) ?? false
            guardMalformed = try c.decodeIfPresent(Int.self, forKey: .guardMalformed) ?? 0
            guardsComplete = try c.decodeIfPresent(Bool.self, forKey: .guardsComplete) ?? false
            skillCalls = try c.decodeIfPresent(Int.self, forKey: .skillCalls)
            workflowCalls = try c.decodeIfPresent(Int.self, forKey: .workflowCalls)
            guardBlocks = try c.decodeIfPresent(Int.self, forKey: .guardBlocks)
            activity = try c.decodeIfPresent([Activity].self, forKey: .activity) ?? []
            unmatchedSkillCalls = try c.decodeIfPresent(Int.self, forKey: .unmatchedSkillCalls)
            unmatchedGuardBlocks = try c.decodeIfPresent(Int.self, forKey: .unmatchedGuardBlocks)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(skillsAvailable, forKey: .skillsAvailable)
            try c.encode(skillsComplete, forKey: .skillsComplete)
            try c.encode(pendingBytes, forKey: .pendingBytes)
            try c.encode(guardsAvailable, forKey: .guardsAvailable)
            try c.encode(guardsComplete, forKey: .guardsComplete)
            try c.encode(guardMalformed, forKey: .guardMalformed)
            try c.encodeIfPresent(skillCalls, forKey: .skillCalls)
            try c.encodeIfPresent(workflowCalls, forKey: .workflowCalls)
            try c.encodeIfPresent(guardBlocks, forKey: .guardBlocks)
            try c.encode(activity, forKey: .activity)
            try c.encodeIfPresent(unmatchedSkillCalls, forKey: .unmatchedSkillCalls)
            try c.encodeIfPresent(unmatchedGuardBlocks, forKey: .unmatchedGuardBlocks)
        }

        /// Skill counts are a floor: transcripts wait to be indexed.
        var skillsPartial: Bool { skillsAvailable && (!skillsComplete || pendingBytes > 0) }
        /// Guard counts are a floor: the ledger did not cover the window or
        /// receipts were skipped.
        var guardsPartial: Bool { guardsAvailable && (!guardsComplete || guardMalformed > 0) }
    }

    struct Activity: Codable, Sendable, Equatable {
        let id: String
        let count: Int
    }
}

// MARK: - Projections

extension ToolkitDashboard {
    /// The panel's three windows, in the segmented control's order. The raw
    /// value is the wire's window id.
    enum Period: String, CaseIterable, Codable, Sendable {
        case today, week = "7d", month = "30d"

        var title: String {
            switch self {
            case .today: "Today"
            case .week: "7 days"
            case .month: "30 days"
            }
        }
    }

    /// What one item's activity in one window honestly is.
    enum Measure: Equatable, Sendable {
        /// A measured count; `partial` = a floor, its source incomplete.
        case count(Int, partial: Bool)
        /// The source did not answer: unknown, never zero.
        case unavailable
        /// Nothing measures it (a bundled workflow: launches are not attributed).
        case notMeasured

        var count: Int? {
            if case let .count(value, _) = self { return value }
            return nil
        }
    }

    /// One drawn row of a kind's list.
    struct Row: Identifiable, Equatable, Sendable {
        let item: Item
        let measure: Measure
        var id: String { item.id }
    }

    /// A measured name the catalog does not hold (a plugin's or a project's
    /// skill, a retired rule): shown in Overview's coverage, never folded into
    /// a catalog total.
    struct Unlisted: Identifiable, Equatable, Sendable {
        let id: String
        /// Its count in the window, as honest as its source (`measure(unlisted:in:)`).
        let measure: Measure
        var kind: Item.Kind? { Self.kind(of: id) }
        var name: String { id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id }

        static func kind(of id: String) -> Item.Kind? {
            id.split(separator: ":", maxSplits: 1).first.flatMap { Item.Kind(rawValue: String($0)) }
        }
    }

    func window(_ period: Period) -> Window? {
        windows.first { $0.id == period.rawValue }
    }

    func items(_ kind: Item.Kind) -> [Item] {
        inventory.filter { $0.itemKind == kind }
    }

    func item(_ id: String) -> Item? {
        inventory.first { $0.id == id }
    }

    /// One item's activity in `window` (nil window: the provider sent none).
    func measure(_ item: Item, in window: Window?) -> Measure {
        guard item.itemKind != nil else { return .notMeasured }
        return measure(id: item.id, kind: item.itemKind, in: window)
    }

    /// A measured name outside the catalog, judged by its id's kind like a
    /// catalog item; a kind this app does not know has no coverage to vouch
    /// for, so its count is a floor.
    func measure(unlisted id: String, in window: Window?) -> Measure {
        let kind = Unlisted.kind(of: id)
        guard kind != nil else {
            guard let window else { return .unavailable }
            return .count(window.count(of: id), partial: true)
        }
        return measure(id: id, kind: kind, in: window)
    }

    private func measure(id: String, kind: Item.Kind?, in window: Window?) -> Measure {
        guard let window else { return .unavailable }
        switch kind {
        case .skill:
            guard window.skillsAvailable else { return .unavailable }
            return .count(window.count(of: id), partial: window.skillsPartial)
        case .guard:
            guard window.guardsAvailable else { return .unavailable }
            return .count(window.count(of: id), partial: window.guardsPartial)
        case .workflow, nil:
            return .notMeasured
        }
    }

    /// A kind's rows matching `filter`: measured ones busiest first, then by
    /// name; workflows by owner, then name.
    func rows(_ kind: Item.Kind, period: Period, filter: String = "") -> [Row] {
        let window = window(period)
        let rows = items(kind).filter { Self.matches($0, filter) }.map { Row(item: $0, measure: measure($0, in: window)) }
        return rows.sorted { a, b in
            let ca = a.measure.count ?? -1, cb = b.measure.count ?? -1
            if ca != cb { return ca > cb }
            if kind == .workflow, (a.item.owner ?? "") != (b.item.owner ?? "") {
                return (a.item.owner ?? "") < (b.item.owner ?? "")
            }
            return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
        }
    }

    /// Overview's busiest of a measured kind: only what was used at least once.
    func top(_ kind: Item.Kind, period: Period, filter: String = "", limit: Int = 5) -> [Row] {
        Array(rows(kind, period: period, filter: filter).filter { ($0.measure.count ?? 0) > 0 }.prefix(limit))
    }

    /// Measured names outside this release's catalog, busiest first.
    func unlisted(period: Period, filter: String = "") -> [Unlisted] {
        guard let window = window(period) else { return [] }
        let known = Set(inventory.map(\.id))
        let text = filter.trimmingCharacters(in: .whitespaces)
        return window.activity
            .filter { !known.contains($0.id) && $0.count > 0 }
            .filter { text.isEmpty || $0.id.localizedCaseInsensitiveContains(text) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
            .map { Unlisted(id: $0.id, measure: measure(unlisted: $0.id, in: window)) }
    }

    /// The catalog's share of a measured total: the named counts of this
    /// release's items only. nil while the kind's source is unavailable.
    func catalogTotal(_ kind: Item.Kind, period: Period) -> Int? {
        guard let window = window(period) else { return nil }
        switch kind {
        case .skill: guard window.skillsAvailable else { return nil }
        case .guard: guard window.guardsAvailable else { return nil }
        case .workflow: return nil
        }
        let ids = Set(items(kind).map(\.id))
        return window.activity.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.count }
    }

    /// The rest of a measured total: what no catalog item names (a plugin's
    /// or a project's skill, a retired rule, a receipt without a rule). It
    /// stays in the total — the named list is never the whole of it. Toolkit's
    /// own measure when it sent one, else the total minus the catalog's
    /// share; nil while either is unknown.
    func otherTotal(_ kind: Item.Kind, period: Period) -> Int? {
        guard let window = window(period), let catalog = catalogTotal(kind, period: period) else { return nil }
        let (total, measured): (Int?, Int?) = switch kind {
        case .skill: (window.skillCalls, window.unmatchedSkillCalls)
        case .guard: (window.guardBlocks, window.unmatchedGuardBlocks)
        case .workflow: (nil, nil)
        }
        return measured ?? total.map { max(0, $0 - catalog) }
    }

    /// Every word of `filter` appears in one of the item's fields — the
    /// detail's description, source, owner, family and event included.
    static func matches(_ item: Item, _ filter: String) -> Bool {
        let words = filter.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [item.id, item.kind, item.name, item.description, item.source, item.owner, item.status,
                      item.family, item.event].compactMap { $0 }
        return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
    }
}

extension ToolkitDashboard.Window {
    /// A named count; absent = 0 (callers check the source is available).
    func count(of id: String) -> Int {
        activity.first { $0.id == id }?.count ?? 0
    }
}

// MARK: - The held answer

/// Why a read gave no dashboard. The message is shown on the page; it names
/// what to do when there is something to do.
enum ToolkitReadFailure: Error, Equatable, Sendable {
    /// No `toolkit` where its installers put it.
    case missing
    /// The installed `toolkit` predates `catalog dashboard`.
    case outdated
    case unsupportedVersion(Int)
    case timedOut(seconds: Int)
    case tooLarge(bytes: Int)
    /// toolkit answered with an error diagnostic or a failed exit.
    case failed(String)
    /// Its answer did not decode.
    case unreadable(String)

    var message: String {
        switch self {
        case .missing: "toolkit not found — brew install --cask toolkit"
        case .outdated: "This toolkit has no catalog dashboard — run toolkit sync"
        case let .unsupportedVersion(version): "toolkit sent dashboard v\(version); this Pultík reads v1 — update Pultík"
        case let .timedOut(seconds): "toolkit catalog dashboard did not answer in \(seconds)s"
        case let .tooLarge(bytes): "toolkit catalog dashboard printed over \(bytes / 1024 / 1024) MB"
        case let .failed(detail): detail
        case let .unreadable(detail): "Unreadable dashboard — \(detail)"
        }
    }
}

/// The module's state: the last dashboard and how it came to be held. A
/// snapshot restored from disk stays "cached" until a live read answers, and
/// a failed read keeps the dashboard it had beside the failure — neither is
/// ever drawn as current.
struct ToolkitHeld: Equatable, Sendable {
    /// Past this a live answer reads "as of HH:MM" (DESIGN.md §7, stale).
    static let staleAfter: TimeInterval = 300

    private(set) var dashboard: ToolkitDashboard?
    /// The last live answer.
    private(set) var readAt: Date?
    /// The dashboard was restored from disk and no live read has answered since.
    private(set) var restoredAt: Date?
    private(set) var failure: ToolkitReadFailure?
    /// The last live read, answered or failed.
    private(set) var attemptedAt: Date?

    enum Freshness: Equatable, Sendable {
        /// Nothing held and nothing failed yet.
        case loading
        case live(Date)
        case stale(Date)
        /// From disk at launch, not read live since.
        case cached(Date)
        /// The last read failed; `since` is what is still drawn, if anything.
        case failed(ToolkitReadFailure, since: Date?)

        var isCurrent: Bool {
            if case .live = self { return true }
            return false
        }
    }

    /// A cold start's snapshot: only while nothing live is held.
    mutating func restore(_ dashboard: ToolkitDashboard, fetchedAt: Date) {
        guard self.dashboard == nil, readAt == nil else { return }
        self.dashboard = dashboard
        restoredAt = fetchedAt
    }

    mutating func answered(_ dashboard: ToolkitDashboard, at date: Date) {
        self.dashboard = dashboard
        readAt = date
        attemptedAt = date
        restoredAt = nil
        failure = nil
    }

    /// The dashboard it had stays, labelled by its own age.
    mutating func failed(_ failure: ToolkitReadFailure, at date: Date = Date()) {
        self.failure = failure
        attemptedAt = date
    }

    func freshness(now: Date = Date()) -> Freshness {
        let heldAt = restoredAt ?? readAt
        if let failure { return .failed(failure, since: dashboard == nil ? nil : heldAt) }
        if let restoredAt { return .cached(restoredAt) }
        guard let readAt else { return .loading }
        return now.timeIntervalSince(readAt) > Self.staleAfter ? .stale(readAt) : .live(readAt)
    }
}
