import SwiftUI

/// Home's Now queue in the panel (copilot shell WP4): the rows the keyboard
/// walks, what ↵ does on each, and the tombstone a resolved selection leaves
/// (contract "Selection": a re-rank never moves the cursor onto another row,
/// and ↵ never silently targets a new one).
extension StatusPanelView {
    /// Home's rows for `queue`: an open fold keeps its own row as the header
    /// its children list under — ↵ there closes it again, and ↓ steps into
    /// them — where `NowQueue.visible` replaces it.
    static func nowRows(_ queue: NowQueue, expanded: Set<String>) -> [NowRow] {
        queue.rows.flatMap { row -> [NowRow] in
            guard row.shape == .fold, expanded.contains(row.key) else { return [row] }
            return [row] + row.incidents.map {
                NowRow(key: $0.key, shape: .incident, lane: row.lane, incidents: [$0], parentKey: row.key)
            }
        }
    }

    /// What Home draws and ↑/↓ walk, in order, with a resolved selection's
    /// tombstone at its old place.
    var homeNowRows: [NowHomeRow] {
        var rows = Self.nowRows(NowStore.shared.queue, expanded: nowExpanded).map(NowHomeRow.live)
        guard let tombstone = nowTombstone else { return rows }
        let index = tombstone.after.flatMap { key in rows.firstIndex { $0.row.key == key }.map { $0 + 1 } } ?? 0
        rows.insert(.tombstone(tombstone.row), at: index)
        return rows
    }

    /// ↵ or a click: a fold opens or closes in place; any other row opens
    /// its object's detail in its module; a tombstone does nothing.
    func activateNow(_ item: NowHomeRow) {
        selectedID = item.id
        guard case let .live(row) = item else { return }
        if row.shape == .fold {
            if nowExpanded.contains(row.key) { nowExpanded.remove(row.key) } else { nowExpanded.insert(row.key) }
            return
        }
        guard let target = NowSelection(incidentKey: row.key).returnTarget(in: NowStore.shared.queue) else { return }
        openNowTarget(target)
    }

    /// Enters the target's module with its object selected and its detail
    /// open — or, when the module does not list that object (yet), the
    /// module alone, never another row's detail.
    func openNowTarget(_ target: NowTarget) {
        openObject(target.module, target.objectID)
    }

    /// `module` on the view that lists `id` — the shown one first, then the
    /// others in ⇥ order (vt-7727 D5) — with it selected and its detail
    /// open; the module alone when no view lists it, or `id` is nil.
    func openObject(_ module: PanelModule, _ id: String?) {
        guard let id else { return router.enter(module) }
        let shown = router.view(of: module)
        let others = module.views.filter { $0 != shown }
        let candidates: [(ModuleView?, ModuleInputs)] = [(shown, inputs(for: module))]
            + others.map { ($0, ModuleInputs(view: $0)) }
        for (view, inputs) in candidates where modulePage(module, inputs: inputs)?.objects.contains(where: { $0.id == id }) == true {
            return router.enter(module, select: id, openDetail: true, view: view)
        }
        router.enter(module)
    }

    /// After a refresh: the selected incident still shows — itself, or the
    /// fold that now holds it, which takes the selection — or it left, and
    /// becomes a tombstone after the nearest row that preceded it and still
    /// shows.
    func nowQueueChanged(from old: NowQueue, to new: NowQueue) {
        guard showsHome, nowTombstone == nil, let id = selectedID, id.hasPrefix("now:") else { return }
        let key = String(id.dropFirst("now:".count))
        let shown = Self.nowRows(new, expanded: nowExpanded)
        if shown.contains(where: { $0.key == key }) { return }
        if let holder = shown.first(where: { row in row.shape != .incident && row.incidents.contains { $0.key == key } }) {
            selectedID = NowHomeRow.id(holder.key)
            return
        }
        let oldOrder = Self.nowRows(old, expanded: nowExpanded)
        guard let row = oldOrder.first(where: { $0.key == key }) else { return }
        let visible = Set(shown.map(\.key))
        nowTombstone = NowTombstone(row: row, after: oldOrder.map(\.key).prefix { $0 != key }.last(where: visible.contains))
        // The tombstone holds the selection under its own id, so the same
        // incident returning as a live row never inherits it.
        selectedID = NowHomeRow.goneID(key)
    }

    /// An explicit move away from the tombstone ends it.
    func nowSelectionChanged(to id: String?) {
        guard let tombstone = nowTombstone, id != NowHomeRow.goneID(tombstone.row.key) else { return }
        nowTombstone = nil
    }

    /// An arrow from the tombstone that would stay on it (↓ on the last row)
    /// or leave the list (↑ on the first) lands on its nearest surviving
    /// neighbour the other way; with none left, the selection clears.
    func nowArrowTarget(_ id: String?) -> String? {
        guard showsHome, let tombstone = nowTombstone, let current = selectedID,
              current == NowHomeRow.goneID(tombstone.row.key), id == current || id == nil else { return id }
        let ids = homeNowRows.map(\.id)
        guard let index = ids.firstIndex(of: current) else { return id }
        return id == nil ? ids[(index + 1)...].first : ids[..<index].last
    }
}
