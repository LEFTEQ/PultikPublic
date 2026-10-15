import Foundation

// The `.h` overview matrix and the eve accounts table (decision D4 B, the
// D5 eve page evidence). Foundation-only like ProdGlance: the contract
// harness tests the column mapping without the app. Columns are derived
// from check ids, never from a deployment's key — a new deployment lands
// in the right columns by naming its checks the way the contract does.

enum ProdMatrix {
    enum Column: String, CaseIterable, Identifiable {
        case probe, app, pool, logs, sentry, firing, backup
        var id: String { rawValue }

        var title: String {
            switch self {
            case .probe: "Probe"
            case .app: "App"
            case .pool: "Queues/pool"
            case .logs: "Logs 24h"
            case .sentry: "Sentry"
            case .firing: "Firing"
            case .backup: "Backup"
            }
        }

        /// How many check values a column joins before it truncates.
        fileprivate var valueLimit: Int {
            switch self {
            case .app, .pool: 2
            default: 1
            }
        }
    }

    /// One matrix cell: a dot (nil = none drawn) and a short mono value
    /// (nil = the em-dash of "nothing here").
    struct Cell: Equatable {
        let tone: ProdGlance.Tone?
        let text: String?
        /// The value reads red/orange on its own (log errors, crit counts).
        var textTone: ProdGlance.Tone?
        /// Last-known text while Hlídač is unreachable: drawn tertiary.
        var dimmed = false

        /// The same value, blind: tone .blind, no colour of its own, dimmed.
        var blinded: Cell {
            Cell(tone: tone == nil ? nil : .blind, text: text, textTone: nil, dimmed: true)
        }

        static let empty = Cell(tone: nil, text: nil)
    }

    struct Row: Equatable, Identifiable {
        let key: String
        let title: String
        /// "api.example.invalid" / "assistant-service · exampleapp-prod" — the card's host line.
        let subtitle: String?
        let tone: ProdGlance.Tone
        let cells: [Column: Cell]
        var id: String { key }

        /// The row in words, for its accessible label — everything the
        /// collapsed row shows: "ExampleApp prod, ok; Probe 182ms; Sentry 1 new,
        /// alert; …". Empty cells are left out.
        var spoken: String {
            let head = [title + ", " + tone.spoken, subtitle].compactMap { $0 }.joined(separator: ", ")
            let parts = Column.allCases.compactMap { column -> String? in
                guard let cell = cells[column], cell.tone != nil || cell.text != nil else { return nil }
                let state: String? = switch cell.tone {
                case .red: "alert"
                case .orange: "warning"
                case .blind: "no data"
                case .hollow: "not monitored"
                case .green, nil: nil
                }
                return [column.title + (cell.text.map { " " + $0 } ?? ""), state].compactMap { $0 }
                    .joined(separator: ", ")
            }
            return ([head] + parts).joined(separator: "; ")
        }
    }

    /// The check-id families each column reads. A check id not named here
    /// falls into `.app`, so nothing a deployment reports is ever dropped.
    static func column(forCheck id: String) -> Column {
        let id = id.lowercased()
        if id.contains("backup") { return .backup }
        if id.contains("pool") || id.contains("queue") || ["scheduler", "failed-work"].contains(id) {
            return .pool
        }
        if ["api", "web", "app", "canary", "p99", "edge5xx", "up"].contains(id) || id.contains("probe") {
            return .probe
        }
        return .app
    }

    static func rows(_ glance: ProdGlance) -> [Row] {
        glance.cards.map { card in
            let drawn = card.deployment.map(Self.cells) ?? [:]
            return Row(key: card.key, title: card.title, subtitle: subtitle(card), tone: card.tone,
                       cells: card.stale ? drawn.mapValues(\.blinded) : drawn)
        }
    }

    /// The deployment `.h <filter>` expands: a key prefix first ("eve" →
    /// eve-exampleapp-prod), then any key or title containing it ("sk" →
    /// booking-sk). Nil for an empty filter or no match.
    static func expandedKey(filter: String, rows: [(key: String, title: String)]) -> String? {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        return rows.first { $0.key.lowercased().hasPrefix(text) }?.key
            ?? rows.first { $0.key.lowercased().contains(text) || $0.title.lowercased().contains(text) }?.key
    }

    /// "1 crit · 2 warn" for the page heading's pills.
    static func severityCounts(_ glance: ProdGlance) -> (critical: Int, warning: Int) {
        (glance.cards.filter { $0.tone == .red }.count, glance.cards.filter { $0.tone == .orange }.count)
    }

    /// The card's status line when it has one ("blind since 14:02", "not
    /// monitored"), else "project · tier".
    private static func subtitle(_ card: ProdGlance.Card) -> String? {
        card.status ?? [card.deployment?.project, card.tier].compactMap { $0 }.joined(separator: " · ")
    }

    static func cells(_ deployment: HlidacDigest.Deployment) -> [Column: Cell] {
        var cells: [Column: Cell] = [:]
        let grouped = Dictionary(grouping: deployment.checks, by: { column(forCheck: $0.id) })
        for column in [Column.probe, .app, .pool, .backup] {
            guard let checks = grouped[column], !checks.isEmpty else { continue }
            let tone = checks.map { chipTone($0.status) }.max(by: { rank($0) < rank($1) })
            // A column that is not healthy leads with what is wrong; a healthy
            // one shows its first values in the order Hlídač sent them.
            let ordered = tone == .green ? checks : checks.sorted { rank(chipTone($0.status)) > rank(chipTone($1.status)) }
            let values = ordered.compactMap(\.value).prefix(column.valueLimit).map(compact)
            cells[column] = Cell(tone: tone, text: values.isEmpty ? nil : values.joined(separator: "·"))
        }
        cells[.logs] = logsCell(deployment)
        cells[.sentry] = sentryCell(deployment.sentry)
        cells[.firing] = firingCell(deployment.alerts)
        return cells
    }

    /// A matrix cell is a glance, never an ellipsis: "182 ms" → "182ms",
    /// "4.1 s · 3m" → "4.1s·3m". The card and the expanded row keep
    /// Hlídač's own spelling.
    static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: " · ", with: "·")
            .replacingOccurrences(of: #"(\d) (ms|s|m|h|d)\b"#, with: "$1$2", options: .regularExpression)
    }

    private static func logsCell(_ deployment: HlidacDigest.Deployment) -> Cell {
        guard let today = deployment.logs.today else {
            return Cell(tone: nil, text: deployment.verdict == .unmonitored ? "not shipped" : nil)
        }
        return Cell(tone: nil, text: "\(today.error)·\(today.warn)",
                    textTone: today.error > 0 ? .red : nil)
    }

    private static func sentryCell(_ issues: [HlidacDigest.Issue]) -> Cell {
        guard let top = issues.first(where: \.isNew) ?? issues.first else { return .empty }
        let fresh = issues.filter(\.isNew).count
        if fresh > 0 { return Cell(tone: .red, text: "\(fresh) new") }
        return Cell(tone: .orange, text: "\(issues.count)·\(top.count)×")
    }

    private static func firingCell(_ alerts: [HlidacDigest.Alert]) -> Cell {
        let critical = alerts.filter(\.isCritical).count
        if critical > 0 { return Cell(tone: .red, text: "\(critical) crit", textTone: .red) }
        if !alerts.isEmpty { return Cell(tone: .orange, text: "\(alerts.count) warn", textTone: .orange) }
        return .empty
    }

    private static func chipTone(_ status: Double?) -> ProdGlance.Tone {
        switch status {
        case .none: .blind
        case let .some(value) where value >= 1: .green
        case let .some(value) where value > 0: .orange
        default: .red
        }
    }

    /// Worse is larger: red beats orange beats blind beats green.
    private static func rank(_ tone: ProdGlance.Tone?) -> Int {
        switch tone {
        case .red: 4
        case .orange: 3
        case .blind: 2
        case .hollow: 1
        case .green, .none: 0
        }
    }
}

// MARK: - eve accounts

/// One row of the eve accounts table, formatted for the matrix's expanded
/// eve row: state, the binding windows, cooldown countdown, freshness.
struct ProdAccountRow: Equatable, Identifiable {
    /// "anthropic/claude-1" — unique across gateways, which may reuse names.
    let id: String
    /// "claude-1" — what the table shows.
    let account: String
    /// "Claude" / "Codex"
    let pool: String
    let state: String
    private(set) var tone: ProdGlance.Tone
    let fiveHour: Double?
    let sevenDay: Double?
    /// What is left of the Fable weekly window (anthropic only), 0…1.
    let fableLeftRatio: Double?
    /// "back 21:14" while cooling; nil otherwise.
    let cooldownAt: String?
    /// "33m" — the countdown to `cooldownAt`.
    let cooldownIn: String?

    /// "38%"
    var fableLeft: String? {
        fableLeftRatio.map { "\(Int(($0 * 100).rounded()))%" }
    }

    /// "back 21:14 · 33m" — one line, for help text and tests; the table
    /// draws the two halves on two lines.
    var cooldown: String? {
        cooldownAt.map { [$0, cooldownIn].compactMap { $0 }.joined(separator: " · ") }
    }
    /// When the window closest to its limit resets: "21:14" today, else
    /// "1d 4h" — complete and short (`resetText`).
    let resets: String?
    /// The same moment as a clock, for the tooltip: "Fri 14:00".
    let resetsAt: String?
    let turns24h: Int
    /// "6m" — how old the window numbers are.
    let asOf: String?
    /// Logged out, numbers older than an hour, or a stale card: drawn dimmed.
    private(set) var stale: Bool

    /// A window bar crosses this and gets the orange tick.
    static let tick = 0.9
    /// Older usage numbers than this are dimmed rather than trusted.
    static let staleAfter: TimeInterval = 3600

    /// - blind: the card is stale (Hlídač not answering) — every row reads
    ///   blind and dimmed, whatever the cached numbers say.
    static func rows(_ pool: HlidacDigest.Pool, now: Date, timeZone: TimeZone = .current,
                     blind: Bool = false) -> [ProdAccountRow] {
        pool.pools.flatMap { gateway in
            gateway.accounts.map { account in
                var row = row(account, gateway: gateway.gateway, now: now, timeZone: timeZone)
                if blind { row.tone = .blind; row.stale = true }
                return row
            }
        }
    }

    /// A gateway's lane dot: red with no usable account, orange short of
    /// all, green when all are usable — blind while the card is stale.
    static func laneTone(usable: Int, total: Int, blind: Bool) -> ProdGlance.Tone {
        if blind { return .blind }
        return usable == 0 ? .red : usable < total ? .orange : .green
    }

    static func row(_ account: HlidacDigest.Account, gateway: String, now: Date,
                    timeZone: TimeZone = .current) -> ProdAccountRow {
        let windows = Dictionary(account.windows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let cooling = account.cooldownUntil.flatMap { $0 > now ? $0 : nil }
        let binding = account.windows.filter { $0.resetsAt != nil }.max { $0.usedRatio < $1.usedRatio }
        let observed = account.observedAt
        return ProdAccountRow(
            id: "\(gateway)/\(account.id)",
            account: account.id,
            pool: poolName(gateway),
            state: account.state.replacingOccurrences(of: "_", with: " "),
            tone: stateTone(account.state),
            fiveHour: windows["five_hour"]?.usedRatio,
            sevenDay: windows["seven_day"]?.usedRatio,
            fableLeftRatio: windows["fable_weekly"].map { min(max(1 - $0.usedRatio, 0), 1) },
            cooldownAt: cooling.map { "back \(clock($0, now: now, timeZone: timeZone))" },
            cooldownIn: cooling.map { countdown(from: now, to: $0) },
            resets: binding?.resetsAt.map { resetText($0, now: now, timeZone: timeZone) },
            resetsAt: binding?.resetsAt.map { clock($0, now: now, timeZone: timeZone) },
            turns24h: account.turns24h,
            asOf: observed.map { $0.shortAge(relativeTo: now) },
            stale: account.state == "logged_out" || observed.map { now.timeIntervalSince($0) > staleAfter } ?? true)
    }

    static func poolName(_ gateway: String) -> String {
        switch gateway {
        case "anthropic": "Claude"
        case "codex": "Codex"
        default: gateway.capitalized
        }
    }

    static func stateTone(_ state: String) -> ProdGlance.Tone {
        switch state {
        case "usable": .green
        case "cooling": .orange
        case "benched", "logged_out": .red
        default: .blind
        }
    }

    /// "33m", "1h 5m" — whole minutes until `end`, never negative.
    static func countdown(from now: Date, to end: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// A reset as the accounts table shows it, always complete and short:
    /// later today → "21:14"; otherwise how far off it is → "1d 4h", "6d"
    /// (weekly windows never reach past a week). The weekday form is the
    /// tooltip's (`clock`).
    static func resetText(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, now: now, timeZone: timeZone) }
        let hours = max(0, Int((date.timeIntervalSince(now) / 3600).rounded()))
        guard hours >= 24 else { return "\(hours)h" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// Same day → "21:14"; within a week → "Fri 14:00"; later → "9 Oct".
    static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if date.timeIntervalSince(now) < 6 * 86400 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }
}

extension HlidacDigest.Pool {
    /// The eve card's pools line: "Claude 1/2 · Codex 2/4 · canary 3m".
    func summary(now: Date) -> String {
        var parts = pools.map { "\(ProdAccountRow.poolName($0.gateway)) \($0.usable)/\($0.total)" }
        if let canary {
            if canary.consecutiveFailures > 0 {
                parts.append("canary ✕\(canary.consecutiveFailures)")
            } else if let success = canary.lastSuccess {
                parts.append("canary \(success.shortAge(relativeTo: now))")
            }
        }
        return parts.joined(separator: " · ")
    }
}
