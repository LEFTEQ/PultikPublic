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
            // A canvas has no rows to filter: a filter naming a list's slice shows that list (D20).
            if let module, view?.canvas != nil, let list = module.view(filtering: value) { showView(list) }
        case let .enter(target, filter, rest, opens):
            // An alias's object lives on the module's first view (`.m`, `.f`: Machines);
            // a filter naming a list's slice lands on that list (`.c failed`: Runs, D20).
            enter(target, filter: filter, select: opens, openDetail: opens != nil,
                  view: opens == nil ? target.view(filtering: filter) : target.views.first)
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
    /// `view` shows that body first: the one that lists `id`.
    func enter(_ target: PanelModule, filter: String = "", select id: String? = nil, openDetail: Bool = false,
               view: ModuleView? = nil)
    {
        guard target != .home else {
            leave()
            return
        }
        remember()
        if let view, target.views.contains(view), view != self.view(of: target) {
            // The view being left keeps its cursor for ⇥ back.
            viewSelections[Self.viewKey(target, self.view(of: target))] = remembered[target]
            remembered[target] = viewSelections[Self.viewKey(target, view)]
            views[target] = view
        }
        module = target
        text = filter
        pendingToken = ""
        selection = id ?? remembered[target]
        detailOpen = openDetail && selection != nil
        entered = false
        canvasEntered = false
        tab = nil
        dropStack()
        clearMarks()
    }

    /// A `pultik://pr/…` link (another app, a notification, a reference in a
    /// description): the PR's detail in PRs, an inbox row by its own id
    /// (`inboxID`), any other by `archive:` (stay in Pultík: never the browser).
    func openPR(repo: String, number: Int, inboxID: String?) {
        enter(.prs, filter: "", select: inboxID.map { "pr:\($0)" } ?? "archive:\(repo)#\(number)", openDetail: true)
    }

    /// Back to the global search — Home once nothing is typed.
    func leave(keeping text: String = "") {
        remember()
        module = nil
        self.text = text
        pendingToken = ""
        selection = nil
        detailOpen = false
        entered = false
        canvasEntered = false
        dropStack()
        clearMarks()
    }

    /// Moves the highlight; nil hands ↵ back to the field and closes the detail.
    /// A plain move ends a ⇧ extension: the next one starts from here.
    func select(_ id: String?) {
        if id != selection { dropStack() }
        selection = id
        if id == nil { detailOpen = false }
        entered = false
        markAnchor = nil
    }

    /// `entering`: ↵ asked, and the module's detail is a workbench — it
    /// opens entered (PR workbench D5). A click opens it without entering.
    /// A detail opened from closed starts on its first tab.
    func openDetail(_ id: String, entering: Bool = false) {
        if id != selection { dropStack() }
        if !detailOpen { tab = nil }
        selection = id
        detailOpen = true
        entered = entering && module.map(Self.workbenches.contains) == true
    }

    func closeDetail() {
        detailOpen = false
        entered = false
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

    // MARK: - Views (vt-7727 D1, D5)

    /// The body each module shows: ⇥/⇧⇥ cycle it, and it outlives leaving
    /// the module and a summon (`Place.view`). Absent = the module's first.
    private(set) var views: [PanelModule: ModuleView] = [:]
    /// Each view's cursor while another view shows, by `viewKey`.
    private var viewSelections: [String: String] = [:]

    func view(of module: PanelModule) -> ModuleView? {
        views[module] ?? module.views.first
    }

    /// The entered module's view; nil on Home or a module with one body.
    var view: ModuleView? { module.flatMap(view(of:)) }

    private static func viewKey(_ module: PanelModule, _ view: ModuleView?) -> String {
        "\(module.rawValue).\(view?.rawValue ?? "")"
    }

    /// ⇥ (+1) / ⇧⇥ (−1): the entered module's next view, wrapping.
    func cycleView(_ step: Int) {
        guard let module, let current = view, let index = module.views.firstIndex(of: current) else { return }
        let count = module.views.count
        showView(module.views[((index + step) % count + count) % count])
    }

    /// A view's own list: the filter stays, the cursor is the one that view
    /// last had, and the detail, cards and marks of the other view close.
    func showView(_ next: ModuleView) {
        guard let module, module.views.contains(next), next != view else { return }
        viewSelections[Self.viewKey(module, view)] = selection
        views[module] = next
        selection = viewSelections[Self.viewKey(module, next)]
        detailOpen = false
        entered = false
        canvasEntered = false
        tab = nil
        dropStack()
        clearMarks()
    }

    // MARK: - Canvas views (vt-7727 D5)

    /// ↵ entered the shown Timeline or Map: ←/→, − / =, N and ↵ are the
    /// canvas's, and a mark's card slides over it. Esc leaves it with the
    /// view still shown; another view, module or a summon past the place drop it.
    private(set) var canvasEntered = false

    func enterCanvas() {
        guard view?.canvas != nil else { return }
        canvasEntered = true
    }

    /// Esc inside the canvas: its cards go with it.
    func leaveCanvas() {
        canvasEntered = false
        dropStack()
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

    /// Over the open detail, or over the entered canvas (a mark's card).
    func push(_ card: DetailRef) {
        guard detailOpen || canvasEntered, stack.last != card else { return }
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

    // MARK: - The workbench (PR workbench D5, D6)

    /// Modules whose detail is a workbench: ↵ opens it entered.
    nonisolated static let workbenches: Set<PanelModule> = [.prs]

    /// ↵ entered the open detail: ←/→ walk its tabs, ↑/↓ scroll the tab and
    /// letters are its verbs. Esc leaves it and the detail stays open, so
    /// the next ↓ walks the list on.
    private(set) var entered = false
    /// The detail's tabs as its view draws them (`setTabs`), and the one
    /// picked; nil is the first. It stays while the list is walked with the
    /// detail open, and resets when a detail opens from closed.
    private(set) var tabs: [String] = []
    private(set) var tab: String?
    /// The letters the entered detail takes as verbs, as its view reports them.
    private(set) var verbKeys: Set<String> = []
    /// The latest scroll the keys asked for; the shown tab's scroller applies
    /// each serial once.
    private(set) var scrollRequest: ScrollRequest?
    /// A verb asked for by its letter, or ⌘K's menu; the workbench takes it.
    private(set) var verbRequest: VerbRequest?

    var shownTab: String? { tab ?? tabs.first }

    func setTabs(_ tabs: [String]) {
        guard tabs != self.tabs else { return }
        self.tabs = tabs
        if let tab, !tabs.contains(tab) { self.tab = nil }
    }

    /// ←/→ inside the detail: the next tab, wrapping. The new tab reports its
    /// own ⇥ targets, so the ring does not travel with it.
    func moveTab(_ step: Int) {
        guard !tabs.isEmpty else { return }
        let index = shownTab.flatMap { tabs.firstIndex(of: $0) } ?? 0
        let count = tabs.count
        showTab(tabs[((index + step) % count + count) % count])
    }

    /// A tab's click: shows it and enters the detail.
    func selectTab(_ name: String) {
        showTab(name)
        if detailOpen, module.map(Self.workbenches.contains) == true { entered = true }
    }

    private func showTab(_ name: String) {
        guard name != shownTab else { return }
        tab = name
        focus = nil
        focusTargets = []
    }

    /// ↵ on a workbench's open detail.
    func enterDetail() {
        guard detailOpen, stack.isEmpty, module.map(Self.workbenches.contains) == true else { return }
        entered = true
    }

    /// Esc inside the detail: back to the list, the detail still shown.
    func leaveDetail() {
        entered = false
        focus = nil
    }

    func setVerbKeys(_ keys: Set<String>) {
        guard keys != verbKeys else { return }
        verbKeys = keys
    }

    func scroll(_ amount: ScrollAmount) {
        scrollRequest = ScrollRequest(amount: amount, serial: (scrollRequest?.serial ?? 0) &+ 1)
    }

    /// `key` is the verb's letter, or `VerbRequest.menu` for ⌘K.
    func requestVerb(_ key: String) {
        verbRequest = VerbRequest(key: key, serial: (verbRequest?.serial ?? 0) &+ 1)
    }

    func consumeVerb() {
        verbRequest = nil
    }

    /// ⌘⇧F, F12 or ⇧F12 on the shown code canvas (D2, D3): the Files tab
    /// takes it.
    private(set) var codeRequest: CodeRequest?

    func requestCode(_ kind: CodeRequest.Kind) {
        codeRequest = CodeRequest(kind: kind, serial: (codeRequest?.serial ?? 0) &+ 1)
    }

    /// A workbench composer is open (its view says so): ⌘↵ submits it and
    /// Esc closes it first.
    private(set) var composing = false
    /// The latest key the open composer is asked to act on.
    private(set) var composerCommand: ComposerCommand?

    func setComposing(_ open: Bool) {
        guard open != composing else { return }
        composing = open
    }

    /// A verb's confirm is open (merge, close): ↵ inside it runs the verb.
    private(set) var verbConfirm = false

    func setVerbConfirm(_ open: Bool) {
        guard open != verbConfirm else { return }
        verbConfirm = open
    }

    func commandComposer(_ action: ComposerCommand.Action) {
        composerCommand = ComposerCommand(action: action, serial: (composerCommand?.serial ?? 0) &+ 1)
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
        /// Inside a workbench, and on which tab (PR workbench D5).
        var entered = false
        var tab: String?
        /// The module's view (vt-7727 D5), and whether its canvas was entered.
        var view: ModuleView?
        var canvasEntered = false

        static let home = Place()
    }

    var place: Place {
        // The global query is no place: typing on Home is transient.
        Place(module: module, filter: module == nil ? "" : text, selection: module == nil ? nil : selection,
              detailOpen: module == nil ? false : detailOpen, inspectorOpen: inspectorOpen,
              stack: module == nil ? [] : stack, entered: module == nil ? false : entered,
              tab: module == nil ? nil : tab, view: view, canvasEntered: module == nil ? false : canvasEntered)
    }

    func restore(_ place: Place) {
        if place.module == nil { leave() } else {
            remember()
            if let module = place.module, let view = place.view, module.views.contains(view) {
                views[module] = view
            }
            module = place.module
            text = place.filter
            pendingToken = ""
            selection = place.selection
            detailOpen = place.detailOpen && place.selection != nil
            canvasEntered = place.canvasEntered && view?.canvas != nil
            stack = detailOpen || canvasEntered ? place.stack : []
            entered = detailOpen && place.entered
            tab = place.tab
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
        /// A file at a commit (code navigation, D2): `repo@sha:path#line`.
        case file
        /// A mark on an entered canvas (vt-7727 D5): `<canvas slot>:<mark id>`.
        /// A job's card becomes `RunCard` once Semafor's jobs feed it (vt-7781 WP6).
        case mark
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

/// How far ↑/↓ move an entered detail's tab: a step (↑/↓), a page (⇧↑/⇧↓,
/// space) or to an edge (⌘↑/⌘↓); the sign is the direction.
enum ScrollAmount: Equatable, Sendable {
    case step(Int), page(Int), edge(Int)
}

struct ScrollRequest: Equatable, Sendable {
    let amount: ScrollAmount
    let serial: Int
}

struct CodeRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case search, definition, references }
    let kind: Kind
    let serial: Int
}

struct ComposerCommand: Equatable, Sendable {
    enum Action: Equatable, Sendable { case submit, close }
    let action: Action
    let serial: Int
}

struct VerbRequest: Equatable, Sendable {
    /// ⌘K: every verb with its key.
    static let menu = "⌘K"
    let key: String
    let serial: Int
}
