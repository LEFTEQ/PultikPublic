import AppKit
import Foundation
import Observation

/// One `todo`-type task from the vitrinka task engine (2026-09-05: the
/// Obsidian vault became read-only history; `vitrinka todo|schedule` is the
/// writer and this app only reads).
///
/// Decoded straight off `GET /api/v1/tasks` and the `task` half of
/// `GET /api/v1/me/ripe`; the two mutable fields are stamped by the store from
/// the ripe entry's siblings.
struct TodoItem: Identifiable, Decodable {
    let id: Int64
    let project: String
    let title: String
    /// todo | in_progress | done | cancelled — the engine's vocabulary.
    let status: String
    /// The scheduled moment — the deadline itself, not the reminder. A
    /// whole-day `due` lands here too (the importer's morning stamp).
    let dueAt: Date?
    /// low | medium | high. The vault said `normal`; the panel keeps painting
    /// medium as the quiet default.
    let priority: String
    let milestoneId: Int64?
    let createdAt: Date?
    /// The `moment` preset values that matter to the panel: `lead` and
    /// `every` (duration grammar `30m 4h 3d 2w`), `trigger` (free text the
    /// model judges), and whether a `context` companion exists.
    let lead: TimeInterval?
    let every: String?
    let trigger: String?
    let hasContext: Bool

    /// From `/me/ripe` only: overdue | due | milestone.
    var reason: String?
    var milestoneName: String?

    private enum CodingKeys: String, CodingKey {
        case id, project, title, status, dueAt, priority, milestoneId, createdAt, fields
    }

    private enum FieldKeys: String, CodingKey {
        case lead, every, trigger, context
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        project = try c.decode(String.self, forKey: .project)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "todo"
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt).flatMap(Self.date)
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        milestoneId = try c.decodeIfPresent(Int64.self, forKey: .milestoneId)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(Self.date)
        // Custom-field values are typed JSON; only the string kinds matter
        // here and a non-string (a select id, a number) must not sink the row.
        if let f = try? c.nestedContainer(keyedBy: FieldKeys.self, forKey: .fields) {
            lead = (try? f.decodeIfPresent(String.self, forKey: .lead)).flatMap { $0 }.flatMap(TodoDuration.parse)
            every = (try? f.decodeIfPresent(String.self, forKey: .every)).flatMap { $0 }
            trigger = (try? f.decodeIfPresent(String.self, forKey: .trigger)).flatMap { $0 }
            let context = (try? f.decodeIfPresent(String.self, forKey: .context)).flatMap { $0 }
            hasContext = !(context ?? "").isEmpty
        } else {
            lead = nil
            every = nil
            trigger = nil
            hasContext = false
        }
    }

    /// Hand-built rows (tests, previews).
    init(id: Int64, project: String, title: String, status: String = "todo", dueAt: Date? = nil,
         priority: String = "medium", milestoneId: Int64? = nil, createdAt: Date? = nil,
         lead: TimeInterval? = nil, every: String? = nil, trigger: String? = nil,
         hasContext: Bool = false, reason: String? = nil, milestoneName: String? = nil) {
        self.id = id
        self.project = project
        self.title = title
        self.status = status
        self.dueAt = dueAt
        self.priority = priority
        self.milestoneId = milestoneId
        self.createdAt = createdAt
        self.lead = lead
        self.every = every
        self.trigger = trigger
        self.hasContext = hasContext
        self.reason = reason
        self.milestoneName = milestoneName
    }

    /// The server writes RFC 3339 with or without fractional seconds.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    /// The panel's row identity and the name every surface shows.
    var name: String { title }
    var isOpen: Bool { status != "done" && status != "cancelled" }
    var isScheduled: Bool { dueAt != nil }
    var at: Date? { dueAt }

    static let defaultLead: TimeInterval = 2 * 3600

    /// The moment it starts asking for attention.
    var ripeAt: Date? { dueAt?.addingTimeInterval(-(lead ?? Self.defaultLead)) }
    /// Inside the lead window — or waiting on a milestone the server says was
    /// reached, which has no clock of its own.
    func isRipe(_ now: Date = .now) -> Bool {
        if reason == "milestone" { return true }
        return ripeAt.map { now >= $0 } ?? false
    }
    func isOverdue(_ now: Date = .now) -> Bool { dueAt.map { now >= $0 } ?? false }

    /// Identity of one occurrence. A recurring todo keeps its id and rolls
    /// `dueAt` forward, so the notification stamp is keyed by id AND moment —
    /// the next occurrence is automatically a fresh thing to be told about.
    var occurrenceKey: String {
        "\(id)@\(dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? (reason == "milestone" ? "milestone" : "-"))"
    }

    /// "in 4h" / "3d ago" — the gap, the way every surface says it.
    func gap(_ now: Date = .now) -> String? {
        guard let at = dueAt else { return nil }
        let delta = abs(at.timeIntervalSince(now))
        let text: String
        switch delta {
        case ..<60: return "now"
        case ..<3600: text = "\(Int(delta / 60))m"
        case ..<(48 * 3600): text = "\(Int(delta / 3600))h"
        default: text = "\(Int(delta / 86400))d"
        }
        return at < now ? "\(text) ago" : "in \(text)"
    }

    /// The "when" line the panel and the notification both show.
    var when: String? {
        if let at = dueAt {
            var line = isOverdue()
                ? "OVERDUE \((gap() ?? "").replacingOccurrences(of: " ago", with: ""))"
                : gap() ?? ""
            line += " · \(at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            if let every { line += " ↻\(every)" }
            return line
        }
        if let milestoneName { return "milestone: \(milestoneName)" }
        if milestoneId != nil { return "milestone" }
        return trigger
    }

    /// Where a click lands: the task panel on its project page.
    var url: URL { VitrinkaClient.shared.taskURL(project: project, id: id) }

    @MainActor
    func open() { NSWorkspace.shared.open(url) }
}

/// Durations use the engine's grammar (`30m 4h 3d 2w 90d 1y`, compoundable).
/// Only `lead` is read here — `every` stays a display string.
enum TodoDuration {
    static func parse(_ raw: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = [
            "m": 60, "h": 3600, "d": 86400, "w": 604_800, "y": 31_536_000,
        ]
        var total: TimeInterval = 0
        var digits = ""
        for ch in raw {
            if ch.isNumber {
                digits.append(ch)
            } else if let unit = units[ch], let n = Double(digits) {
                total += n * unit
                digits = ""
            } else {
                return nil
            }
        }
        return digits.isEmpty && total > 0 ? total : nil
    }
}

/// The panel's read of the vitrinka todo engine.
///
/// Polled through `StatusStore.refreshVitrinka()` inside the vitrinka circuit
/// breaker — one host, one credential, one `ProbeTarget` — so an off-mesh
/// laptop backs off exactly as it does for the listener rail, and every
/// surface this feeds HIDES (rail, section, badge) rather than alerting. The
/// 60 s ripeness clock and the wake observer stay: a deadline arriving is a
/// clock event, not a server event.
@MainActor
@Observable
final class TodoStore {
    static let shared = TodoStore()

    /// Open todos across every project, as the last successful poll saw them.
    private(set) var todos: [TodoItem] = []
    /// The server's ripe list — the only source for milestone ripeness.
    private(set) var ripeNow: [TodoItem] = []
    /// False until the first successful poll and after any failure — the
    /// difference between "no todos" and "cannot see the todos".
    private(set) var isReachable = false

    /// Re-renders the menu bar icon; @Observable only reaches SwiftUI views.
    var onChange: (() -> Void)?

    private var ripenessTimer: Timer?
    /// Ids seen since launch — the diff basis for "notify on new".
    private var knownIDs: Set<Int64>?

    private init() {
        loadNotified()
        startRipenessClock()
    }

    /// Open todos, highest priority first, then oldest first — the panel's
    /// order. Sorting by created (not due) keeps the list stable; ripeness is
    /// a judgment the AI makes, not something a sort can express.
    var openTodos: [TodoItem] {
        let rank = ["high": 0, "medium": 1, "normal": 1, "low": 2]
        return todos.filter(\.isOpen).sorted { lhs, rhs in
            let (l, r) = (rank[lhs.priority] ?? 1, rank[rhs.priority] ?? 1)
            if l != r { return l < r }
            return (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }
    }

    /// The agenda: open scheduled todos, soonest first. Time order, not
    /// priority order — a schedule is read forwards.
    var scheduledTodos: [TodoItem] {
        todos.filter { $0.isOpen && $0.isScheduled }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    /// What the Reminders rail and the ripeness notifier look at: every
    /// scheduled todo (the clock decides locally between polls) plus the
    /// milestone-ripe ones only the server can know about.
    var reminderCandidates: [TodoItem] {
        Self.mergeReminderCandidates(scheduled: scheduledTodos, ripe: ripeNow)
    }

    /// `/me/ripe` is authoritative for ripeness and is never capped, so EVERY
    /// ripe row surfaces: a scheduled row the server also lists as ripe takes
    /// the server's verdict (`reason`, `milestoneName` — a future `dueAt`
    /// with a reached milestone is ripe now, not at its lead window), and
    /// ripe rows the open list does not carry — milestone-only todos with no
    /// `dueAt`, or due/overdue ones past the open list's page cap — are
    /// appended as the server sent them (a ripe entry is a whole task).
    static func mergeReminderCandidates(scheduled: [TodoItem], ripe: [TodoItem]) -> [TodoItem] {
        let verdicts = Dictionary(ripe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = scheduled.map { row -> TodoItem in
            guard let verdict = verdicts[row.id] else { return row }
            var merged = row
            merged.reason = verdict.reason
            merged.milestoneName = verdict.milestoneName
            return merged
        }
        var seen = Set(scheduled.map(\.id))
        for row in ripe where seen.insert(row.id).inserted { out.append(row) }
        return out
    }

    /// Anything past its `dueAt` and still open. Drives the badge escalation.
    var overdueCount: Int { scheduledTodos.filter { $0.isOverdue() }.count }
    var ripeCount: Int { reminderCandidates.filter { $0.isRipe() }.count }

    // MARK: - Polling

    /// One poll: ripe first (one request, the breaker's verdict), then the
    /// open list. Called by `StatusStore` inside `gated(.vitrinka)`; the
    /// returned failure is what the breaker backs off on.
    func refresh(using client: VitrinkaClient) async -> ProbeFailure? {
        let ripe: [TodoItem]
        switch await client.ripe() {
        case .failed(let failure):
            markUnreachable()
            return failure
        case .value(let items):
            ripe = items
        }
        switch await client.openTodos() {
        case .failed(let failure):
            markUnreachable()
            return failure
        case .value(let items):
            ripeNow = ripe
            notifyNewTodos(items)
            todos = items
            isReachable = true
            checkRipeness()
            onChange?()
            return nil
        }
    }

    /// Off the mesh, signed out, or refused: every todo surface folds. Not a
    /// modal, not an alert — the laptop is often away from the network.
    func markUnreachable() {
        guard isReachable || !todos.isEmpty || !ripeNow.isEmpty else { return }
        isReachable = false
        todos = []
        ripeNow = []
        onChange?()
    }

    /// Fires a user notification per open todo that wasn't there before.
    /// First poll establishes the baseline silently — relaunching the app
    /// must not replay the whole engine as "new".
    private func notifyNewTodos(_ fresh: [TodoItem]) {
        defer { knownIDs = Set(fresh.map(\.id)) }
        guard let known = knownIDs else { return }
        for todo in fresh where todo.isOpen && !known.contains(todo.id) {
            Notifier.send(
                title: "Todo: \(todo.name)",
                body: todo.when ?? todo.project,
                url: todo.url.absoluteString
            )
            // A brand-new todo that is already ripe was just announced above;
            // stamping it here stops checkRipeness firing a second time for
            // the same thing one second later.
            if todo.isRipe() { notifiedOccurrences.insert(todo.occurrenceKey) }
        }
    }

    // MARK: - Ripeness

    /// Occurrence keys already notified. Persisted, because the whole point
    /// is surviving a relaunch: a reminder that fired into a sleeping Mac
    /// must still arrive, and one that already arrived must not repeat.
    private var notifiedOccurrences: Set<String> = []

    /// Beside settings.json — the app's state directory. (The CLI's own
    /// announce ledger is `~/.config/vitrinka/schedule-claims.json`; the
    /// session hook and this panel announce independently, by design.)
    private static let notifiedURL = Preferences.directory.appending(path: "notified.json")

    private func loadNotified() {
        guard let data = try? Data(contentsOf: Self.notifiedURL),
              let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        notifiedOccurrences = Set(keys)
    }

    private func saveNotified() {
        let dir = Self.notifiedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(notifiedOccurrences)) else { return }
        try? data.write(to: Self.notifiedURL, options: .atomic)
    }

    /// Notifies for anything ripe that has not been announced yet.
    ///
    /// This is the catch-up: it runs after every poll, on wake and on a
    /// one-minute tick, so a reminder whose moment passed while the Mac was
    /// asleep still lands — late, but never silently lost.
    func checkRipeness() {
        let candidates = reminderCandidates
        let ripe = candidates.filter { $0.isRipe() }
        var fired = false
        for todo in ripe where !notifiedOccurrences.contains(todo.occurrenceKey) {
            let late = todo.isOverdue() ? "OVERDUE" : "ripe"
            Notifier.send(
                title: "\(late): \(todo.name)",
                body: todo.when ?? todo.project,
                url: todo.url.absoluteString
            )
            notifiedOccurrences.insert(todo.occurrenceKey)
            fired = true
        }
        // Forget occurrences that are gone (done, dropped, advanced) so the
        // stamp file can't grow forever — but only on the strength of a
        // successful poll; an empty list because we are off the mesh must not
        // erase the ledger and replay everything on reconnect.
        if isReachable {
            let live = Set(candidates.map(\.occurrenceKey))
            let pruned = notifiedOccurrences.intersection(live)
            if pruned != notifiedOccurrences {
                notifiedOccurrences = pruned
                fired = true
            }
        }
        if fired { saveNotified() }
    }

    /// A ripeness moment is a clock event, not a server event — nothing on
    /// the server changes when a deadline arrives, so it needs its own tick.
    /// One minute is far below the coarsest thing shown ("in 4h") and costs
    /// nothing; wake is observed separately because timers don't fire while
    /// the machine is asleep, and a wake also asks the poller for a fresh
    /// read (the breaker decides whether it actually goes out).
    private func startRipenessClock() {
        ripenessTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkRipeness()
                self?.onChange?()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkRipeness()
                await StatusStore.shared.refreshIfStale()
            }
        }
    }
}
