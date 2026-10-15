import Foundation

/// Which prod-board changes are worth a macOS notification, digest by digest
/// (docs/specs/2026-10-02-prod-watch-decisions.md D9/D10). Pure state, no
/// I/O: `ProdWatch` feeds it every Hlídač answer and sends what it returns.
/// Mirrors `FiringWatch`'s idioms.
///
/// - A deployment is red when Hlídač says `down` or carries an emergency —
///   an emergency counts even on a `blind` or `unmonitored` deployment.
///   Otherwise `blind` and `unmonitored` are unknown: the last known state is
///   kept, so an outage never reads as a recovery.
/// - Turning red notifies once. Within one red episode, a NEW reason — a
///   check gone to 0, a new critical or emergency alert — notifies again, and
///   so does an escalation to an emergency.
/// - Policy (lead decision): a red on a `critical`-tier deployment, and every
///   emergency, is Time Sensitive and bypasses FocusGate; any other red is an
///   ordinary banner through FocusGate. Recoveries are ordinary banners.
/// - The first answer after launch is silent, and so is the first sighting of
///   a deployment added later: whatever is already red is history. A first
///   sighting that is blind is observed-but-unknown, not unseen: its first
///   healthy answer is silent, a red after it is news.
/// - Recovery notifies once, and only for a red that was announced.
/// - Back to red within `flapWindow` of recovering stays silent (an emergency
///   never waits), and speaks only if still red once the window has passed.
/// - Hlídač unreachable says nothing: the blind board and dots say it.
struct ProdTransitions {
    struct Notice: Equatable {
        /// The deployment it speaks for — the notification thread and the
        /// click target.
        let key: String
        let title: String
        let body: String
        let interruption: NotificationContent.Interruption
        /// Delivered even while FocusGate holds.
        let bypassesFocus: Bool
    }

    static let flapWindow: TimeInterval = 30 * 60

    private struct State: Equatable {
        var red: Bool
        var emergency: Bool
        /// `check:<id>` for checks at 0, `alert:<name>` for critical or
        /// emergency alerts — what a red is made of.
        var reasons: Set<String>
    }

    /// Last known state per deployment; nil until the first answer.
    private var known: [String: State]?
    /// Seen only blind or unmonitored so far — no known state yet, but not a
    /// first sighting either, so a later red is not baselined away.
    private var unknownSeen: Set<String> = []
    /// Announced red and not yet announced as recovered.
    private var announced: Set<String> = []
    /// Announced as an emergency while the emergency lasts.
    private var announcedEmergency: Set<String> = []
    /// Reasons already announced (or baselined) in the current red episode.
    private var announcedReasons: [String: Set<String>] = [:]
    /// When each deployment last left red, for the flap window.
    private var leftAt: [String: Date] = [:]
    /// Back inside the flap window and still red — not yet announced.
    private var held: Set<String> = []

    /// Deployments another channel already announced red — FiringWatch,
    /// while Hlídač was away. Their red is not announced again, and their
    /// recovery comes from here.
    mutating func adopt(_ keys: Set<String>) {
        announced.formUnion(keys)
    }

    /// - Parameters:
    ///   - digest: Hlídač's latest answer; nil before the first one.
    ///   - unreachableSince: set while Hlídač does not answer — nothing is
    ///     known then, and nothing is said.
    ///   - pointers: settings.json `projects[].prod`; when non-empty, only
    ///     those deployments notify, with their own title and tier.
    mutating func update(digest: HlidacDigest?, unreachableSince: Date?, pointers: [ProdPointer] = [],
                         now: Date = Date()) -> [Notice]
    {
        leftAt = leftAt.filter { now.timeIntervalSince($0.value) < Self.flapWindow }
        guard unreachableSince == nil, let digest else { return [] }
        let wanted = pointers.isEmpty ? nil
            : Dictionary(pointers.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        var current = known ?? [:]
        var observed: [(deployment: HlidacDigest.Deployment, pointer: ProdPointer?)] = []
        for deployment in digest.deployments {
            if let wanted, wanted[deployment.key] == nil { continue }
            let unknown = deployment.verdict == .blind || deployment.verdict == .unmonitored
            if unknown, !deployment.emergency {
                if current[deployment.key] == nil { unknownSeen.insert(deployment.key) }
                continue
            }
            current[deployment.key] = State(red: deployment.verdict == .down || deployment.emergency,
                                            emergency: deployment.emergency,
                                            reasons: Self.reasons(deployment))
            observed.append((deployment, wanted?[deployment.key]))
        }
        guard let previous = known else {
            known = current
            // A red already there at launch is history, and so are its
            // reasons for the whole episode — one that dips and returns
            // while still red is not news.
            for (key, state) in current where state.red { announcedReasons[key] = state.reasons }
            return []
        }
        known = current

        var notices: [Notice] = []
        for (deployment, pointer) in observed {
            let key = deployment.key
            guard let state = current[key] else { continue }
            // First sighting of this deployment: a baseline, never news —
            // unless it was seen blind before, which baselined nothing.
            let blindBefore = unknownSeen.remove(key) != nil
            guard let was = previous[key] ?? (blindBefore ? State(red: false, emergency: false, reasons: []) : nil)
            else {
                if state.red { announcedReasons[key] = state.reasons }
                continue
            }
            let critical = (pointer?.tier ?? deployment.tier) == "critical"
            let title = pointer?.title ?? deployment.title
            if !state.emergency { announcedEmergency.remove(key) }

            if state.red {
                let newcomer = !was.red || held.contains(key)
                if newcomer {
                    // A flapper waits out the window — unless it is now an
                    // emergency, which never waits.
                    if leftAt[key] != nil, !state.emergency {
                        held.insert(key)
                        continue
                    }
                    held.remove(key)
                    announcedReasons[key] = state.reasons
                    if state.emergency { announcedEmergency.insert(key) }
                    // Handed back from FiringWatch: already announced there.
                    guard !announced.contains(key) else { continue }
                    announced.insert(key)
                    notices.append(Self.red(deployment, title: title, emergency: state.emergency,
                                            critical: critical, new: state.reasons))
                    continue
                }
                // Already red (announced, or silently since launch): speak
                // for what is new in this episode.
                let base = announcedReasons[key] ?? was.reasons
                let added = state.reasons.subtracting(base)
                let escalated = state.emergency && !was.emergency && !announcedEmergency.contains(key)
                guard escalated || !added.isEmpty else { continue }
                announced.insert(key)
                announcedReasons[key] = base.union(state.reasons)
                if state.emergency { announcedEmergency.insert(key) }
                notices.append(Self.red(deployment, title: title, emergency: state.emergency,
                                        critical: critical, new: added.isEmpty ? state.reasons : added))
            } else if was.red || announced.contains(key) {
                // (`announced` without `was.red`: a red adopted from
                // FiringWatch that ended while Hlídač was away.)
                held.remove(key)
                leftAt[key] = now
                announcedEmergency.remove(key)
                announcedReasons[key] = nil
                if announced.remove(key) != nil {
                    notices.append(Notice(key: key, title: "✅ \(title) recovered",
                                          body: Self.okSummary(deployment), interruption: .active,
                                          bypassesFocus: false))
                }
            }
        }
        return notices
    }

    private static func reasons(_ deployment: HlidacDigest.Deployment) -> Set<String> {
        Set(deployment.checks.filter { $0.status == 0 }.map { "check:\($0.id)" })
            .union(deployment.alerts.filter { $0.emergency || $0.isCritical }.map { "alert:\($0.name)" })
    }

    /// `new` picks the headline: the first newly failing check, else the
    /// first new critical alert. The body lists every current reason.
    private static func red(_ deployment: HlidacDigest.Deployment, title: String, emergency: Bool,
                            critical: Bool, new: Set<String>) -> Notice
    {
        let failing = deployment.checks.filter { $0.status == 0 }
        let alerts = deployment.alerts.filter { $0.emergency || $0.isCritical }
        let headline: String
        if let check = failing.first(where: { new.contains("check:\($0.id)") }) {
            headline = "\(check.title) down"
        } else if let alert = alerts.first(where: { new.contains("alert:\($0.name)") && $0.emergency })
            ?? alerts.first(where: { new.contains("alert:\($0.name)") })
        {
            headline = alert.summary.isEmpty ? alert.name : alert.summary
        } else {
            headline = "down"
        }
        let lines = failing.map { [$0.title, $0.value].compactMap { $0 }.joined(separator: " ") }
            + alerts.map { $0.summary.isEmpty ? $0.name : $0.summary }
        let urgent = emergency || critical
        return Notice(key: deployment.key,
                      title: "\(emergency ? "🚨" : "🔴") \(title) · \(headline)",
                      body: lines.isEmpty ? "Open the prod board for details." : lines.joined(separator: " · "),
                      interruption: urgent ? .timeSensitive : .active,
                      bypassesFocus: urgent)
    }

    private static func okSummary(_ deployment: HlidacDigest.Deployment) -> String {
        let checks = deployment.checks.filter { $0.status == 1 }
            .map { [$0.title, $0.value].compactMap { $0 }.joined(separator: " ") }
        return checks.isEmpty ? "Back to \(deployment.verdict.rawValue)." : checks.prefix(3).joined(separator: " · ")
    }
}
