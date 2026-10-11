import Foundation

/// The Now list's keyboard selection (contract "Selection"): held by object
/// identity — the selected row's key plus the chosen child — never by row
/// index. A refresh re-ranks around it without ever moving it to another
/// object; new urgency may move a row, never steal the cursor.
struct NowSelection: Equatable, Sendable {
    /// The selected row's key: an incident's key, or a ×N series or fold
    /// row's own key.
    let incidentKey: String
    /// The child need picked in detail, if any.
    let needID: String?
    /// Set once the selected object left the view ("resolved / no longer in
    /// this view"): Return targets nothing until an explicit arrow moves on.
    private(set) var tombstone: Tombstone?

    struct Tombstone: Equatable, Sendable {
        /// The visible row keys, in order, of the last view that held it.
        let order: [String]
    }

    enum Step: Sendable {
        case up, down
    }

    init(incidentKey: String, needID: String? = nil) {
        self.incidentKey = incidentKey
        self.needID = needID
    }

    static func first(in queue: NowQueue, expanded: Set<String> = []) -> NowSelection? {
        queue.visible(expanded: expanded).first.map { NowSelection(incidentKey: $0.key) }
    }

    var isTombstone: Bool { tombstone != nil }

    /// After an atomic refresh: the same object, or a tombstone carrying the
    /// old ordering — never another row. A tombstone stays until navigation.
    func refreshed(from old: NowQueue, to new: NowQueue, expanded: Set<String> = []) -> NowSelection {
        guard tombstone == nil, !new.holds(incidentKey) else { return self }
        var copy = self
        copy.tombstone = Tombstone(order: old.visible(expanded: expanded).map(\.key))
        return copy
    }

    /// The selected child resolved while its siblings remain: the incident
    /// stays selected and detail shows the child finished.
    func childResolved(in queue: NowQueue) -> Bool {
        guard let needID, let incident = queue.incident(incidentKey) else { return false }
        return !incident.needs.contains { $0.needID == needID }
    }

    /// What Return opens — detail only, never a mutation. Nil on a tombstone
    /// (Return never silently targets a new row) and on a fold, which →
    /// expands instead.
    func returnTarget(in queue: NowQueue) -> NowTarget? {
        guard tombstone == nil else { return nil }
        if let incident = queue.incident(incidentKey) {
            let child = needID.flatMap { id in incident.needs.first { $0.needID == id } }
            return (child ?? incident.lead).target
        }
        guard let row = queue.rows.first(where: { $0.key == incidentKey }), row.shape == .series else { return nil }
        return row.lead.lead.target
    }

    /// An explicit arrow. From a tombstone it lands on the nearest surviving
    /// neighbour of the previous ordering, looking the arrow's way first;
    /// otherwise it steps through the visible rows.
    func moved(_ step: Step, in queue: NowQueue, expanded: Set<String> = []) -> NowSelection? {
        let keys = queue.visible(expanded: expanded).map(\.key)
        guard !keys.isEmpty else { return nil }
        if let tombstone {
            guard let from = tombstone.order.firstIndex(of: incidentKey) else { return Self.first(in: queue, expanded: expanded) }
            let after = Array(tombstone.order[(from + 1)...])
            let before = Array(tombstone.order[..<from].reversed())
            for key in step == .down ? after + before : before + after {
                if let visible = queue.visibleKey(for: key, expanded: expanded) {
                    return NowSelection(incidentKey: visible)
                }
            }
            return Self.first(in: queue, expanded: expanded)
        }
        guard let current = queue.visibleKey(for: incidentKey, expanded: expanded),
              let index = keys.firstIndex(of: current)
        else { return Self.first(in: queue, expanded: expanded) }
        let next = step == .down ? min(index + 1, keys.count - 1) : max(index - 1, 0)
        return next == index && current == incidentKey ? self : NowSelection(incidentKey: keys[next])
    }
}
