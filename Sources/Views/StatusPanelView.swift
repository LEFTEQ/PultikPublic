import SwiftUI

enum OverviewURL {
    static let githubPulls = URL(string: "https://github.com/pulls")!
    static let sentryIssues = URL(string: "https://sentry.ops.example.invalid/organizations/sentry/issues/")!

    static func repoPulls(_ slug: String) -> URL {
        slug.split(separator: "/").reduce(URL(string: "https://github.com")!) { url, component in
            url.appending(path: String(component))
        }
        .appending(path: "pulls")
    }

    static func projectPulls(_ repos: [String]) -> URL {
        guard repos.count != 1 else { return repoPulls(repos[0]) }

        var components = URLComponents(url: githubPulls, resolvingAgainstBaseURL: false)!
        let scope = (["is:open", "is:pr"] + repos.map { "repo:\($0)" }).joined(separator: " ")
        components.queryItems = [URLQueryItem(name: "q", value: scope)]
        return components.url!
    }

    static func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            NSLog("pultik: failed to open overview URL %@", url.absoluteString)
        }
    }
}

/// The panel's wiring (copilot shell WP3): it owns the state and hands it to
/// `PanelShell` — the top bar, the body and the footer in the fixed frame.
/// The body is an entered module in its `ModuleFrame`, or the global search:
/// Home at rest, results once typed, and the palette's pages (`.t`, `.n`,
/// the todos tab, a project page) beside the side columns. `ModuleRouter`
/// holds where the panel is; `KeyboardCoordinator` routes every key.
struct StatusPanelView: View {
    let store: StatusStore
    /// Show/hide signal from the warm panel — this view lives through quick
    /// summons until the idle release, so per-open work hangs off this, not
    /// off `onAppear`.
    let session: PanelSession
    /// Which of Now first's PR-tile folds are open — repo slugs for their
    /// ready lines, `PRDigest.foldKey` for drafts · stale.
    @State var homeExpanded: Set<String> = []
    /// Home's open Now folds and ×N series (D15), by row key. Kept here so
    /// keyboard selection walks exactly the rows on screen.
    @State var nowExpanded: Set<String> = []
    /// A selected Now row that left the queue, held in place until the next
    /// arrow (`HomeNow.swift`).
    @State var nowTombstone: NowTombstone?

    /// The entered module, the field's text, the selection and the detail.
    @State var router = ModuleRouter()
    @FocusState var paletteFocused: Bool
    let keyToken = UUID()

    /// The field's text: the global query, or the entered module's filter.
    /// Writing it applies the dot grammar (`.c failed` enters CI).
    var query: String {
        get { router.text }
        nonmutating set { router.type(newValue) }
    }

    /// The highlighted row's id. nil = the text field owns ↵ (open the best
    /// deterministic match); non-nil = ↵ activates that row.
    ///
    /// Deliberately an id and not an index: `isSelected` runs once per row per
    /// render, and resolving an index would mean rebuilding the whole item list
    /// each time — O(n²) filtering + string-lowercasing every PR title, which
    /// is exactly what made the list stutter. A string compare is free, and the
    /// selection now survives the list changing under it.
    var selectedID: String? {
        get { router.selection }
        nonmutating set { router.select(newValue) }
    }
    var links: LinkStore {
        LinkStore.shared
    }

    var notes: NoteStore {
        NoteStore.shared
    }

    /// Feedback line for the last slash command ("saved “Grafana”").
    @State var commandNotice: SlashResult?
    /// A pasted path, repaired and checked on disk (decision log
    /// 2026-09-03). Set from the query `onChange`, not computed per render:
    /// detection stats the disk.
    @State var pathTarget: PathTarget?
    /// Which of `pathTarget.verbs` ↵ runs; ⇥ moves it.
    @State var pathVerbIndex = 0

    @State var eveOnline: Bool?
    @State var eveAskedPrompt: String?
    @State var eveReply = ""
    @State var eveDone = false
    @State var eveError: String?
    @State var eveExpanded = false
    @State var askTask: Task<Void, Never>?
    @State var activeProject: ProjectSpec?
    /// AppStorage so the tab survives panel close/reopen and app relaunch —
    /// `panelDidDismiss` deliberately leaves it alone, matching the old
    /// rebuilt-per-summon behavior where only this survived.
    @AppStorage("todosTabOpen") var showTodos = false
    var todoStore: TodoStore {
        TodoStore.shared
    }

    var resolvedStore: ResolvedStore {
        ResolvedStore.shared
    }

    var prodArchive: ProdArchive {
        ProdArchive.shared
    }

    /// Ids resolved BEFORE this panel opened — hidden entirely. A resolve
    /// made while the panel is up only dims (⇥ can still undo it).
    @State var hiddenResolved: Set<String> = []
    /// The note expanded in the CENTER column (results section or `.notes`),
    /// and the one expanded in the rail — independent, so reading a note in
    /// one column never unfolds its twin in the other. Both live here because
    /// Esc has to be able to fold whichever is open.
    @State var expandedNoteID: String?
    /// The note being edited in `.notes` — Esc cancels the edit before it is
    /// allowed to close the panel.
    @State var editingNoteID: String?

    /// The palette page the global query names (`.t`, `.n`, `.p`…). A mode
    /// that is a module's alias never lands here — the router enters the
    /// module the moment its token is typed.
    var activeMode: (mode: PaletteMode, filter: String)? {
        guard router.module == nil, let parsed = PaletteMode.parse(query), parsed.mode.module == nil else { return nil }
        return (parsed.mode, parsed.filter)
    }

    /// "." (or an ambiguous partial) shows the mode picker instead.
    var modePickerMatches: [PaletteMode] {
        guard router.module == nil, query.hasPrefix("."), PaletteMode.parse(query) == nil else { return [] }
        let token = query.dropFirst().prefix(while: { !$0.isWhitespace }).lowercased()
        return PaletteMode.allCases.filter { token.isEmpty || $0.rawValue.hasPrefix(token) }
    }

    /// A widget opens its page pre-filtered (`.work overdue`, `.devbox pultik`)
    /// through the same query text a typed mode uses; a module's alias
    /// enters the module with the filter in its field.
    func enterMode(_ mode: PaletteMode, filter: String = "") {
        query = ".\(mode.rawValue) \(filter)"
        DispatchQueue.main.async { moveCaretToEnd() }
    }

    /// Unread at the moment the panel opened — the open marks everything
    /// seen (badge clears), but the rail keeps these visually unread for the
    /// rest of the session, same contract as the resolved snapshot.
    @State var unreadAlertsSnapshot: Set<Int> = []
    /// True while this panel holds a tick on FanStore — see panelDidPresent/-Dismiss.
    @State var fanTicking = false
    /// True while this panel holds MacHealthStore's re-read, the same way.
    @State var macHealthWatching = false
    @State var presentedGeneration: Int?
    /// Measured chrome, subtracted from the panel's height below.
    @State var footerHeight: CGFloat = 0
    @State var topBarHeight: CGFloat = 0
    @State var centreChrome: CGFloat = 0
    var body: some View {
        PanelShell(current: stripModule, scope: searchScope,
                   signals: ModuleSignals.make(store: store, fanStore: FanStore.shared,
                                               macHealth: MacHealthStore.shared),
                   chatting: eveAskedPrompt != nil,
                   showsHints: selectedID == nil && query.isEmpty,
                   onSelectModule: selectModule,
                   topBarHeight: $topBarHeight, footerHeight: $footerHeight) {
            palette
        } content: {
            if let module = router.module, let page = modulePage(module) {
                // An entered module takes the whole body (D5-A: the strip is
                // the awareness, so no side column costs it width).
                hosted(page)
                    .frame(height: columnBudget)
            } else {
                globalBody
            }
        } footer: {
            PanelFooter(
                store: store,
                eveOnline: eveOnline,
                todoCount: todoStore.openTodos.count,
                // A module owns the body: leave it, or the tab would open unseen.
                onTodos: {
                    leaveModule()
                    showTodos = true
                },
                onMacHealth: { enterMode(.mac) }
            )
        }
        .environment(\.panelIsPresented, session.isPresented)
        // On the root, the search field's ancestor: it lives in the top bar,
        // and Esc from it must peel one layer, never fall through to the
        // panel's cancelOperation and close everything.
        .onExitCommand { escapeOneLayer() }
        // A click while the panel is already up: no new summon, so switch here.
        .onReceive(NotificationCenter.default.publisher(for: .pultikOpenProd)) { _ in
            if let key = AppDelegate.shared?.takePendingProdKey() { enterMode(.health, filter: key) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pultikOpenLink)) { _ in
            if let link = AppDelegate.shared?.takePendingLink() { openLink(link) }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            driveFromDebugger(note.userInfo ?? [:])
        }
        #endif
        .onPreferenceChange(CentreChromeKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - centreChrome) >= 1 { centreChrome = rounded }
        }
        .onAppear {
            // A cold summon can mark the session presented before the first
            // body appears. Warm summons use the session changes below.
            if session.isPresented { panelDidPresent() }
        }
        .onChange(of: session.generation) { panelDidPresent() }
        // A critical landing while the panel is open is on screen already —
        // the Firing rail has no unread styling to carry it, so it is seen.
        .onChange(of: store.firingAlerts) {
            if session.isPresented, store.isSectionVisible("firing") { store.markFiringSeen() }
        }
        // F6: a deployment turning red on an open panel is on the board
        // already, so its menu-bar dot must not pulse for it afterwards —
        // likewise when Hlídač comes back and the board reads true again.
        .onChange(of: store.prodDigest) {
            if session.isPresented, store.isSectionVisible("prod") { store.markProdSeen() }
        }
        .onChange(of: store.prodUnreachableSince) {
            if session.isPresented, store.isSectionVisible("prod") { store.markProdSeen() }
        }
        .onChange(of: session.isPresented) { _, presented in
            if !presented { panelDidDismiss() }
        }
        .onChange(of: NowStore.shared.queue) { old, new in nowQueueChanged(from: old, to: new) }
        .onChange(of: router.selection) { _, id in nowSelectionChanged(to: id) }
        .onDisappear { panelDidDismiss() }
    }

    /// Per-open work — what lived in `onAppear` back when every summon built a
    /// fresh view tree.
    func panelDidPresent() {
        guard presentedGeneration != session.generation else { return }
        presentedGeneration = session.generation
        // An ordered-out host can coalesce dismiss + reopen before SwiftUI
        // observes the hidden state. A fresh opening must reset regardless.
        panelDidDismiss()
        // The open this call belongs to. Anything asynchronous started here
        // must check it before writing state back: the view is permanently
        // mounted, so a late completion would otherwise land in a hidden
        // panel — or, after a fast dismiss/reopen, stomp the newer open.
        let generation = session.generation
        // Triage snapshot: what was resolved before THIS open stays
        // hidden; what gets resolved during it only dims.
        hiddenResolved = resolvedStore.snapshot()
        // Opening the panel is the read receipt: snapshot what was unread
        // (the rail keeps styling it), then clear the badge.
        if store.isSectionVisible("alerts") {
            unreadAlertsSnapshot = store.unreadAlertIds
            store.markAlertsSeen()
        }
        if store.isSectionVisible("firing") { store.markFiringSeen() }
        // The board shows every red deployment: their menu-bar dots stop pulsing.
        if store.isSectionVisible("prod") { store.markProdSeen() }
        // A prod notification click opened this summon: land on its row.
        if let key = AppDelegate.shared?.takePendingProdKey() { enterMode(.health, filter: key) }
        // A pultik:// click opened this summon: land on what it names.
        if let link = AppDelegate.shared?.takePendingLink() { openLink(link) }
        // Now's ages move and its Handled window slides with the clock; an
        // expiry window opens on the clock too, not on the radar's daily probe.
        ExpiryRadarStore.shared.recordNowNeeds()
        NowStore.shared.refresh()
        // Focus once the panel is key; a zero-delay hop is enough. The tree
        // outlives the summon now, so a dismiss inside those 50 ms would
        // otherwise re-focus a hidden palette — and leave the binding already
        // true on the next open, so no focus transition ever fires and the
        // keyboard goes nowhere. Only the open that scheduled it may focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard session.isPresented, session.generation == generation else { return }
            paletteFocused = true
        }
        // Every panel open is another request; while eve's breaker is open
        // the honest answer is "offline" without asking again — and an
        // answered probe reports its outcome, so repeated panel opens
        // can open the breaker (or close it on a half-open trial) instead
        // of knocking outside its books forever.
        Task {
            let gate = ProbeGate.shared
            switch gate.verdict(.eve) {
            case .hold:
                if isCurrentOpen(generation) { eveOnline = false }
            case .trial, .go:
                let failure = await EveClient.shared.probeHealth(settingsToken: store.eveToken)
                // The gate is told either way — a half-open trial that is not
                // reported never closes the breaker — but only the open that
                // asked may paint the answer.
                if let failure {
                    gate.failed(.eve, failure)
                } else {
                    gate.succeeded(.eve)
                }
                if isCurrentOpen(generation) { eveOnline = failure == nil }
            }
        }
        KeyboardCoordinator.claim(keyToken, context: { keyContext() }, perform: { perform($0, $1) })
        // Local SMC reads are cheap but pointless off-screen — tick only
        // while the panel is up. (The fan keep-alive runs independently.)
        // `!fanTicking` keeps the hold balanced if a present ever fires twice
        // without a dismiss between — an unmatched extra start would leak a
        // tick that outlives the panel.
        if store.isSectionVisible("fans"), !fanTicking {
            FanStore.shared.startTicking()
            fanTicking = true
        }
        // toolkit republishes once a minute; read on open, re-read while up.
        // Its fleet snapshot (Sessions, WP7) rides the same hold.
        if !macHealthWatching {
            MacHealthStore.shared.startWatching()
            FleetStore.shared.startWatching()
            macHealthWatching = true
        }
    }

    /// Is `generation` still the open on screen? Async work started by a
    /// present writes view state only while this holds — the tree is never
    /// torn down, so nothing else stops a stale completion.
    func isCurrentOpen(_ generation: Int) -> Bool {
        session.isPresented && session.generation == generation
    }

    /// Per-dismiss teardown AND state reset: the tree stays mounted between
    /// summons, so everything deallocation used to reset for free is reset
    /// here by hand — each ⌥Space still opens a fresh palette.
    func panelDidDismiss() {
        askTask?.cancel()
        askTask = nil
        KeyboardCoordinator.resign(keyToken)
        // Balanced with the conditional start above — an unmatched stop
        // would cancel someone else's hold on the tick (Settings' chart).
        if fanTicking {
            FanStore.shared.stopTicking()
            fanTicking = false
        }
        if macHealthWatching {
            MacHealthStore.shared.stopWatching()
            FleetStore.shared.stopWatching()
            macHealthWatching = false
        }
        paletteFocused = false
        // Each summon opens on Home; remembered selections survive.
        router.reset()
        nowTombstone = nil
        commandNotice = nil
        activeProject = nil
        pathTarget = nil
        pathVerbIndex = 0
        expandedNoteID = nil
        editingNoteID = nil
        unreadAlertsSnapshot = []
        // The eve conversation does not survive a dismiss (it never did) —
        // and dropping the reply text is also what keeps the hidden tree's
        // diffing and memory at panel-at-rest size.
        eveOnline = nil
        eveAskedPrompt = nil
        eveReply = ""
        eveDone = false
        eveError = nil
        eveExpanded = false
    }

    /// Esc from the field's own cancel: the same ladder the key monitor peels.
    func escapeOneLayer() {
        _ = perform(.escape(KeyboardCoordinator.escape(keyContext())))
    }

    // MARK: - Modules

    /// The strip's lift: the entered module, Home at rest, none on results
    /// and palette pages.
    var stripModule: PanelModule? {
        router.module ?? (showsHome ? .home : nil)
    }

    /// The entered module as the field's scope chip; none on Home.
    var searchScope: SearchScope? {
        router.module.map { module in
            SearchScope(title: module.title, symbol: module.symbol) { leaveModule() }
        }
    }

    /// ⌘1–9 or a strip click. Home is the global search at rest; picking the
    /// module already entered keeps its filter and selection.
    func selectModule(_ module: PanelModule) {
        if eveAskedPrompt != nil { dismissEve() }
        showTodos = false
        activeProject = nil
        guard module != router.module else { return }
        router.enter(module)
    }

    /// The scope chip's ×, ⌫ on an empty filter, a page's back chevron.
    func leaveModule() {
        router.leave()
    }

    /// Each module's list — the one place a module plugs into the shell.
    /// Each page draws its selected row, lists its objects in drawn order,
    /// and opens a clicked row's detail; the scope chip is the way back.
    func modulePage(_ module: PanelModule) -> (any ModulePage)? {
        let filter = router.text
        let selected = router.selection
        let open: (String) -> Void = { router.openDetail($0) }
        switch module {
        case .home:
            return nil
        case .prs:
            return PRListPage(store: store, filter: filter, hidden: hiddenResolved, selectedID: selected)
        case .ci:
            return CIPage(store: store, filter: filter, selectedID: selected)
        case .prod:
            return ProdMatrixPage(store: store, filter: filter, selectedID: selected, onOpen: open)
        case .devbox:
            return DevboxPage(store: store, filter: filter, selectedID: selected, onOpen: open)
        case .work:
            return WorkPage(store: store, filter: filter, selectedID: selected, onOpen: open)
        case .sessions:
            return SessionsPage(fleet: FleetStore.shared, store: store, listeners: modeVit(filter), filter: filter,
                                selectedID: selected, onOpen: open)
        case .estate:
            return EstatePage(store: store, filter: filter, selectedID: selected,
                              firing: estateFiring,
                              renewals: ExpiryRadarStore.shared.watched, onOpen: open)
        case .mac:
            return MacHealthPage(health: MacHealthStore.shared, fansShown: store.isSectionVisible("fans"),
                                 filter: filter, selectedID: selected, onOpen: open)
        }
    }

    func hosted(_ page: some ModulePage) -> AnyView {
        AnyView(ModuleHost(page: page, router: router))
    }

    /// The entered module's objects in drawn order; empty when global.
    var moduleObjects: [ModuleObject] {
        router.module.flatMap(modulePage)?.objects ?? []
    }

    /// Is the selected object's detail on screen (not just requested)?
    var detailShown: Bool {
        router.detailOpen && moduleObjects.contains { $0.id == router.selection }
    }

    /// A PR row on Home or in the global results: ↵ opens its detail in PRs
    /// (D6 "every need is one step from its action"). The search text comes
    /// along as the filter, so an archive hit stays in the list.
    func openPRDetail(_ id: String) {
        router.enter(.prs, filter: showsHome ? "" : query, select: id, openDetail: true)
    }

    /// A `pultik://` link: an inbox PR opens its detail; one the inbox does
    /// not hold (another author's, a repo not pinned) opens on GitHub.
    func openLink(_ link: PultikLink) {
        switch link {
        case let .pr(repo, number):
            let entry = store.inbox.first {
                $0.repoSlug.caseInsensitiveCompare(repo) == .orderedSame && $0.info.pr.number == number
            }
            if let entry {
                router.enter(.prs, filter: "", select: "pr:\(entry.id)", openDetail: true)
            } else if let url = link.webURL {
                OverviewURL.open(url)
            }
        }
    }

    // MARK: - Keyboard (`KeyboardCoordinator` routes, the panel performs)

    /// The ids ↑/↓ walk: the entered module's objects, else the palette's
    /// rows (Home's PR rows at rest).
    var keyItems: [String] {
        router.module == nil ? paletteItems.map(\.id) : moduleObjects.map(\.id)
    }

    /// The panel as the coordinator reads it, per keystroke. A PanelDriver
    /// event is addressed to the field by construction (`synthetic`).
    func keyContext(synthetic: Bool = false) -> KeyContext {
        let global = router.module == nil
        return KeyContext(
            fieldFocused: synthetic || paletteFocused,
            textViewFocused: !synthetic && !paletteFocused && NSApp.keyWindow?.firstResponder is NSTextView,
            module: router.module,
            text: query,
            pendingToken: router.pendingToken,
            items: keyItems,
            selection: selectedID,
            detailOpen: detailShown,
            pathCard: global && pathTarget != nil,
            completion: global && (!slashMatches.isEmpty || !modePickerMatches.isEmpty),
            notesDraft: activeMode.map { $0.mode == .notes && !$0.filter.isEmpty } ?? false,
            page: global && (showTodos || activeProject != nil),
            eve: eveAskedPrompt != nil,
            noteEditing: global && editingNoteID != nil,
            noteExpanded: global && expandedNoteID != nil
        )
    }

    /// Performs what the coordinator decided; false lets the key through to
    /// the field.
    func perform(_ intent: KeyIntent, _ event: NSEvent? = nil) -> Bool {
        switch intent {
        case let .module(module):
            selectModule(module)
        case let .select(id):
            selectedID = nowArrowTarget(id)
            // The field held focus the whole time, but the trip through the
            // list leaves its insertion point at 0 — put it back at the end,
            // where typing would naturally continue.
            if id == nil { moveCaretToEnd() }
        case let .openDetail(id):
            router.openDetail(id)
        case let .activate(id):
            guard let item = paletteItems.first(where: { $0.id == id }) else { return false }
            item.activate()
            if !item.keepsSelection { selectedID = nil }
        case let .openInBrowser(id):
            // Browser-only: a row without a page swallows ⌘↵ and does nothing —
            // it never falls back to the row's own ↵ (a quick command, a note,
            // a layout would run).
            let url = router.module == nil
                ? paletteItems.first { $0.id == id }?.url.flatMap { URL(string: $0) }
                : moduleObjects.first { $0.id == id }?.url
            if let url { OverviewURL.open(url) }
        case .toggleInspector:
            router.toggleInspector()
        case let .rerunFailed(id):
            // The detail's own verb: it fires only once the run it would
            // re-run has been read.
            guard let verb = moduleObjects.first(where: { $0.id == id })?.verbs.first(where: { $0.role == .primary })
            else { return false }
            verb.action()
        case .widenScope:
            leaveModule()
        case let .escape(step):
            peel(step)
        case .runPathVerb:
            // A chord picks a verb outright; handled here so ⌘↵ never
            // reaches the field editor.
            guard let target = pathTarget else { return false }
            runPathVerb(event.flatMap { PathVerb.forModifiers($0.modifierFlags) }
                ?? target.verbs[min(pathVerbIndex, target.verbs.count - 1)])
        case let .cyclePathVerb(step):
            guard let count = pathTarget?.verbs.count, count > 0 else { return false }
            pathVerbIndex = (pathVerbIndex + step + count) % count
        case let .triage(id):
            // The row dims now and disappears on the next panel open. The
            // `.notes` draft row is unsaved text, not an item — persisting its
            // id would outlive the draft. A Now row is open at its source —
            // dismissing it locally is not a resolution (contract "Handled").
            if id != Self.noteDraftID, !NowHomeRow.owns(id) { ResolvedStore.shared.toggle(id) }
        case .complete:
            // Exactly what the on-screen completion card promises.
            if let command = slashMatches.first {
                let completed = "/" + command.name + " "
                if query != completed {
                    query = completed
                    // The text change rebuilds the field — park the caret after it.
                    DispatchQueue.main.async { moveCaretToEnd() }
                }
            } else if let mode = modePickerMatches.first {
                enterMode(mode)
            } else {
                return false
            }
        case .createNote:
            guard let (mode, filter) = activeMode, mode == .notes, !filter.isEmpty else { return false }
            createNote(filter)
        case .paste:
            return pasteMultiline()
        case let .copyNote(id):
            // A note you can read but not retrieve is half a feature. Scoped
            // to the KEYBOARD-selected row: an expanded note is
            // text-selectable, and ⌘C there copies the words dragged over.
            guard let note = notes.notes.first(where: { "note:\($0.id)" == id }) else { return false }
            copyNote(note)
        case let .swallowToken(key):
            return router.swallowTokenKey(key)
        case .ignore:
            break
        }
        return true
    }

    /// One Esc (`KeyboardCoordinator.escape`): it never closes the panel
    /// while a layer remains.
    func peel(_ step: EscStep) {
        switch step {
        case .cancelNoteEdit:
            editingNoteID = nil
        case .foldNote:
            withAnimation(.easeOut(duration: 0.16)) { expandedNoteID = nil }
        case .dismissEve:
            dismissEve()
        case .clearText:
            // A mode, completion or path card exits; a filter empties.
            query = ""
        case .closeDetail:
            router.closeDetail()
        case .clearSelection:
            selectedID = nil
            moveCaretToEnd()
        case .closePage:
            if showTodos { showTodos = false } else { activeProject = nil }
        case .leaveModule:
            leaveModule()
        case .close:
            AppDelegate.shared?.closePanel()
        }
    }
}
