import Foundation

// Prod watch (docs/specs/2026-10-02-prod-watch-brief.md): Hlídač's digest
// and the prod board's glance over it. Foundation-only — the contract harness
// (tools/test-foundation.sh) decodes the golden fixture through these types.
// Verdicts are Hlídač's; this file only formats them and never derives
// health on its own (decision D14).

/// `GET /api/v1/prod` — the shape pinned in
/// docs/specs/2026-10-03-prod-watch-contracts.md §5.
struct HlidacDigest: Decodable, Equatable, Sendable {
    let generatedAt: Date
    let sources: [String: Source]
    let deployments: [Deployment]

    struct Source: Decodable, Equatable, Sendable {
        let ok: Bool
        let since: Date?
        let error: String?
    }

    enum Verdict: String, Decodable, Equatable, Sendable {
        case ok, degraded, down, blind, unmonitored

        /// An unknown verdict from a newer Hlídač is never read as healthy.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Verdict(rawValue: raw) ?? .blind
        }
    }

    struct Deployment: Decodable, Equatable, Identifiable, Sendable {
        let key: String
        let project: String
        let title: String
        let tier: String
        let verdict: Verdict
        let blindSince: Date?
        let emergency: Bool
        let checks: [Check]
        let logs: Logs
        let edge: Edge?
        let sentry: [Issue]
        let alerts: [Alert]
        let pool: Pool?
        let links: [Link]
        var id: String {
            key
        }
    }

    struct Check: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        /// 1 ok · 0.5 degraded · 0 down · nil = no series.
        let status: Double?
        let value: String?
        let page: Bool
    }

    struct Logs: Decodable, Equatable, Sendable {
        /// 24 buckets, oldest first; the last is the current partial hour.
        let hours: [Hour]?
        let today: Counts?
        let yesterday: Counts?
    }

    struct Hour: Decodable, Equatable, Sendable {
        let start: Date
        let error: Int
        let warn: Int
    }

    struct Counts: Decodable, Equatable, Sendable {
        let error: Int
        let warn: Int
    }

    struct Edge: Decodable, Equatable, Sendable {
        let today: EdgeCounts
    }

    struct EdgeCounts: Decodable, Equatable, Sendable {
        let serverErrors: Int
        let throttled: Int

        enum CodingKeys: String, CodingKey {
            case serverErrors = "5xx"
            case throttled = "429"
        }
    }

    struct Issue: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let shortId: String
        let title: String
        let project: String
        let environment: String
        let count: Int
        let users: Int
        let firstSeen: Date
        let lastSeen: Date
        let permalink: String?
        let isNew: Bool
    }

    struct Alert: Decodable, Equatable, Sendable {
        let name: String
        let severity: String
        let summary: String
        let activeAt: Date?
        let emergency: Bool
        let url: String?

        var isCritical: Bool {
            severity == "critical"
        }
    }

    struct Pool: Decodable, Equatable, Sendable {
        let pools: [GatewayPool]
        let canary: Canary?
        let failoversToday: Int?
        let backupTurnsToday: Int?
    }

    struct GatewayPool: Decodable, Equatable, Identifiable, Sendable {
        let gateway: String
        let usable: Int
        let total: Int
        let accounts: [Account]
        var id: String {
            gateway
        }
    }

    struct Account: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        /// usable · cooling · benched · disabled · logged_out
        let state: String
        let cooldownUntil: Date?
        let demotedUntil: Date?
        let windows: [Window]
        let turns24h: Int
        let observedAt: Date?
    }

    struct Window: Decodable, Equatable, Sendable {
        /// A LENGTH name — `five_hour`, `seven_day`, `fable_weekly`, `<n>m` —
        /// never a codex `primary`/`secondary` position (contracts §5).
        let name: String
        let usedRatio: Double
        let resetsAt: Date?
    }

    struct Canary: Decodable, Equatable, Sendable {
        let lastSuccess: Date?
        let durationSeconds: Double?
        let consecutiveFailures: Int
    }

    struct Link: Decodable, Equatable, Sendable {
        let title: String
        let url: String
    }

    /// RFC 3339 with or without fractional seconds (Go emits either).
    static func decode(_ data: Data) -> HlidacDigest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        do {
            return try decoder.decode(HlidacDigest.self, from: data)
        } catch {
            NSLog("pultik: hlidac digest unreadable — %@", ConfigIssueSink.describe(error))
            return nil
        }
    }
}

/// The prod board as the panel draws it: one card per configured
/// deployment, in board order, plus the menu bar's five dots.
struct ProdGlance: Equatable {
    var cards: [Card]
    /// With no card to draw: "waiting for Hlídač" before its first answer,
    /// "blind since HH:MM" while it is unreachable — the board still shows
    /// one blind row rather than vanishing (F10).
    var waiting: String? = nil

    enum Tone: String, Equatable, Sendable {
        /// ok · degraded · down · no answer (striped) · not monitored (hollow)
        case green, orange, red, blind, hollow

        init(_ verdict: HlidacDigest.Verdict) {
            switch verdict {
            case .ok: self = .green
            case .degraded: self = .orange
            case .down: self = .red
            case .blind: self = .blind
            case .unmonitored: self = .hollow
            }
        }

        /// The tone in words, for labels a colour cannot reach.
        var spoken: String {
            switch self {
            case .green: "ok"
            case .orange: "degraded"
            case .red: "down"
            case .blind: "no answer"
            case .hollow: "not monitored"
            }
        }
    }

    struct Card: Equatable, Identifiable {
        let key: String
        let title: String
        let tier: String
        let tone: Tone
        /// One quiet line under the title when there is no number to show:
        /// "blind since 14:02", "not monitored", "unknown to Hlídač".
        let status: String?
        let emergency: Bool
        /// Hlídač is unreachable: chips, cells and the top issue keep their
        /// last-known text but read blind, never a stale green or red.
        let stale: Bool
        let chips: [Chip]
        /// Nil = no log series (CZ, or a blind card with nothing cached).
        let hours: [HlidacDigest.Hour]?
        /// "0 err · 818 warn ▾4%" — nil when there are no log counts.
        let logsLine: String?
        /// "5xx 0 · 429 340"
        let edgeLine: String?
        let topIssue: TopIssue?
        /// The full deployment for the `.h` matrix; nil on a config-issue card.
        let deployment: HlidacDigest.Deployment?
        var id: String {
            key
        }
    }

    struct Chip: Equatable, Identifiable {
        let id: String
        let label: String
        let tone: Tone
    }

    struct TopIssue: Equatable {
        enum Kind: Equatable { case alert, sentry }
        let kind: Kind
        let title: String
        /// "12m" / "558× · 3 users · 2h"
        let meta: String
        let tone: Tone
        let isNew: Bool
        let url: String?

        func withTone(_ tone: Tone) -> TopIssue {
            TopIssue(kind: kind, title: title, meta: meta, tone: tone, isNew: isNew, url: url)
        }
    }

    struct Dot: Equatable, Identifiable {
        let key: String
        let tone: Tone
        /// Red and not yet seen in an open panel.
        let pulsing: Bool
        var id: String {
            key
        }
    }

    /// - Parameters:
    ///   - pointers: settings.json `projects[].prod`, already in board order.
    ///     Empty = show every deployment Hlídač reports.
    ///   - digest: the last answer, kept through an outage for context.
    ///   - unreachableSince: set while Hlídač is not answering — every card
    ///     reads blind from then, whatever the cached digest says.
    static func make(pointers: [ProdPointer], digest: HlidacDigest?, unreachableSince: Date?,
                     now: Date, timeZone: TimeZone = .current) -> ProdGlance {
        let byKey = Dictionary((digest?.deployments ?? []).map { ($0.key, $0) },
                               uniquingKeysWith: { first, _ in first })
        let wanted: [ProdPointer] = pointers.isEmpty
            ? (digest?.deployments ?? []).map { ProdPointer(key: $0.key) }
            : pointers
        let cards = wanted.map { pointer -> Card in
            guard let deployment = byKey[pointer.key] else {
                return Card(
                    key: pointer.key, title: pointer.title ?? pointer.key, tier: pointer.tier ?? "critical",
                    tone: .blind,
                    status: digest == nil ? blindLine(unreachableSince, timeZone: timeZone)
                        : "unknown to Hlídač — add it to deployments.yaml",
                    emergency: false, stale: unreachableSince != nil, chips: [], hours: nil, logsLine: nil, edgeLine: nil,
                    topIssue: nil, deployment: nil)
            }
            return card(deployment, pointer: pointer, unreachableSince: unreachableSince,
                        now: now, timeZone: timeZone)
        }
        guard cards.isEmpty else { return ProdGlance(cards: cards) }
        let waiting = unreachableSince != nil ? blindLine(unreachableSince, timeZone: timeZone)
            : digest == nil ? blindLine(nil, timeZone: timeZone) : nil
        return ProdGlance(cards: [], waiting: waiting)
    }

    private static func card(_ deployment: HlidacDigest.Deployment, pointer: ProdPointer,
                             unreachableSince: Date?, now: Date, timeZone: TimeZone) -> Card {
        let blind = unreachableSince != nil || deployment.verdict == .blind
        let since = unreachableSince ?? deployment.blindSince
        let status: String?
        switch deployment.verdict {
        case _ where blind: status = blindLine(since, timeZone: timeZone)
        case .unmonitored: status = "not monitored"
        default: status = nil
        }
        return Card(
            key: deployment.key,
            title: pointer.title ?? deployment.title,
            tier: pointer.tier ?? deployment.tier,
            tone: blind ? .blind : Tone(deployment.verdict),
            status: status,
            // Hlídač's own blind verdict can still carry an emergency from
            // Alertmanager; only a stale cached digest must never siren.
            emergency: unreachableSince == nil && deployment.emergency,
            stale: unreachableSince != nil,
            chips: deployment.checks.map { check in
                Chip(id: check.id,
                     label: [check.title, check.value].compactMap { $0 }.joined(separator: " "),
                     tone: unreachableSince != nil ? .blind : chipTone(check.status))
            },
            hours: deployment.logs.hours,
            logsLine: logsLine(deployment.logs),
            edgeLine: deployment.edge.map { "5xx \($0.today.serverErrors) · 429 \($0.today.throttled)" },
            topIssue: topIssue(deployment, now: now).map { issue in
                unreachableSince == nil ? issue : issue.withTone(.blind)
            },
            deployment: deployment)
    }

    private static func chipTone(_ status: Double?) -> Tone {
        switch status {
        case .none: return .blind
        case let .some(value) where value >= 1: return .green
        case let .some(value) where value > 0: return .orange
        default: return .red
        }
    }

    private static func blindLine(_ since: Date?, timeZone: TimeZone) -> String {
        guard let since else { return "waiting for Hlídač" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "blind since \(formatter.string(from: since))"
    }

    /// "0 err · 818 warn ▾4%": the arrow compares today's lines (errors plus
    /// warnings) with the same hours yesterday and is omitted without a base.
    static func logsLine(_ logs: HlidacDigest.Logs) -> String? {
        guard let today = logs.today else { return nil }
        var line = "\(today.error) err · \(today.warn) warn"
        if let yesterday = logs.yesterday, yesterday.error + yesterday.warn > 0 {
            let now = Double(today.error + today.warn)
            let then = Double(yesterday.error + yesterday.warn)
            let percent = Int(((now - then) / then * 100).rounded())
            if percent != 0 { line += " \(percent < 0 ? "▾" : "▴")\(abs(percent))%" }
        }
        return line
    }

    /// Most urgent first: a critical alert, any alert, a new Sentry issue,
    /// then the most recently seen issue (Hlídač sends them newest first).
    private static func topIssue(_ deployment: HlidacDigest.Deployment, now: Date) -> TopIssue? {
        let alerts = deployment.alerts.sorted { ($0.isCritical ? 0 : 1) < ($1.isCritical ? 0 : 1) }
        if let alert = alerts.first {
            return TopIssue(kind: .alert, title: alert.summary.isEmpty ? alert.name : alert.summary,
                            meta: alert.activeAt.map { $0.shortAge(relativeTo: now) } ?? "",
                            tone: alert.isCritical ? .red : .orange, isNew: false, url: alert.url)
        }
        let issue = deployment.sentry.first(where: \.isNew) ?? deployment.sentry.first
        return issue.map { issue in
            TopIssue(kind: .sentry, title: issue.title,
                     meta: "\(issue.count)× · \(issue.users) users · \(issue.lastSeen.shortAge(relativeTo: now))",
                     tone: .red, isNew: issue.isNew, url: issue.permalink)
        }
    }

    /// A card's colour on the strip: a live emergency is red whatever the
    /// verdict — a blind deployment can still carry one from Alertmanager
    /// (D9). A stale card never has `emergency`, so a cached one never sirens.
    private static func stripTone(_ card: Card) -> Tone {
        card.emergency ? .red : card.tone
    }

    /// The menu bar's health strip: one dot per card in board order. A red
    /// dot pulses until a panel open has seen it red (`seenRed`).
    func dots(seenRed: Set<String>) -> [Dot] {
        cards.map { card in
            let tone = Self.stripTone(card)
            return Dot(key: card.key, tone: tone, pulsing: tone == .red && !seenRed.contains(card.key))
        }
    }

    /// The strip in words — the status item's tooltip and accessibility
    /// label, since the dots are colour in a raster image: every card that
    /// is not ok in board order, an emergency and an unseen red marked, then
    /// the ok count. Nil without cards.
    func spoken(seenRed: Set<String>) -> String? {
        guard !cards.isEmpty else { return nil }
        let ok = cards.filter { Self.stripTone($0) == .green }.count
        let rest = cards.filter { Self.stripTone($0) != .green }.map { card in
            "\(card.title) \(card.tone.spoken)" + (card.emergency ? ", emergency" : "")
                + (Self.stripTone(card) == .red && !seenRed.contains(card.key) ? ", unseen" : "")
        }
        guard !rest.isEmpty else { return "prod: all \(ok) ok" }
        return "prod: " + (rest + (ok > 0 ? ["\(ok) ok"] : [])).joined(separator: " · ")
    }

    /// Keys red on the strip right now — what a panel open marks as seen.
    var redKeys: Set<String> {
        Set(cards.filter { Self.stripTone($0) == .red }.map(\.key))
    }

    /// Seen-state after a refresh: a deployment that left red forgets it was
    /// seen, so its next red pulses again.
    static func seen(_ seen: Set<String>, keepingOnly red: Set<String>) -> Set<String> {
        seen.intersection(red)
    }
}
