import Foundation

/// One line of the ranked list: an incident, a ×N series (one problem seen
/// on several objects), or a fold of same-kind incidents (D15). Series and
/// folds expand in place under their own key.
struct NowRow: Equatable, Identifiable, Sendable {
    enum Shape: Equatable, Sendable {
        case incident
        /// The same check failing on several PRs, reminders due together:
        /// counts as ONE incident in the hero, drawn "×N".
        case series
        /// Several same-kind incidents past the lane's first rows: counts as
        /// each of them, drawn "+N".
        case fold
    }

    /// An incident row's key is its incident key; a series or fold row has
    /// its own, stable across refreshes.
    let key: String
    let shape: Shape
    let lane: NowLane
    /// The incidents the row stands for, best first — one for `.incident`.
    let incidents: [NowIncident]
    /// The series or fold this row was expanded out of.
    let parentKey: String?

    var id: String { key }
    var lead: NowIncident { incidents[0] }
    var kind: NowKind { lead.kind }
    var needCount: Int { incidents.reduce(0) { $0 + $1.evidence } }
    /// What this row adds to its lane's hero count: a series is one problem,
    /// a fold is each incident it hides.
    var heroCount: Int { shape == .fold ? incidents.count : 1 }
}

/// A lane's hero cell: grouped incidents with the raw evidence labelled
/// beside them ("10 · 15 needs · 5 folded").
struct NowLaneSummary: Equatable, Sendable {
    let lane: NowLane
    /// Grouped active incidents; a ×N series counts once.
    let incidents: Int
    /// Raw needs behind them.
    let needs: Int
    /// Incidents hidden in collapsed folds.
    let folded: Int
}

/// Home's Now queue (D6): adapters → needs → incidents → lanes → rank →
/// fold by kind. Both Home styles and the status strip draw this one value.
struct NowQueue: Equatable, Sendable {
    /// A lane's first rows always stand alone; folding starts past them.
    static let leadRows = 3

    let now: Date
    /// Every active incident, ranked.
    let incidents: [NowIncident]
    /// The collapsed list, in drawing order: lanes in order, ranked inside.
    let rows: [NowRow]
    /// All four lanes, in order, empty ones included.
    let lanes: [NowLaneSummary]

    var incidentCount: Int { lanes.reduce(0) { $0 + $1.incidents } }
    var needCount: Int { lanes.reduce(0) { $0 + $1.needs } }

    /// Groups by incident key (never by title text), ranks, then folds.
    /// A need whose onset is still in the future is not active yet and stays
    /// out; a needID seen twice keeps its first copy.
    static func build(needs: [NowNeed], now: Date) -> NowQueue {
        var seen = Set<String>()
        var grouped: [String: [NowNeed]] = [:]
        for need in needs where need.onset.date <= now && seen.insert(need.needID).inserted {
            grouped[need.incidentKey, default: []].append(need)
        }
        let incidents = grouped.compactMap { NowIncident(key: $0.key, needs: $0.value) }
            .sorted(by: NowIncident.ranksBefore)
        var rows: [NowRow] = []
        var lanes: [NowLaneSummary] = []
        for lane in NowLane.allCases {
            let laneRows = Self.rows(lane, incidents.filter { $0.lane == lane })
            rows += laneRows
            lanes.append(NowLaneSummary(
                lane: lane,
                incidents: laneRows.reduce(0) { $0 + $1.heroCount },
                needs: laneRows.reduce(0) { $0 + $1.needCount },
                folded: laneRows.filter { $0.shape == .fold }.reduce(0) { $0 + $1.incidents.count }))
        }
        return NowQueue(now: now, incidents: incidents, rows: rows, lanes: lanes)
    }

    func summary(_ lane: NowLane) -> NowLaneSummary {
        lanes.first { $0.lane == lane } ?? NowLaneSummary(lane: lane, incidents: 0, needs: 0, folded: 0)
    }

    func incident(_ key: String) -> NowIncident? {
        incidents.first { $0.key == key }
    }

    /// The rows on screen given which series and folds are open — keyboard
    /// selection walks exactly these.
    func visible(expanded: Set<String>) -> [NowRow] {
        rows.flatMap { row -> [NowRow] in
            guard row.shape != .incident, expanded.contains(row.key) else { return [row] }
            return row.incidents.map {
                NowRow(key: $0.key, shape: .incident, lane: row.lane, incidents: [$0], parentKey: row.key)
            }
        }
    }

    /// True while `key` names an active incident or a series/fold row.
    func holds(_ key: String) -> Bool {
        incident(key) != nil || rows.contains { $0.key == key }
    }

    /// The visible row that shows `key`: itself, or the collapsed series or
    /// fold that hides it.
    func visibleKey(for key: String, expanded: Set<String>) -> String? {
        let rows = visible(expanded: expanded)
        if rows.contains(where: { $0.key == key }) { return key }
        return rows.first { row in row.shape != .incident && row.incidents.contains { $0.key == key } }?.key
    }

    /// One lane's rows. ×N series form first (same kind + series identity,
    /// two or more, foldable severity); then, past the lane's first rows,
    /// same-kind incidents fold into one counted row placed where its best
    /// member ranks. On fire and critical/emergency never fold, and a series
    /// is already compact, so it never folds again.
    private static func rows(_ lane: NowLane, _ ranked: [NowIncident]) -> [NowRow] {
        let folds = lane != .onFire
        func seriesKey(_ incident: NowIncident) -> String? {
            guard folds, incident.severity.mayFold, let series = incident.lead.seriesKey else { return nil }
            return "series:\(lane.rawValue):\(incident.kind.rawValue):\(series)"
        }
        var members: [String: [NowIncident]] = [:]
        for incident in ranked {
            if let key = seriesKey(incident) { members[key, default: []].append(incident) }
        }
        var units: [NowRow] = []
        var placed = Set<String>()
        for incident in ranked {
            if let key = seriesKey(incident), let series = members[key], series.count >= 2 {
                if placed.insert(key).inserted {
                    units.append(NowRow(key: key, shape: .series, lane: lane, incidents: series, parentKey: nil))
                }
            } else {
                units.append(NowRow(key: incident.key, shape: .incident, lane: lane, incidents: [incident],
                                    parentKey: nil))
            }
        }
        guard folds else { return units }

        func foldable(_ index: Int) -> Bool {
            index >= leadRows && units[index].shape == .incident && units[index].lead.severity.mayFold
        }
        var byKind: [NowKind: [NowIncident]] = [:]
        for index in units.indices where foldable(index) {
            byKind[units[index].kind, default: []].append(units[index].lead)
        }
        var out: [NowRow] = []
        var emitted = Set<NowKind>()
        for index in units.indices {
            let unit = units[index]
            guard foldable(index), let fold = byKind[unit.kind], fold.count >= 2 else {
                out.append(unit)
                continue
            }
            if emitted.insert(unit.kind).inserted {
                out.append(NowRow(key: "fold:\(lane.rawValue):\(unit.kind.rawValue)", shape: .fold, lane: lane,
                                  incidents: fold, parentKey: nil))
            }
        }
        return out
    }
}
