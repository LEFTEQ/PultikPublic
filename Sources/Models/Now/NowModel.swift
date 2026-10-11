import Foundation

// The Now queue's vocabulary — Home's ranked "what needs me" (copilot shell
// D6, D12–D15). The contract is docs/specs/2026-10-09-now-queue-contracts.md:
// which source produces a need, its lane, its onset, its verb and the
// incident key that groups it. Foundation-only, like the overview glances:
// the contract harness (tools/test-foundation.sh) ranks, folds and ledgers
// these values without the app; views only draw them.

/// A need's urgency class — the Now Line's four lanes, most urgent first.
enum NowLane: String, CaseIterable, Codable, Comparable, Sendable {
    case onFire, waitingOnYou, due, drifting

    var order: Int {
        switch self {
        case .onFire: 0
        case .waitingOnYou: 1
        case .due: 2
        case .drifting: 3
        }
    }

    static func < (lhs: NowLane, rhs: NowLane) -> Bool { lhs.order < rhs.order }
}

/// How bad a need is inside its lane, most severe first. Each adapter maps
/// its source's typed severity onto this — unrelated raw priorities are
/// never compared.
enum NowSeverity: String, CaseIterable, Codable, Comparable, Sendable {
    case emergency, critical, warning, normal

    var order: Int {
        switch self {
        case .emergency: 0
        case .critical: 1
        case .warning: 2
        case .normal: 3
        }
    }

    /// Critical and emergency needs never fold (D15): a bad morning may
    /// compress, but nothing critical hides behind a count.
    var mayFold: Bool { self == .warning || self == .normal }

    static func < (lhs: NowSeverity, rhs: NowSeverity) -> Bool { lhs.order < rhs.order }
}

/// When a need began — always labelled, never fabricated. A bar starts at
/// need onset (check failing, review requested, expiry window entered), never
/// at `updatedAt` or `lastSeen`.
enum NowOnset: Codable, Hashable, Sendable {
    /// The source's own instant for this need: `activeAt`, `since`,
    /// `ripeAt`, `updatedAt + 7 d`.
    case exact(Date)
    /// The object's lifetime start, not this need's (Sentry `firstSeen`).
    /// Labelled "first seen"; it never pulls an incident's bar earlier than a
    /// sibling with a real onset.
    case firstSeen(Date)
    /// The source has no onset: Pultík's first observation, drawn hollow and
    /// labelled "observed". `ObservationLedger` keeps it across relaunches.
    case observed(Date)

    var date: Date {
        switch self {
        case let .exact(date), let .firstSeen(date), let .observed(date): date
        }
    }

    var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }

    var isFirstSeen: Bool {
        if case .firstSeen = self { return true }
        return false
    }
}

/// What a need is — the unit D15 folds by ("+3 sessions waiting").
enum NowKind: String, CaseIterable, Codable, Sendable {
    /// A Hlídač deployment verdict or failing check.
    case deployment
    /// Hlídač, one of its sources, or a deployment cannot be judged.
    case monitoringBlind
    case sentryIssue
    case firingAlert
    case eveNotification
    case eveApproval
    case sessionWaiting
    /// A failing check or run on the operator's own PR.
    case failedCheck
    case reviewRequested
    case stalePR
    /// A ripe vitrinka todo — reminder, recurring schedule, lead window.
    case reminder
    /// A vitrinka task past its due date (the Work feed).
    case overdueTask
    case staleWorkspace
    case macFinding
    case expiry
}

/// The object ↵ opens: its module and the id that module selects by
/// (`ModuleObject.id`). `url` is the real page ⌘↵ opens in the browser (D7),
/// when one exists.
struct NowTarget: Codable, Hashable, Sendable {
    let module: PanelModule
    let objectID: String
    var url: String? = nil
}

/// The one verb a need offers. ↵ only ever opens; a verb that acts carries
/// its own shortcut, and a destructive one confirms and revalidates the
/// object's fingerprint first.
struct NowVerb: Codable, Hashable, Sendable {
    let title: String
    /// The key hint drawn beside it ("↵", "⌘R"); nil until one is decided.
    let shortcut: String?
    let destructive: Bool

    init(title: String, shortcut: String? = nil, destructive: Bool = false) {
        self.title = title
        self.shortcut = shortcut
        self.destructive = destructive
    }

    /// A navigation verb: ↵ opens the object's detail and never mutates.
    static func open(_ title: String) -> NowVerb { NowVerb(title: title, shortcut: "↵") }
}

/// Who waits, inside the waiting-on-you lane only: an agent or eve request
/// blocked on you outranks your own failed CI, which outranks a review
/// someone asked for (contract assumption, data.md's order).
enum NowWaiterRank: String, CaseIterable, Codable, Comparable, Sendable {
    case blockedRequest, ownFailure, reviewRequest, other

    var order: Int {
        switch self {
        case .blockedRequest: 0
        case .ownFailure: 1
        case .reviewRequest: 2
        case .other: 3
        }
    }

    static func < (lhs: NowWaiterRank, rhs: NowWaiterRank) -> Bool { lhs.order < rhs.order }
}

/// One need: a source object's occurrence that asks for the operator.
/// Three identities, never confused: `needID` is the object + occurrence,
/// `incidentKey` the row it presents under, `episodeID` one continuous
/// active spell (stamped by `ObservationLedger`). Every key is namespaced by
/// backend origin and identity — never correlated by title text.
struct NowNeed: Codable, Hashable, Identifiable, Sendable {
    let needID: String
    let incidentKey: String
    var episodeID: String
    let kind: NowKind
    let lane: NowLane
    let severity: NowSeverity
    var onset: NowOnset
    let title: String
    let subtitle: String?
    /// The short id a row shows: `#412`, `FIX-1365`, `EXAMPLEAPP-API-9Q`.
    let displayID: String?
    let verb: NowVerb
    let target: NowTarget
    /// A due item's deadline — a marker in the future gutter, never a bar.
    let deadline: Date?
    /// Order inside the waiting-on-you lane; ignored in the other lanes.
    let waiterRank: NowWaiterRank
    /// The ×N identity (D15): needs of one kind sharing it in one lane read
    /// as one problem — the same check failing on several PRs of a repo, or
    /// reminders due at the same instant. Nil = never part of a ×N row.
    let seriesKey: String?

    var id: String { needID }

    init(needID: String, incidentKey: String, episodeID: String? = nil, kind: NowKind, lane: NowLane,
         severity: NowSeverity, onset: NowOnset, title: String, subtitle: String? = nil,
         displayID: String? = nil, verb: NowVerb, target: NowTarget, deadline: Date? = nil,
         waiterRank: NowWaiterRank = .other, seriesKey: String? = nil) {
        self.needID = needID
        self.incidentKey = incidentKey
        self.episodeID = episodeID ?? needID
        self.kind = kind
        self.lane = lane
        self.severity = severity
        self.onset = onset
        self.title = title
        self.subtitle = subtitle
        self.displayID = displayID
        self.verb = verb
        self.target = target
        self.deadline = deadline
        self.waiterRank = waiterRank
        self.seriesKey = seriesKey
    }

    /// The Now rank: lane → severity → waiter (waiting lane only) → oldest
    /// onset → stable id. Unknown onsets sort by their labelled
    /// first-observed time, never an invented epoch; a lifetime `firstSeen`
    /// is context, so a sibling with a real onset leads before it.
    static func ranksBefore(_ lhs: NowNeed, _ rhs: NowNeed) -> Bool {
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.lane == .waitingOnYou, lhs.waiterRank != rhs.waiterRank { return lhs.waiterRank < rhs.waiterRank }
        if lhs.onset.isFirstSeen != rhs.onset.isFirstSeen { return rhs.onset.isFirstSeen }
        if lhs.onset.date != rhs.onset.date { return lhs.onset.date < rhs.onset.date }
        return lhs.needID < rhs.needID
    }
}

/// One Now row's worth of evidence: the active needs sharing an incident
/// key. Grouping is presentation only — it never asserts a common cause.
struct NowIncident: Equatable, Identifiable, Sendable {
    let key: String
    /// Active children, most urgent first; every one stays reachable in detail.
    let needs: [NowNeed]
    /// The highest active child's lane.
    let lane: NowLane
    /// The most severe active child's severity.
    let severity: NowSeverity
    /// The best waiter among the children in the incident's lane.
    let waiterRank: NowWaiterRank
    /// Where the bar starts: the earliest ACTIVE child onset. A lifetime
    /// `firstSeen` counts only when no child has a real onset, so an old
    /// Sentry issue never backdates a deployment's verdict.
    let onset: NowOnset
    /// The earliest child deadline, if any.
    let deadline: Date?

    var id: String { key }
    /// The child the row speaks for: title, verb and target.
    var lead: NowNeed { needs[0] }
    var kind: NowKind { lead.kind }
    /// Raw evidence behind the row ("3 needs, one deployment").
    var evidence: Int { needs.count }

    /// Nil for an empty child list — an incident is never hollow.
    init?(key: String, needs: [NowNeed]) {
        let ranked = needs.sorted(by: NowNeed.ranksBefore)
        guard let lead = ranked.first else { return nil }
        self.key = key
        self.needs = ranked
        lane = lead.lane
        severity = ranked.map(\.severity).min() ?? lead.severity
        waiterRank = ranked.filter { $0.lane == lead.lane }.map(\.waiterRank).min() ?? lead.waiterRank
        let real = ranked.filter { !$0.onset.isFirstSeen }
        // Earliest wins; on a tie the source's own instant beats an observed one.
        onset = (real.isEmpty ? ranked : real).map(\.onset).min { a, b in
            a.date != b.date ? a.date < b.date : (!a.isObserved && b.isObserved)
        } ?? lead.onset
        deadline = ranked.compactMap(\.deadline).min()
    }

    /// The same rank as `NowNeed.ranksBefore`, over the grouped values.
    static func ranksBefore(_ lhs: NowIncident, _ rhs: NowIncident) -> Bool {
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.lane == .waitingOnYou, lhs.waiterRank != rhs.waiterRank { return lhs.waiterRank < rhs.waiterRank }
        if lhs.onset.date != rhs.onset.date { return lhs.onset.date < rhs.onset.date }
        return lhs.key < rhs.key
    }
}

/// How much of its source one read saw. Only a complete, successful read
/// may finish a need; a failed, stale, truncated or unauthorized read never
/// clears anything, and a hidden backend is missing coverage, never zero.
enum NowCoverage: String, Codable, Sendable {
    case complete, partial, failed
}

/// The adapter a read came from.
enum NowFeed: String, Codable, Sendable {
    case hlidacBlindness, hlidacSentry, estateAlerts, eveNotifications, githubStalePRs,
         vitrinkaTodos, devboxStale, macHealth, expiryRadar, fleetSessions, eveApprovals

    /// How far back the feed looks, by onset: a need older than this left
    /// its view without resolving (eve's notifications past Now's window),
    /// so it leaves the screen — on a read, a summon or a relaunch —
    /// unhandled. Nil = no horizon.
    var horizon: TimeInterval? {
        self == .eveNotifications ? NowAxis.window : nil
    }
}

/// Whose view a read is. `identity` carries the origin plus the account,
/// workspace or machine, so one identity's needs never resurface — or
/// clear — under another's.
struct NowSource: Codable, Hashable, Sendable {
    let feed: NowFeed
    let identity: String

    var key: String { "\(feed.rawValue):\(identity)" }
}

/// One adapter pass over one source: its needs and how much it saw.
/// Adapters read fresh answers only — a cached snapshot is not a read, so
/// pass the adapter nil (→ `.failed`) and keep serving the last good needs.
struct NowRead: Equatable, Sendable {
    let source: NowSource
    let coverage: NowCoverage
    let needs: [NowNeed]
    /// Terminal instants the source reported for needs it no longer lists
    /// (an eve `action.result`, a GitHub completion): the Handled section
    /// prefers them to the poll that saw the need gone.
    var finished: [String: Date] = [:]
}
