import Foundation

/// Which critical firing alerts are worth a macOS notification, poll by poll
/// (docs/specs/2026-09-29-firing-notifications-decisions.md). Pure state, no
/// I/O: `StatusStore` feeds it each answered fetch and sends what it returns.
///
/// - Only `critical` rules notify; warnings stay rail-only.
/// - The first answer after launch is silent: whatever already fires is
///   history, the same idiom as eve alerts and Sentry.
/// - An alert is one instance — `FiringAlert.id`, rule + labels — so one
///   rule firing on two containers notifies twice, but more than
///   `burstLimit` new ones in a poll collapse into one summary.
/// - A notified alert that stops firing notifies once as resolved.
/// - An instance back within `flapWindow` of leaving stays silent, and
///   notifies only if it is still firing once that window has passed.
struct FiringWatch {
    struct Notice: Equatable {
        let title: String
        let body: String
    }

    static let burstLimit = 3
    static let flapWindow: TimeInterval = 30 * 60

    /// Firing criticals of the last answer; nil until the first answer.
    private var live: [String: FiringAlert]?
    /// Announced as firing and not yet announced as resolved.
    private var notified: Set<String> = []
    /// When each instance last stopped firing, for the flap window.
    private var leftAt: [String: Date] = [:]
    /// Back inside the flap window and still firing — not yet announced.
    private var held: Set<String> = []

    static func criticals(_ alerts: [FiringAlert]) -> [FiringAlert] {
        alerts.filter { $0.state == "firing" && $0.severity == "critical" && $0.name != "Watchdog" }
    }

    /// One firing episode of an instance — what the panel marks seen, so a
    /// rule that resolves and fires again is unseen again.
    /// Deployments with a firing alert announced here and not yet resolved —
    /// what the prod board adopts when Hlídač comes back, so their red is not
    /// announced twice.
    var announcedDeployments: Set<String> {
        Set((live ?? [:]).values.filter { notified.contains($0.id) }.compactMap { $0.labels["deployment"] })
    }

    static func episodeKey(_ alert: FiringAlert) -> String {
        "\(alert.id)@\(alert.activeAt?.timeIntervalSince1970 ?? 0)"
    }

    /// `answered` = the evaluators that replied this poll. A silent one (the
    /// Loki ruler drops out on its own) keeps its last alerts, so its outage
    /// never reads as every one of its rules resolving.
    /// `quiet` = alerts another watch announces (the prod board, while Hlídač
    /// answers): tracked, never spoken — so their resolve stays silent too.
    mutating func update(_ alerts: [FiringAlert], answered: Set<FiringAlert.Source>,
                         quiet: (FiringAlert) -> Bool = { _ in false },
                         now: Date = Date()) -> [Notice]
    {
        var current = Dictionary(Self.criticals(alerts).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, alert) in live ?? [:] where !answered.contains(alert.source) {
            current[id] = alert
        }
        leftAt = leftAt.filter { now.timeIntervalSince($0.value) < Self.flapWindow }
        guard let previous = live else {
            live = current
            return []
        }
        live = current
        // Hand-off: an alert announced here that the prod board now owns
        // resolves there (ProdTransitions adopted it), never here as well.
        for alert in previous.values where quiet(alert) {
            notified.remove(alert.id)
        }

        let gone = previous.values.filter { current[$0.id] == nil }
        for alert in gone { leftAt[alert.id] = now }
        let resolved = gone.filter { notified.contains($0.id) }.sorted { $0.id < $1.id }
        notified.subtract(resolved.map(\.id))

        // Newcomers, plus flappers still firing: one back inside the window
        // waits, and speaks once it has stayed the window out.
        let candidates = current.values.filter { previous[$0.id] == nil || held.contains($0.id) }
        held = Set(candidates.filter { leftAt[$0.id] != nil }.map(\.id))
        let fired = candidates
            .filter { leftAt[$0.id] == nil && !quiet($0) }
            .sorted { ($0.activeAt ?? .distantPast, $0.id) < ($1.activeAt ?? .distantPast, $1.id) }
        notified.formUnion(fired.map(\.id))

        return Self.notices(fired, title: { "🔴 \($0.name)" }, burst: { "🔴 \($0) critical alerts firing" })
            + Self.notices(resolved, title: { "✅ \($0.name) resolved" },
                           burst: { "✅ \($0) critical alerts resolved" })
    }

    private static func notices(_ alerts: [FiringAlert], title: (FiringAlert) -> String,
                                burst: (Int) -> String) -> [Notice]
    {
        guard alerts.count <= burstLimit else {
            let names = Set(alerts.map(\.name)).sorted().joined(separator: ", ")
            return [Notice(title: burst(alerts.count), body: names)]
        }
        return alerts.map { alert in
            let summary = alert.summary ?? alert.description ?? alert.name
            return Notice(title: title(alert), body: alert.context.map { "\($0) — \(summary)" } ?? summary)
        }
    }
}
