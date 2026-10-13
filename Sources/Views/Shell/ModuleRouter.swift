import Foundation
import Observation

/// Where the panel is (copilot shell D5, D9): the entered module and its
/// filter, the selected object, and whether its detail and the ⌘I inspector
/// are open. The search is global until a module is entered — Home while
/// nothing is typed, results once something is — then it becomes the
/// module's scope chip and the field filters inside it; ⌫ on an empty field
/// widens back to global. Foundation-only: `Tests/ModuleRouterTests.swift`
/// drives it without a view.
///
/// Selection is always an object id, never an index, so a refresh that
/// re-ranks or re-filters a list never moves the cursor onto another row;
/// each module remembers its last selection for its next visit.
@MainActor
@Observable
final class ModuleRouter {
    /// What a change of the field's text means (`route(_:in:)`).
    enum Route: Equatable {
        /// It stays the global query, or the entered module's filter.
        case text(String)
        /// A `.x` alias: enter `module` with the rest as its filter. `rest`
        /// is the unread tail of the mode's name (`i` after `.c`); `opens`
        /// is the object the alias lands on with its detail (`.f`, Mac's fans).
        case enter(PanelModule, filter: String, rest: String, opens: String? = nil)
        /// `.` or `/` typed into a module: commands and palette pages are
        /// global, so the scope drops and the text goes with it.
        case global(String)
    }

    /// The entered module; nil while the search is global. Home is the
    /// global search at rest, never an entered scope.
    private(set) var module: PanelModule?
    /// The field: the global query, or the entered module's filter.
    private(set) var text = ""
    /// The highlighted object in the list on screen; nil = the field owns ↵.
    private(set) var selection: String?
    /// ↵ opened the selected object's detail (D4-B). Never a mutation.
    private(set) var detailOpen = false
    /// ⌘I: the detail's context sections move into a trailing inspector.
    private(set) var inspectorOpen = false
    /// The rest of a `.x` token's mode name: `.c` enters CI at once, so the
    /// `i` of `.ci` — and the space that ends the token — must not become
    /// CI's filter. The keyboard swallows them (`swallowTokenKey`).
    private(set) var pendingToken = ""
    private var remembered: [PanelModule: String] = [:]

    init() {}

    /// The dot grammar, pure: a `.x` alias enters its module from anywhere;
    /// inside a module a leading `.` or `/` returns to the global search.
    nonisolated static func route(_ text: String, in module: PanelModule?) -> Route {
        if let parsed = PaletteMode.parse(text), let target = parsed.mode.module {
            return .enter(target, filter: parsed.filter,
                          rest: parsed.filter.isEmpty ? String(parsed.mode.rawValue.dropFirst(parsed.token.count)) : "",
                          opens: parsed.mode.opens)
        }
        if module != nil, text.hasPrefix(".") || text.hasPrefix("/") { return .global(text) }
        return .text(text)
    }

    /// The field's text changed — typed, pasted, or set by a page or the
    /// debug driver; `.c failed` lands in CI with `failed`.
    func type(_ new: String) {
        switch Self.route(new, in: module) {
        case let .text(value):
            text = value
            pendingToken = ""
        case let .enter(target, filter, rest, opens):
            enter(target, filter: filter, select: opens, openDetail: opens != nil)
            pendingToken = rest
        case let .global(value):
            leave(keeping: value)
        }
    }

    /// Consumes the next character of the pending token (or the space that
    /// ends it) while the filter is still empty. False: it is filter text.
    func swallowTokenKey(_ character: String) -> Bool {
        // `.ho` lands on Home, which is no entered module, with `me` still to come.
        guard module != nil || !pendingToken.isEmpty, text.isEmpty else { return false }
        if let next = pendingToken.first, character.lowercased() == String(next) {
            pendingToken.removeFirst()
            return true
        }
        pendingToken = ""
        return character == " "
    }

    /// Enters `target` (⌘1–9, a strip click, a `.x` alias, a page link).
    /// Home is the global search at rest, so entering it leaves instead.
    func enter(_ target: PanelModule, filter: String = "", select id: String? = nil, openDetail: Bool = false) {
        guard target != .home else {
            leave()
            return
        }
        remember()
        module = target
        text = filter
        pendingToken = ""
        selection = id ?? remembered[target]
        detailOpen = openDetail && selection != nil
        dropStack()
        clearMarks()
    }

    /// Back to the global search — Home once nothing is typed.
    func leave(keeping text: String = "") {
        remember()
        module = nil
        self.text = text
        pendingToken = ""
        selection = nil
        detailOpen = false
        dropStack()
        clearMarks()
    }

    /// Moves the highlight; nil hands ↵ back to the field and closes the detail.
    /// A plain move ends a ⇧ extension: the next one starts from here.
    func select(_ id: String?) {
        if id != selection { dropStack() }
        selection = id
        if id == nil { detailOpen = false }
        markAnchor = nil
    }

    func openDetail(_ id: String) {
        if id != selection { dropStack() }
        selection = id
        detailOpen = true
    }

    func closeDetail() {
        detailOpen = false
        dropStack()
    }

    func toggleInspector() {
        inspectorOpen.toggle()
    }

    private func remember() {
        guard let module else { return }
        remembered[module] = selection
    }

    /// The selection `module` had when it was left — a warm body's frozen one.
    func rememberedSelection(_ module: PanelModule) -> String? {
        remembered[module]
    }

    // MARK: - Marks (bulk actions D1)

    /// The rows marked for a bulk verb in the entered module, by object id
    /// and apart from the cursor. They belong to the module: entering
    /// another, leaving and a restored place drop them, and no place keeps them.
    private(set) var marks: Set<String> = []
    /// Where a ⇧ extension began, and the marks it extends (Finder's range).
    private var markAnchor: String?
    private var marksBeforeExtension: Set<String> = []
    /// The destructive bulk verb whose confirm is open (bulk D2): Esc
    /// cancels it before it drops the marks.
    private(set) var confirming: String?

    func confirm(_ verb: String?) {
        confirming = verb
    }

    /// ⌘-click, or a click on a row's check: the row joins or leaves the
    /// marks and the cursor follows it. Marking closes the detail — the
    /// bulk pane takes its place.
    func toggleMark(_ id: String) {
        moveCursor(to: id)
        if !marks.insert(id).inserted { marks.remove(id) }
        markAnchor = id
        marksBeforeExtension = marks
    }

    /// ⇧-click: every markable row from the cursor (or where the last
    /// extension began) to `id`, on top of the marks before it.
    func markRange(to id: String, in markable: [String]) {
        guard markable.contains(id) else { return }
        beginExtension(at: selection.flatMap { markable.contains($0) ? $0 : nil } ?? id, in: markable)
        moveCursor(to: id)
        extendMarks(to: id, in: markable)
    }

    /// ⇧↑ / ⇧↓: the cursor moves through `items` and the markable rows
    /// between it and where the run began are marked; turning back unmarks
    /// what the run passed.
    func extendMarks(_ step: Int, in items: [String], markable: [String]) {
        guard !items.isEmpty else { return }
        let index = selection.flatMap { items.firstIndex(of: $0) }
        let next = index.map { items[min(max($0 + step, 0), items.count - 1)] } ?? (step > 0 ? items[0] : items[items.count - 1])
        beginExtension(at: selection.flatMap { items.contains($0) ? $0 : nil } ?? next, in: items)
        moveCursor(to: next)
        extendMarks(to: next, in: items, markable: markable)
    }

    /// ⌘A: every markable row the list draws — type a filter first to
    /// narrow. With every one of them marked already, ⌘A unmarks.
    func markAll(_ markable: [String]) {
        guard !markable.isEmpty else { return }
        closeDetail()
        marks = marks.isSuperset(of: markable) ? [] : Set(markable)
        markAnchor = nil
    }

    func clearMarks() {
        marks = []
        markAnchor = nil
        marksBeforeExtension = []
        confirming = nil
    }

    private func beginExtension(at anchor: String, in items: [String]) {
        guard markAnchor.map({ !items.contains($0) }) ?? true else { return }
        markAnchor = anchor
        marksBeforeExtension = marks
    }

    private func extendMarks(to id: String, in items: [String], markable: [String]? = nil) {
        guard let anchor = markAnchor, let from = items.firstIndex(of: anchor), let to = items.firstIndex(of: id)
        else { return }
        let range = items[min(from, to) ... max(from, to)].filter { markable?.contains($0) ?? true }
        marks = marksBeforeExtension.union(range)
    }

    /// The cursor moves without ending the extension `select` would end.
    /// The detail closes with every card on it — a hidden card must not
    /// keep ⌘↵.
    private func moveCursor(to id: String) {
        selection = id
        closeDetail()
    }

    // MARK: - The stack (stay in Pultík D2, D3, D11)

    /// The cards over the detail, bottom first: a CI run over its PR. Esc
    /// slides the top one away; a new selection or a closed detail drops all.
    private(set) var stack: [DetailRef] = []
    /// ⇥'s focus on the top layer (D3): one of `focusTargets`, ringed.
    private(set) var focus: String?
    /// The top layer's targets in ⇥ order, as its view draws them — run
    /// badges, then open threads, then files (`setFocusTargets`).
    private(set) var focusTargets: [String] = []
    /// The focus each card was pushed from, restored when it pops.
    private var focusBeneath: [String?] = []
    /// The top card's columns as its view draws them (jobs, steps, log).
    private(set) var cardColumns: [[String]] = []
    /// A focused target ↵ activated that is not a card (a file folds open):
    /// the layer's view acts on it and clears it.
    private(set) var activated: String?

    /// The top layer's view reports what ⇥ walks; a focus it no longer
    /// draws is dropped.
    func setFocusTargets(_ targets: [String]) {
        guard targets != focusTargets else { return }
        focusTargets = targets
        if let focus, !targets.contains(focus) { self.focus = nil }
    }

    /// ⇥ (+1) / ⇧⇥ (−1): the next target, wrapping; from none, the first
    /// (or the last).
    func moveFocus(_ step: Int) {
        guard !focusTargets.isEmpty else { return }
        guard let focus, let index = focusTargets.firstIndex(of: focus) else {
            self.focus = step > 0 ? focusTargets.first : focusTargets.last
            return
        }
        let count = focusTargets.count
        self.focus = focusTargets[((index + step) % count + count) % count]
    }

    func clearFocus() {
        focus = nil
    }

    /// ↵ on the focused target: a run badge slides its card over the PR;
    /// anything else is the layer's own (`activated`).
    func activateFocus() {
        guard let focus else { return }
        if let card = DetailRef(target: focus) {
            push(card)
        } else {
            activated = focus
        }
    }

    func consumeActivation() {
        activated = nil
    }

    func push(_ card: DetailRef) {
        guard detailOpen, stack.last != card else { return }
        focusBeneath.append(focus)
        stack.append(card)
        focus = nil
        focusTargets = []
        cardColumns = []
    }

    /// Esc on a card: it slides away and the target it was opened from is
    /// focused again.
    func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        cardColumns = []
        focusTargets = []
        focus = focusBeneath.popLast() ?? nil
    }

    /// The top card's view reports its columns; the walk stays inside them.
    func setCardColumns(_ columns: [[String]]) {
        guard columns != cardColumns, var top = stack.last else { return }
        cardColumns = columns
        top.column = min(top.column, max(columns.count - 1, 0))
        for index in columns.indices {
            if let picked = top.picks[index], !columns[index].contains(picked) { top.picks[index] = nil }
        }
        stack[stack.count - 1] = top
    }

    /// ↑/↓ in the top card's column.
    func moveInCard(_ step: Int) {
        guard var top = stack.last, cardColumns.indices.contains(top.column) else { return }
        let items = cardColumns[top.column]
        guard !items.isEmpty else { return }
        let index = top.picks[top.column].flatMap { items.firstIndex(of: $0) }
        let next = index.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
        top.picks[top.column] = items[next]
        stack[stack.count - 1] = top
    }

    /// ⇥ / ⇧⇥ between the top card's columns.
    func moveCardColumn(_ step: Int) {
        guard var top = stack.last, !cardColumns.isEmpty else { return }
        top.column = min(max(top.column + step, 0), cardColumns.count - 1)
        stack[stack.count - 1] = top
    }

    /// ↵ in a column narrows the next one (D11): never a mutation.
    func openInCard() {
        guard var top = stack.last, top.column + 1 < max(cardColumns.count, 1) else { return }
        guard top.picks[top.column] != nil else { return moveInCard(1) }
        top.column += 1
        stack[stack.count - 1] = top
    }

    // MARK: - The place (D1)

    /// Where the panel is — what a summon restores.
    struct Place: Equatable, Sendable {
        var module: PanelModule?
        var filter = ""
        var selection: String?
        var detailOpen = false
        var inspectorOpen = false
        var stack: [DetailRef] = []

        static let home = Place()
    }

    var place: Place {
        // The global query is no place: typing on Home is transient.
        Place(module: module, filter: module == nil ? "" : text, selection: module == nil ? nil : selection,
              detailOpen: module == nil ? false : detailOpen, inspectorOpen: inspectorOpen,
              stack: module == nil ? [] : stack)
    }

    func restore(_ place: Place) {
        if place.module == nil { leave() } else {
            remember()
            module = place.module
            text = place.filter
            pendingToken = ""
            selection = place.selection
            detailOpen = place.detailOpen && place.selection != nil
            stack = detailOpen ? place.stack : []
        }
        clearMarks()
        inspectorOpen = place.inspectorOpen
        focus = nil
        focusTargets = []
        focusBeneath = Array(repeating: nil, count: stack.count)
        cardColumns = []
        activated = nil
    }

    /// A different object, a closed detail or another module: no card or
    /// focus outlives what it was over.
    private func dropStack() {
        stack = []
        focusBeneath = []
        focus = nil
        focusTargets = []
        cardColumns = []
        activated = nil
    }
}

/// One card on the detail stack (D2): today a CI run over its change
/// request. `column` and `picks` are the run card's walk (D11): jobs, steps,
/// log, and what each column has picked.
struct DetailRef: Hashable, Sendable {
    enum Kind: String, Sendable {
        case run
    }

    let kind: Kind
    /// The object's host-qualified key (`CIRunRef.key`).
    let id: String
    var column = 0
    var picks: [Int: String] = [:]

    init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// A focus target that opens as a card: `run:<CIRunRef.key>`.
    init?(target: String) {
        guard target.hasPrefix("run:") else { return nil }
        self.init(kind: .run, id: String(target.dropFirst(4)))
    }

    /// Cards are the same object whatever their walk.
    static func == (lhs: DetailRef, rhs: DetailRef) -> Bool { lhs.kind == rhs.kind && lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}
