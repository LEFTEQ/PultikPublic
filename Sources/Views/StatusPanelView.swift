import SwiftUI

private enum OverviewURL {
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

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the footer strip — measured rather than hard-coded so the column
/// budget stays right if the chrome ever grows a line.
private struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the vitals dock, which sits below the right rail's scroller and
/// must keep its room when that scroller is capped.
private struct DockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Intrinsic heights of the two side columns' scrollers — measured on their
/// DEFINITE `ScrollColumn` frames, never on the stretched HStack cell. A
/// stretched cell measures the panel's height, which includes the centre
/// column itself: feeding that back into `centreCap` could never shrink, and
/// a rail folding away would leave the panel ratcheted tall forever.
private struct LeftColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RightRailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Everything in the centre column that sits OUTSIDE the capped list — the
/// palette, its hairline, and the pinned prod/links strips. Summed, not maxed:
/// these are stacked siblings, and the cap has to leave room for all of them.
private struct CentreChromeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    func measuringCentreChrome() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: CentreChromeKey.self, value: proxy.size.height)
            }
        )
    }
}

/// A rail column that scrolls inside a height budget instead of growing.
///
/// The panel body is `.fixedSize(vertical:)` — SwiftUI proposes nil height all
/// the way down, and a `ScrollView` handed a nil proposal reports its content's
/// full height and never scrolls. (`.frame(maxHeight:)` doesn't fix it: with no
/// finite proposal there is nothing for it to clamp against.) So the content is
/// measured and the scroller given a DEFINITE height: its content's, capped at
/// `maxHeight`. Short rails still size to their content — only a rail that
/// would overrun the screen becomes a scroller.
///
/// Internal, not fileprivate: every full-height left-column tab has to obey the
/// same rule, and `VitrinkaDailyRail` lives in its own file. A second copy would
/// drift into the rigid `.frame(height:)` this replaced.
struct ScrollColumn<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // Quantised for the same reason as the centre column: every write
        // re-renders the panel AND resizes the window, which re-pins it.
        .onPreferenceChange(ContentHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - measured) >= 1 { measured = rounded }
        }
        // Before the first measurement lands there is nothing to cap against —
        // stay unconstrained for that one pass rather than flashing a 1pt
        // column. The window's own clamp keeps even that frame on-screen.
        .frame(height: measured > 0 ? min(measured, maxHeight) : nil)
    }
}

/// Full-bleed native material for the borderless panel window.
private struct VibrancyBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

/// The panel's shell: Liquid Glass on macOS 26, the classic popover vibrancy
/// below. One modifier so the whole hub swaps chrome with the OS, not per-view.
private struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                .glassEffect(in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        } else {
            content
                .background(VibrancyBackground())
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}

/// The PR-first command center (redesign 2026-07-22): palette on top, the
/// cross-repo PR inbox in fixed repo order, a red prod strip pinned at the
/// bottom when Sentry is non-quiet, and a one-line status footer. Typing
/// filters the inbox; Eve is only invoked through `/ask <prompt>`.
struct StatusPanelView: View {
    let store: StatusStore
    /// Show/hide signal from the warm panel — this view lives through quick
    /// summons until the idle release, so per-open work hangs off this, not
    /// off `onAppear`.
    let session: PanelSession
    @State private var contentHeight: CGFloat = 200

    @State private var query = ""
    @FocusState private var paletteFocused: Bool
    /// The highlighted row's id. nil = the text field owns ↵ (open the best
    /// deterministic match); non-nil = ↵ activates that row.
    ///
    /// Deliberately an id and not an index: `isSelected` runs once per row per
    /// render, and resolving an index would mean rebuilding the whole item list
    /// each time — O(n²) filtering + string-lowercasing every PR title, which
    /// is exactly what made the list stutter. A string compare is free, and the
    /// selection now survives the list changing under it.
    @State private var selectedID: String?
    private let keyToken = UUID()
    @Namespace private var paletteMorph
    private var links: LinkStore {
        LinkStore.shared
    }

    private var notes: NoteStore {
        NoteStore.shared
    }

    /// Feedback line for the last slash command ("saved “Grafana”").
    @State private var commandNotice: SlashResult?
    /// A pasted path, repaired and checked on disk (decision log
    /// 2026-09-03). Set from the query `onChange`, not computed per render:
    /// detection stats the disk.
    @State private var pathTarget: PathTarget?
    /// Which of `pathTarget.verbs` ↵ runs; ⇥ moves it.
    @State private var pathVerbIndex = 0

    @State private var eveOnline: Bool?
    @State private var eveAskedPrompt: String?
    @State private var eveReply = ""
    @State private var eveDone = false
    @State private var eveError: String?
    @State private var eveExpanded = false
    @State private var askTask: Task<Void, Never>?
    @State private var activeProject: ProjectSpec?
    /// AppStorage so the tab survives panel close/reopen and app relaunch —
    /// `panelDidDismiss` deliberately leaves it alone, matching the old
    /// rebuilt-per-summon behavior where only this survived.
    @AppStorage("todosTabOpen") private var showTodos = false
    private var todoStore: TodoStore {
        TodoStore.shared
    }

    private var resolvedStore: ResolvedStore {
        ResolvedStore.shared
    }

    private var prodArchive: ProdArchive {
        ProdArchive.shared
    }

    /// Ids resolved BEFORE this panel opened — hidden entirely. A resolve
    /// made while the panel is up only dims (⇥ can still undo it).
    @State private var hiddenResolved: Set<String> = []
    /// The note expanded in the CENTER column (results section or `.notes`),
    /// and the one expanded in the rail — independent, so reading a note in
    /// one column never unfolds its twin in the other. Both live here because
    /// Esc has to be able to fold whichever is open.
    @State private var expandedNoteID: String?
    @State private var expandedRailNoteID: String?
    /// The note being edited in `.notes` — Esc cancels the edit before it is
    /// allowed to close the panel.
    @State private var editingNoteID: String?

    // MARK: - Palette modes ("." prefix — easy on a Czech keyboard, unlike ">")

    /// A scoped ALL-view the palette can enter: ".p" → every prod error,
    /// ".t" → every todo, ".v" → every listener. Text after the mode token
    /// filters within the mode. Esc exits.
    enum PaletteMode: String, CaseIterable {
        case todos, schedule, prod, vit, boards, issues, fans, notes, organize

        var title: String {
            switch self {
            case .todos: "All todos"
            case .schedule: "Schedule"
            case .prod: "All prod errors"
            case .vit: "Vitrinka listeners"
            case .boards: "Boards"
            case .issues: "GitHub issues"
            case .fans: "Fan deck"
            case .notes: "All notes"
            case .organize: "Organize workspaces"
            }
        }

        var blurb: String {
            switch self {
            case .todos: "vitrinka todos, every open item — all projects"
            case .schedule: "scheduled vitrinka todos — today, this week, later"
            case .prod: "sentry, last 12 days, staggered"
            case .vit: "boards a session is tuned into"
            case .boards: "recent vitrinka boards, newest first — all projects"
            case .issues: "search every issue in your repos"
            case .fans: "this Mac — fans, temps, vitals"
            case .notes: "scratch notes — read, edit, promote"
            case .organize: "route Warp windows to their displays — hammerspoon"
            }
        }

        var systemImage: String {
            switch self {
            case .todos: "checklist"
            case .schedule: "calendar.badge.clock"
            case .prod: "exclamationmark.triangle"
            case .vit: "dot.radiowaves.left.and.right"
            case .boards: "rectangle.on.rectangle"
            case .issues: "smallcircle.filled.circle"
            case .fans: "fanblades"
            case .notes: "square.text.square"
            case .organize: "rectangle.3.group"
            }
        }

        /// The palette's placeholder inside the mode. Issues are the one mode
        /// whose field searches GitHub rather than filtering what's loaded.
        var fieldHint: String {
            switch self {
            case .issues: "Search issues — text, or #812…"
            case .fans: "Filter sensors…"
            case .organize: "Layout — ↵ runs the top match…"
            default: "Filter \(title.lowercased())…"
            }
        }
    }

    /// ".prod redis" → (.prod, "redis"). A mode is entered the moment its
    /// prefix is unambiguous — ".p" is already prod, no ↵ needed.
    ///
    /// Static so the query's `onChange` can parse the incoming text directly
    /// instead of trusting `query` to have settled.
    static func paletteMode(in text: String) -> (mode: PaletteMode, filter: String)? {
        guard text.hasPrefix(".") else { return nil }
        let body = text.dropFirst()
        let token = body.prefix(while: { $0 != " " }).lowercased()
        guard !token.isEmpty else { return nil }
        let matches = PaletteMode.allCases.filter { $0.rawValue.hasPrefix(token) }
        guard matches.count == 1, let mode = matches.first else { return nil }
        let rest = body.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        return (mode, rest)
    }

    private var activeMode: (mode: PaletteMode, filter: String)? {
        Self.paletteMode(in: query)
    }

    /// "." (or an ambiguous partial) shows the mode picker instead.
    private var modePickerMatches: [PaletteMode] {
        guard query.hasPrefix("."), activeMode == nil else { return [] }
        let token = query.dropFirst().prefix(while: { $0 != " " }).lowercased()
        return PaletteMode.allCases.filter { token.isEmpty || $0.rawValue.hasPrefix(token) }
    }

    private func enterMode(_ mode: PaletteMode) {
        query = ".\(mode.rawValue) "
        DispatchQueue.main.async { moveCaretToEnd() }
    }

    /// Open todos narrowed by the palette — one query, every surface.
    private var filteredTodos: [TodoItem] {
        todoStore.openTodos.filter {
            $0.matches(query) && !hiddenResolved.contains("todo:\($0.id)")
        }
    }

    /// Notes matching the typed query. Unlike todos and listeners, notes have
    /// NO resting section: the rail is their glance, so they only enter the
    /// center column when you actually search for one.
    private var filteredNotes: [SavedNote] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.hasPrefix("."), !q.hasPrefix("/") else { return [] }
        return notes.ordered.filter { $0.matches(q) }
    }

    /// Active vitrinka listeners narrowed by the same query.
    private var filteredVitrinka: [VitrinkaListening] {
        store.vitrinkaListening.filter {
            $0.matches(query) && !hiddenResolved.contains("vit:\($0.id)")
        }
    }

    private var showDevbox: Bool {
        store.isSectionVisible("devbox")
            && (store.devboxSummary != nil || !(store.devboxWorkspaces.isEmpty && store.devboxProjects.isEmpty))
    }

    /// The left rail is devbox only since the VPS meters moved to the bottom
    /// bar — the cards duplicated numbers the bar now carries, and cost a rail
    /// of height to say it. It is also the first thing to fold when the screen
    /// is too narrow for all three columns (scaled laptop displays go below
    /// the 1240pt the full panel needs) — a hidden rail beats a window
    /// overhanging the screen edge.
    /// Vitrinka on top, Devbox below (spec 2026-09-09 decision 8); either
    /// having data keeps the column alive.
    private var showLeftRail: Bool {
        guard showDevbox || showVitrinkaRail else { return false }
        let needed: CGFloat = 680 + 280 + (showServiceRail ? 280 : 0)
        return PanelMetrics.shared.maxWidth >= needed
    }

    private var showVitrinkaRail: Bool {
        store.isSectionVisible("vitrinka")
            && store.vitrinkaWorkspaces.contains(where: { !$0.unavailable })
    }

    /// Todos worth interrupting for — overdue, inside their lead window, or
    /// milestone-ripe per the server (decision D4=B). A reminder that is not
    /// yet due is not yet information; a backend we cannot reach yields none,
    /// so the rail folds instead of alerting.
    private var reminders: [TodoItem] {
        RemindersRail.attentionWorthy(todoStore.reminderCandidates)
    }

    private var showRunnerSlots: Bool {
        store.isSectionVisible("runners") && !store.laneBoard.isEmpty
    }

    private var showAlerts: Bool {
        store.isSectionVisible("alerts") && !store.visibleAlerts.isEmpty
    }

    /// Unread at the moment the panel opened — the open marks everything
    /// seen (badge clears), but the rail keeps these visually unread for the
    /// rest of the session, same contract as the resolved snapshot.
    @State private var unreadAlertsSnapshot: Set<Int> = []
    /// True while this panel holds a tick on FanStore — see panelDidPresent/-Dismiss.
    @State private var fanTicking = false
    @State private var presentedGeneration: Int?
    /// The right rail carries service probes AND the CI slot queue — either
    /// having data keeps the column alive (both come from mesh Prometheus, so
    /// off-mesh they vanish together and the panel narrows).
    private var showServiceRail: Bool {
        (store.isSectionVisible("services") && !store.serviceStatuses.isEmpty)
            || showRunnerSlots
            || showAlerts
            // Links, notes and reminders are local — they must be able to hold
            // the rail open on their own, or off-mesh they'd vanish with the
            // probes. The vitals dock counts too: this Mac's fans are readable
            // with no network at all, and the dock is the only thing that
            // reports them since the fan strip was retired.
            || !links.links.isEmpty
            || !notes.notes.isEmpty
            || !reminders.isEmpty
            || (store.isSectionVisible("fans") && !FanStore.shared.fans.isEmpty)
    }

    private var panelWidth: CGFloat {
        680 + (showLeftRail ? 280 : 0) + (showServiceRail ? 280 : 0)
    }

    /// Measured chrome, subtracted from the screen budget below.
    @State private var footerHeight: CGFloat = 0
    @State private var dockHeight: CGFloat = 0
    /// Tallest a column may be before it has to scroll: the working area of the
    /// screen the panel is on (`PanelMetrics`), less the footer beneath it.
    /// The floor keeps the hub usable on a very short screen rather than
    /// collapsing the columns to nothing.
    private var columnBudget: CGFloat {
        max(280, PanelMetrics.shared.maxHeight - footerHeight - 1)
    }

    @State private var centreChrome: CGFloat = 0
    /// Intrinsic side-column heights — see LeftColumnHeightKey for why these
    /// are measured on the scrollers, not the stretched HStack cells.
    @State private var leftColumnHeight: CGFloat = 0
    @State private var rightRailsHeight: CGFloat = 0
    /// The centre list keeps its 560pt design cap on a roomy screen and gives
    /// it up only when the screen is shorter than that — or when a side rail
    /// has already made the panel taller: the panel's height is set by its
    /// tallest column, so a capped centre would just leave a dead zone under
    /// its last row while rows sit unread behind its scroller (2026-09-01).
    /// The screen budget still wins over both. The palette and the pinned
    /// strips are stacked outside this frame, so every bound subtracts them
    /// first or the column would overrun the cap it is supposed to obey.
    /// Full-height integration tabs share the left column.
    @ViewBuilder
    private var leftColumn: some View {
        VStack(spacing: 0) {
            if showVitrinkaRail && showDevbox {
                Picker("Left rail", selection: Binding(get: { store.leftRailTab }, set: { store.setLeftRailTab($0) })) {
                    Text("Vitrinka").tag("vitrinka")
                    Text("Devbox").tag("devbox")
                }
                .pickerStyle(.segmented)
                .padding(8)
            }
            if showVitrinkaRail && (store.leftRailTab == "vitrinka" || !showDevbox) {
                VitrinkaDailyRail(store: store, snapshots: store.vitrinkaWorkspaces,
                                  maxHeight: max(80, columnBudget - 42))
            } else if showDevbox {
                if let summary = store.devboxSummary {
                    MachineVitals(name: "Devbox VM", cpuCount: summary.cpus, cpuPercent: summary.cpuUsagePercent,
                                  memoryUsed: summary.memoryTotalBytes - summary.memoryAvailableBytes,
                                  memoryTotal: summary.memoryTotalBytes,
                                  diskUsed: summary.diskUsedBytes, diskTotal: summary.diskTotalBytes)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                ScrollColumn(maxHeight: max(80, columnBudget - 96)) {
                    DevboxRail(store: store,
                               workspaces: store.devboxWorkspaces,
                               projects: store.devboxProjects,
                               summary: store.devboxSummary,
                               fetchedAt: store.devboxFetchedAt)
                }
            }
        }
    }

    private var centreCap: CGFloat {
        let budget = max(160, columnBudget - centreChrome)
        let design = min(560, budget)
        let tallestSide = max(leftColumnHeight, rightRailsHeight + dockHeight)
        return max(design, min(max(0, tallestSide - centreChrome), budget))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if showLeftRail {
                    leftColumn
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: LeftColumnHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
                    .frame(width: 280)
                    // A fixed-width frame centers (never clips) an oversized
                    // child, so any row that escapes the rail would bleed into
                    // the centre column — clip here so it can't, whatever the
                    // data looks like.
                    .clipped()
                    hairlineV
                }
                centerColumn
                    .frame(width: 680)
                if showServiceRail {
                    hairlineV
                    // The dock is a SIBLING of the ScrollView, not content
                    // inside it: welded to the column's bottom edge, it must
                    // not scroll away with the rails stacked above it.
                    VStack(spacing: 0) {
                        ScrollColumn(maxHeight: max(120, columnBudget - dockHeight)) {
                            railsColumn
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: RightRailsHeightKey.self,
                                                       value: proxy.size.height)
                            }
                        )
                        Spacer(minLength: 0)
                        // The dock is welded to the bottom and does not scroll —
                        // except when it alone would eat the column (a long
                        // estate on a short screen), where scrolling it beats
                        // pushing the rails out of the panel entirely. Measured
                        // AFTER its own cap, so the rails' budget above can
                        // never be over-drawn.
                        ScrollColumn(maxHeight: columnBudget - 120) {
                            VitalsDock(store: store, fanStore: FanStore.shared)
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: DockHeightKey.self,
                                                       value: proxy.size.height)
                            }
                        )
                    }
                    .frame(width: 280)
                    .clipped()
                }
            }
            hairline
            PanelFooter(
                store: store,
                eveOnline: eveOnline,
                todoCount: todoStore.openTodos.count,
                onTodos: { showTodos = true }
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: FooterHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .environment(\.panelIsPresented, session.isPresented)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: panelWidth)
        .onPreferenceChange(FooterHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - footerHeight) >= 1 { footerHeight = rounded }
        }
        .onPreferenceChange(DockHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - dockHeight) >= 1 { dockHeight = rounded }
        }
        .onPreferenceChange(LeftColumnHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - leftColumnHeight) >= 1 { leftColumnHeight = rounded }
        }
        .onPreferenceChange(RightRailsHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - rightRailsHeight) >= 1 { rightRailsHeight = rounded }
        }
        .onPreferenceChange(CentreChromeKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - centreChrome) >= 1 { centreChrome = rounded }
        }
        .modifier(PanelChrome())
        .onAppear {
            // A cold summon can mark the session presented before the first
            // body appears. Warm summons use the session changes below.
            if session.isPresented { panelDidPresent() }
        }
        .onChange(of: session.generation) { panelDidPresent() }
        .onChange(of: session.isPresented) { _, presented in
            if !presented { panelDidDismiss() }
        }
        .onDisappear { panelDidDismiss() }
    }

    /// Per-open work — what lived in `onAppear` back when every summon built a
    /// fresh view tree.
    private func panelDidPresent() {
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
        PaletteKeyRouter.shared.claim(keyToken) { handleKey($0) }
        // Local SMC reads are cheap but pointless off-screen — tick only
        // while the panel is up. (The fan keep-alive runs independently.)
        // `!fanTicking` keeps the hold balanced if a present ever fires twice
        // without a dismiss between — an unmatched extra start would leak a
        // tick that outlives the panel.
        if store.isSectionVisible("fans"), !fanTicking {
            FanStore.shared.startTicking()
            fanTicking = true
        }
    }

    /// Is `generation` still the open on screen? Async work started by a
    /// present writes view state only while this holds — the tree is never
    /// torn down, so nothing else stops a stale completion.
    private func isCurrentOpen(_ generation: Int) -> Bool {
        session.isPresented && session.generation == generation
    }

    /// Per-dismiss teardown AND state reset: the tree stays mounted between
    /// summons, so everything deallocation used to reset for free is reset
    /// here by hand — each ⌥Space still opens a fresh palette.
    private func panelDidDismiss() {
        askTask?.cancel()
        askTask = nil
        PaletteKeyRouter.shared.resign(keyToken)
        // Balanced with the conditional start above — an unmatched stop
        // would cancel someone else's hold on the tick (Settings' chart).
        if fanTicking {
            FanStore.shared.stopTicking()
            fanTicking = false
        }
        paletteFocused = false
        query = ""
        selectedID = nil
        commandNotice = nil
        activeProject = nil
        pathTarget = nil
        pathVerbIndex = 0
        expandedNoteID = nil
        expandedRailNoteID = nil
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

    /// The original 680px panel — palette, prod strip, inbox (or a project
    /// page), CI footer — with the eve reply floating over the scroll area.

    /// The right rail's stacked sections — extracted so the scroller can be
    /// measured (RightRailsHeightKey) without burying the GeometryReader
    /// eight indentation levels deep in the body.
    private var railsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.isSectionVisible("services") && !store.serviceStatuses.isEmpty {
                RailSection(key: "services", title: "Services") {
                    ServiceRail(statuses: store.serviceStatuses,
                                hostOrder: store.serverNames)
                }
            }
            if !reminders.isEmpty {
                RailSection(key: "reminders", title: "Reminders",
                            count: reminders.count,
                            tone: reminders.contains(where: { $0.isOverdue() })
                                ? .red : .orange)
                {
                    RemindersRail(todos: reminders)
                }
            }
            if showRunnerSlots {
                // The Grafana escape hatch used to live on this
                // rail's kicker; the kicker is now RailSection's
                // collapse control, so the link becomes an
                // accessory rather than being lost.
                RailSection(
                    key: "runners", title: "CI · lanes",
                    count: store.laneBoard.running,
                    accessory: AnyView(
                        Button {
                            if let url = URL(string: "https://runners.ops.example.invalid") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("BuildServer JIT lane fleet — Grafana runners dashboard")
                    )
                ) {
                    LaneRail(board: store.laneBoard)
                }
            }
            if showAlerts {
                let unread = unreadAlertsSnapshot.union(store.unreadAlertIds)
                RailSection(key: "alerts", title: "eve alerts",
                            count: unread.count,
                            tone: unread.isEmpty ? .secondary : .orange)
                {
                    AlertsRail(alerts: store.visibleAlerts, unread: unread)
                }
            }
            if !links.links.isEmpty {
                // No count (D7=B): the list renders in full.
                RailSection(key: "links", title: "Links") {
                    LinksRail(links: links.ordered) { link in
                        links.recordOpen(id: link.id)
                        if let url = URL(string: link.url) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if !notes.notes.isEmpty {
                RailSection(key: "notes", title: "Notes") {
                    NotesRail(
                        notes: notes.ordered,
                        onRemove: { notes.remove(id: $0.id) },
                        onOpenAll: { enterMode(.notes) },
                        expandedID: $expandedRailNoteID
                    )
                }
            }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            // Asking eve turns the panel into a conversation: the field slides
            // from the top of the panel to the foot of the reply, where a chat
            // composer belongs. One field, two homes — matchedGeometryEffect
            // animates between them so it reads as the same object moving.
            if eveAskedPrompt == nil {
                palette.measuringCentreChrome()
                commandResults.measuringCentreChrome()
            }
            hairline.measuringCentreChrome()

            if let (mode, filter) = activeMode {
                modePage(mode, filter: filter)
                    .frame(height: centreCap)
            } else if showTodos {
                TodosPageView(todoStore: todoStore, todos: filteredTodos,
                              isSelected: { isSelected($0) },
                              selectedID: selectedID) { showTodos = false }
                    .frame(height: centreCap)
            } else if let project = activeProject {
                ProjectPageView(project: project, store: store) { activeProject = nil }
                    .frame(height: centreCap)
            } else {
                if store.pinned.isEmpty && query.isEmpty {
                    emptyState
                } else {
                    // A ScrollView in a borderless panel has no height to fill —
                    // measure the content and size the viewport to it, capped at
                    // `centreCap` (the 560pt design cap, or the screen if shorter).
                    ScrollViewReader { scroller in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                inbox
                                searchSection
                                sentrySection
                                notesSection
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                                }
                            )
                        }
                        // Sub-point jitter here is expensive, not cosmetic: every
                        // write re-renders the panel AND resizes the window, which
                        // re-pins it (StatusPanel.applyPin). Quantise to whole
                        // points so scrolling can't drive a resize feedback loop.
                        .onPreferenceChange(ContentHeightKey.self) { measured in
                            let rounded = measured.rounded()
                            if abs(rounded - contentHeight) >= 1 { contentHeight = rounded }
                        }
                        .frame(height: min(max(contentHeight, eveAskedPrompt != nil ? 320 : 0), centreCap))
                        // Arrowing past the viewport must pull the row into it;
                        // the palette and prod strip live outside this scroller
                        // and are always on screen, so their ids simply miss.
                        .onChange(of: selectedID) { _, _ in
                            guard let selectedID else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                scroller.scrollTo(selectedID, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // The pinned strips anchor the BOTTOM of the center column —
            // prod (Sentry) always in the same place regardless of how the
            // list above breathes, reference links at the very foot.
            if activeMode == nil, !showTodos, activeProject == nil, eveAskedPrompt == nil {
                prodStrip.measuringCentreChrome()
                linksStrip.measuringCentreChrome()
            }

            if eveAskedPrompt != nil {
                hairline.measuringCentreChrome()
                palette.measuringCentreChrome()
            }
        }
        .overlay(alignment: .top) {
            // Slash verbs and palette modes float OVER the list on glass —
            // they are transient completions, not content.
            if eveAskedPrompt == nil, !slashMatches.isEmpty || !modePickerMatches.isEmpty {
                floatingResults
                    .padding(.horizontal, 14)
                    .padding(.top, 46)
            } else if eveAskedPrompt == nil, let target = pathTarget {
                PathCard(target: target, highlighted: pathVerbIndex) { runPathVerb($0) }
                    .padding(.horizontal, 14)
                    .padding(.top, 46)
            }
        }
        .overlay(alignment: .top) {
            // Eve replies float OVER the dashboard instead of squeezing it.
            if eveAskedPrompt != nil {
                EveOverlay(
                    prompt: eveAskedPrompt ?? "",
                    reply: eveReply,
                    done: eveDone,
                    error: eveError,
                    expanded: $eveExpanded,
                    onDismiss: { dismissEve() }
                )
                // The composer moved to the foot of the panel, so the reply no
                // longer has to clear a search bar above it.
                .padding(.top, 8)
            }
        }
        .onExitCommand { escapeOneLayer() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            driveFromDebugger(note.userInfo ?? [:])
        }
        #endif
    }

    /// Esc peels the outermost layer: eve, a mode/verb/path card, the todos
    /// tab, a project page — and only then the panel.
    private func escapeOneLayer() {
        if eveAskedPrompt != nil {
            dismissEve()
        } else if query.hasPrefix(".") || query.hasPrefix("/") || pathTarget != nil {
            // Exit the mode / completion card, keep the panel.
            query = ""
        } else if showTodos {
            showTodos = false
        } else if activeProject != nil {
            activeProject = nil
        } else {
            AppDelegate.shared?.closePanel()
        }
    }

    #if DEBUG
    /// PanelDriver relay: the same state changes and key routing a typed
    /// query or keystroke would produce, minus the field editor.
    private func driveFromDebugger(_ info: [AnyHashable: Any]) {
        let cmd = info["cmd"] as? String
        switch cmd {
        case "query":
            query = info["text"] as? String ?? ""
        case "key":
            guard let name = info["key"] as? String,
                  let event = PanelDriver.keyEvent(named: name, mods: info["mods"] as? String) else { return }
            // What the monitor leaves alone would reach the field editor:
            // ↵ submits, Esc cancels. The rest are caret moves.
            guard handleKey(event, synthetic: true) != nil else { return }
            if name == "enter" { submitPalette() }
            if name == "esc" { escapeOneLayer() }
        case "state":
            guard let path = info["path"] as? String else { return }
            var state: [String: Any] = [
                "query": query,
                "selectedID": selectedID ?? NSNull(),
                "pathVerbIndex": pathVerbIndex,
                "commandNotice": commandNotice?.text ?? NSNull(),
                "activeMode": activeMode?.mode.rawValue ?? NSNull(),
                "eveAskedPrompt": eveAskedPrompt ?? NSNull(),
            ]
            if let target = pathTarget {
                state["pathTarget"] = [
                    "path": target.url.path,
                    "isDirectory": target.isDirectory,
                    "missing": target.missing ?? NSNull(),
                    "line": target.line ?? NSNull(),
                    "column": target.column ?? NSNull(),
                    "verbs": target.verbs.map(\.rawValue),
                ] as [String: Any]
            } else {
                state["pathTarget"] = NSNull()
            }
            PanelDriver.write(state: state, to: path)
        default:
            break
        }
    }
    #endif

    private var hairline: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var hairlineV: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }

    // MARK: - Palette

    private var palette: some View {
        let chatting = eveAskedPrompt != nil
        return HStack(spacing: 10) {
            Image(systemName: chatting ? "sparkles" : "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chatting ? Theme.eve : Color.secondary.opacity(0.6))
            TextField(paletteHint, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($paletteFocused)
                .onSubmit(submitPalette)
                .onChange(of: query) { _, new in
                    // New query, new result list — a stale index would point at
                    // a different PR than the one that was highlighted.
                    selectedID = nil
                    // A successful slash verb clears the field itself and
                    // the notice is its only feedback — only new typing
                    // retires it.
                    if !new.isEmpty { commandNotice = nil }
                    pathTarget = Self.detectPath(new)
                    pathVerbIndex = 0
                    // "/" and "." are command surfaces, not search text — a
                    // GitHub archive query for ".p" is pure noise. Nor is a
                    // pasted path.
                    let isPathShaped = PathTarget.looksLikePath(new)
                    store.search(new.hasPrefix("/") || new.hasPrefix(".") || isPathShaped ? "" : new)
                    // Issues are searched ONLY from inside their mode, so no
                    // keystroke anywhere else spends an issue-search call.
                    let issueFilter = Self.paletteMode(in: new)
                        .flatMap { $0.mode == .issues ? $0.filter : nil }
                    store.searchIssues(issueFilter ?? "")
                }
            if selectedID != nil {
                // ↵ belongs to the highlighted row now, not to eve — say so.
                Text("↵ open · ↑ back")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if query.isEmpty {
                if eveOnline == true {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("eve")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                KeyChip("⌥ ␣")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .matchedGeometryEffect(id: "palette", in: paletteMorph)
    }

    /// Typing "todo…" surfaces the todos tab. Prefix-only on purpose: a PR
    /// titled "fix todo list" must not hijack the search results.
    private var todosMatch: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        return "todos".hasPrefix(q) || q == "td"
    }

    private var paletteHint: String {
        if eveAskedPrompt != nil { return "Ask eve again…" }
        if let (mode, _) = activeMode { return mode.fieldHint }
        if showTodos { return "Search todos…" }
        return "Search PRs, repos…  (/ask for eve · \".\" for modes)"
    }

    private func submitPalette() {
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // Slash commands are explicit verbs — they run before any fuzzy match
        // gets a chance to reinterpret them.
        if let (command, argument) = SlashCommands.parse(prompt) {
            switch command.action {
            case .askEve:
                let evePrompt = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !evePrompt.isEmpty else {
                    commandNotice = .failed("usage: \(command.usage)")
                    return
                }
                guard eveOnline == true else {
                    commandNotice = .failed("eve is offline")
                    return
                }
                askEve(evePrompt)
                query = ""
            case .local:
                let result = command.run(argument)
                commandNotice = result
                if !result.isFailure { query = "" }
            }
            return
        }
        // A path card: the key router normally takes ↵ first, but a submit
        // that reaches here (no monitor, a synthetic submit) does the same.
        if let target = pathTarget {
            runPathVerb(target.verbs[min(pathVerbIndex, target.verbs.count - 1)])
            return
        }
        // Once `/ask` deliberately opened the conversation, this field is a
        // composer rather than a search box. Follow-ups stay conversational;
        // dismissing the overlay returns to the search-only contract.
        if eveAskedPrompt != nil {
            guard eveOnline == true else {
                commandNotice = .failed("eve is offline")
                return
            }
            askEve(prompt)
            query = ""
            return
        }
        // A mode's field is a filter — ↵ opens the top match; a partial mode
        // token completes.
        if let (mode, filter) = activeMode {
            switch mode {
            case .todos: modeTodos(filter).first?.open()
            case .schedule: modeSchedule(filter).first?.open()
            case .prod:
                if let issue = modeProd(filter).first { Self.open(issue.issue.permalink) }
            case .vit: modeVit(filter).first?.open()
            case .boards: modeBoards(filter).first?.open()
            case .issues:
                if let issue = modeIssues(filter).first { Self.open(issue.url) }
            case .notes:
                if let note = modeNotes(filter).first { toggleNote(note) }
            case .fans:
                break // the deck is controls, not a result list — ↵ is a no-op
            case .organize:
                // Bare ↵ runs "default" (names() sorts it first); unmatched
                // text runs literally — the Lua engine may know layouts the
                // settings file doesn't list yet.
                runOrganize(modeOrganize(filter).first ?? (filter.isEmpty ? "default" : filter))
            }
            return
        }
        if let mode = modePickerMatches.first {
            enterMode(mode)
            return
        }
        // Inside the todos tab the field is a filter — ↵ opens the top match.
        if showTodos {
            filteredTodos.first?.open()
            return
        }
        // Todos, then projects ("fix ↵" opens the ExampleApp on-call page), then
        // commands ("v ↵" opens vitrinka). Unmatched text remains a search.
        if todosMatch {
            query = ""
            showTodos = true
            return
        }
        if let project = store.matchProject(prompt) {
            query = ""
            activeProject = project
            return
        }
        if let command = QuickCommand.matching(prompt).first {
            query = ""
            command.run()
            AppDelegate.shared?.closePanel()
            return
        }
        return
    }

    // MARK: - Path card

    /// Path detection for the palette. Never while the text is (or is
    /// completing into) a slash verb — `/open` must not resolve to the
    /// nearest ancestor `/`.
    private static func detectPath(_ text: String) -> PathTarget? {
        guard PathTarget.looksLikePath(text) else { return nil }
        guard SlashCommands.parse(text) == nil, SlashCommands.matching(text).isEmpty else { return nil }
        return PathTarget.detect(text)
    }

    /// Runs a card verb and closes the panel — the destination is another
    /// app, exactly like a quick command.
    private func runPathVerb(_ verb: PathVerb) {
        guard let target = pathTarget else { return }
        let result = verb.run(target)
        guard !result.isFailure else {
            commandNotice = result
            return
        }
        query = ""
        pathTarget = nil
        pathVerbIndex = 0
        AppDelegate.shared?.closePanel()
    }

    // MARK: - Keyboard navigation (↓ ↑ walk the results, ↵ opens)

    /// One activatable result. The list is flattened in the exact visual order
    /// the panel renders — project match, quick commands, prod, inbox, archive —
    /// so ↓ never jumps somewhere the eye isn't.
    private struct PaletteItem {
        let id: String
        let activate: @MainActor () -> Void
        /// ↵ normally activates and drops the selection (the row opened a URL
        /// or a page, so there is nothing left to be selected). A note toggles
        /// its expansion in place — it has to stay selected, or the second ↵
        /// would have nothing to close.
        var keepsSelection = false

        init(id: String, keepsSelection: Bool = false, activate: @escaping @MainActor () -> Void) {
            self.id = id
            self.activate = activate
            self.keepsSelection = keepsSelection
        }
    }

    private var paletteItems: [PaletteItem] {
        // The project page and the eve overlay replace the result list; the
        // todos page keeps the keyboard — its rows ARE the result list there.
        guard activeProject == nil, eveAskedPrompt == nil else { return [] }
        if showTodos {
            return filteredTodos.map { todo in
                PaletteItem(id: "todo:\(todo.id)") { todo.open() }
            }
        }
        if let (mode, filter) = activeMode {
            switch mode {
            case .todos:
                return modeTodos(filter).map { todo in
                    PaletteItem(id: "todo:\(todo.id)") { todo.open() }
                }
            case .schedule:
                return modeSchedule(filter).map { todo in
                    PaletteItem(id: "todo:\(todo.id)") { todo.open() }
                }
            case .prod:
                return modeProd(filter).map { issue in
                    PaletteItem(id: "prod:\(issue.id)") { Self.open(issue.issue.permalink) }
                }
            case .vit:
                return modeVit(filter).map { entry in
                    PaletteItem(id: "vit:\(entry.id)") { entry.open() }
                }
            case .boards:
                return modeBoards(filter).map { board in
                    PaletteItem(id: "board:\(board.slug)") { board.open() }
                }
            case .issues:
                return modeIssues(filter).map { issue in
                    PaletteItem(id: "issue:\(issue.id)") { Self.open(issue.url) }
                }
            case .notes:
                return modeNotes(filter).map { note in
                    PaletteItem(id: "note:\(note.id)", keepsSelection: true) {
                        toggleNote(note)
                    }
                }
            case .fans:
                return []
            case .organize:
                return modeOrganize(filter).map { name in
                    PaletteItem(id: "organize:\(name)") { runOrganize(name) }
                }
            }
        }
        var items: [PaletteItem] = []
        for command in slashMatches {
            items.append(PaletteItem(id: "slash:\(command.name)") { completeSlash(command) })
        }
        for mode in modePickerMatches {
            items.append(PaletteItem(id: "mode:\(mode.rawValue)") { enterMode(mode) })
        }
        if !items.isEmpty { return items } // a completion card owns the keyboard
        if todosMatch {
            items.append(PaletteItem(id: "todos") {
                query = ""
                showTodos = true
            })
        }
        if let project = store.matchProject(query) {
            items.append(PaletteItem(id: "project:\(project.id)") {
                query = ""
                activeProject = project
            })
        }
        for command in QuickCommand.matching(query) {
            items.append(PaletteItem(id: "cmd:\(command.id)") {
                query = ""
                command.run()
                AppDelegate.shared?.closePanel()
            })
        }
        guard !(store.pinned.isEmpty && query.isEmpty) else { return items }
        // Matching the visual order exactly: PRs in fixed repo order, todos,
        // listeners, archive, then the pinned strips at the foot — prod, links.
        for entry in filteredInbox {
            items.append(PaletteItem(id: "pr:\(entry.id)") {
                Self.open(entry.info.pr.htmlUrl)
            })
        }
        for todo in filteredTodos {
            items.append(PaletteItem(id: "todo:\(todo.id)") { todo.open() })
        }
        for entry in filteredVitrinka {
            items.append(PaletteItem(id: "vit:\(entry.id)") { entry.open() })
        }
        if searchActive {
            for pr in store.searchMatches {
                items.append(PaletteItem(id: "archive:\(pr.id)") {
                    Self.open(pr.url)
                })
            }
            for issue in store.sentryMatches {
                items.append(PaletteItem(id: "sentry:\(issue.id)") {
                    Self.open(issue.issue.permalink)
                })
            }
        }
        for note in filteredNotes {
            items.append(PaletteItem(id: "note:\(note.id)", keepsSelection: true) {
                toggleNote(note)
            })
        }
        if store.isSectionVisible("prod") {
            for issue in filteredProdIssues.prefix(4) {
                items.append(PaletteItem(id: "prod:\(issue.id)") {
                    Self.open(issue.issue.permalink)
                })
            }
        }
        for link in filteredLinks.prefix(4) {
            items.append(PaletteItem(id: "link:\(link.id)") { openLink(link) })
        }
        return items
    }

    // MARK: - Floating completions (slash verbs + palette modes, on glass)

    private var slashMatches: [SlashCommand] {
        SlashCommands.matching(query)
    }

    /// The completion card floating OVER the list: slash verbs when typing
    /// "/", palette modes when typing ".". Arrow keys walk it (the rows are
    /// paletteItems), ↵/click completes into the field.
    private var floatingResults: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(slashMatches, id: \.name) { command in
                FloatingCompletionRow(
                    systemImage: "chevron.right.square",
                    primary: command.usage, primaryMono: true,
                    blurb: command.blurb,
                    selected: isSelected("slash:\(command.name)")
                ) { completeSlash(command) }
            }
            ForEach(modePickerMatches, id: \.rawValue) { mode in
                FloatingCompletionRow(
                    systemImage: mode.systemImage,
                    primary: ".\(mode.rawValue) — \(mode.title)", primaryMono: false,
                    blurb: mode.blurb,
                    selected: isSelected("mode:\(mode.rawValue)")
                ) { enterMode(mode) }
            }
        }
        .padding(5)
        .modifier(GlassCard())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    private func completeSlash(_ command: SlashCommand) {
        query = "/" + command.name + " "
        selectedID = nil
        DispatchQueue.main.async { moveCaretToEnd() }
    }

    // MARK: - Mode pages

    @ViewBuilder
    private func modePage(_ mode: PaletteMode, filter: String) -> some View {
        switch mode {
        case .todos:
            TodosPageView(todoStore: todoStore, todos: modeTodos(filter),
                          isSelected: { isSelected($0) },
                          selectedID: selectedID) { query = "" }
        case .schedule:
            SchedulePageView(todos: modeSchedule(filter),
                             isSelected: { isSelected($0) },
                             selectedID: selectedID) { query = "" }
        case .prod:
            ProdArchiveView(archive: prodArchive, issues: modeProd(filter),
                            selectedID: selectedID,
                            isSelected: { isSelected($0) }) { query = "" }
        case .vit:
            VitrinkaAllView(entries: modeVit(filter),
                            isSelected: { isSelected($0) }) { query = "" }
        case .boards:
            BoardsAllView(boards: modeBoards(filter),
                          isSelected: { isSelected($0) }) { query = "" }
        case .issues:
            IssueSearchView(store: store, issues: modeIssues(filter),
                            selectedID: selectedID,
                            isSelected: { isSelected($0) }) { query = "" }
        case .fans:
            FanDeckView(fanStore: FanStore.shared, filter: filter) { query = "" }
        case .notes:
            NotesPageView(store: notes, notes: modeNotes(filter),
                          selectedID: selectedID,
                          isSelected: { isSelected($0) },
                          expandedID: expandedNoteID,
                          editingID: $editingNoteID,
                          onToggle: { toggleNote($0) }) { query = "" }
        case .organize:
            OrganizePageView(layouts: modeOrganize(filter),
                             isSelected: { isSelected($0) },
                             onRun: { runOrganize($0) }) { query = "" }
        }
    }

    /// Layout names narrowed by the palette, read fresh from settings.json —
    /// see `WorkspaceLayouts.names()` for why nothing is cached.
    private func modeOrganize(_ filter: String) -> [String] {
        let q = filter.lowercased()
        let all = WorkspaceLayouts.names()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    /// Fire-and-report: the move/tile/spawn happens inside Hammerspoon (which
    /// shows its own on-screen summary); the palette only carries the verdict
    /// as an inline notice — a broken hs must never modal.
    private func runOrganize(_ name: String) {
        commandNotice = .ok("organizing — \(name)…")
        Task {
            commandNotice = await OrganizeRunner.run(layout: name)
        }
    }

    private func modeNotes(_ filter: String) -> [SavedNote] {
        notes.ordered.filter { $0.matches(filter) }
    }

    /// Expand-in-place, everywhere: the note opens where you found it. Second
    /// ↵ (or Esc) folds it back — see `handleKey`.
    private func toggleNote(_ note: SavedNote) {
        withAnimation(.easeOut(duration: 0.16)) {
            expandedNoteID = expandedNoteID == note.id ? nil : note.id
        }
    }

    /// The agenda, narrowed by the palette. Unlike `modeTodos` this keeps
    /// resolved-hiding out of it — a scheduled item is dismissed by doing it,
    /// not by triaging it away.
    private func modeSchedule(_ filter: String) -> [TodoItem] {
        todoStore.scheduledTodos.filter { $0.matches(filter) }
    }

    private func modeTodos(_ filter: String) -> [TodoItem] {
        todoStore.openTodos.filter {
            $0.matches(filter) && !hiddenResolved.contains("todo:\($0.id)")
        }
    }

    private func modeProd(_ filter: String) -> [ProdIssue] {
        let visible = prodArchive.issues.filter { !hiddenResolved.contains("prod:\($0.id)") }
        let q = filter.lowercased()
        guard !q.isEmpty else { return visible }
        return visible.filter {
            $0.issue.title.lowercased().contains(q)
                || $0.project.lowercased().contains(q)
                || $0.issue.shortId.lowercased().contains(q)
        }
    }

    /// Issue hits come back already answered to `filter` — GitHub matched the
    /// body text too, so re-filtering locally would hide real hits. Only the
    /// resting list needs narrowing, while a one-character query is still too
    /// short to be worth a request.
    private func modeIssues(_ filter: String) -> [ArchivedIssue] {
        let visible = store.issueMatches.filter { !hiddenResolved.contains("issue:\($0.id)") }
        guard store.showingRecentIssues, !filter.isEmpty else { return visible }
        let q = filter.lowercased()
        return visible.filter {
            $0.title.lowercased().contains(q)
                || $0.repoSlug.lowercased().contains(q)
                || "#\($0.number)".contains(q)
                || $0.labels.contains { $0.lowercased().contains(q) }
        }
    }

    private func modeVit(_ filter: String) -> [VitrinkaListening] {
        store.vitrinkaListening.filter {
            $0.matches(filter) && !hiddenResolved.contains("vit:\($0.id)")
        }
    }

    private func modeBoards(_ filter: String) -> [VitrinkaBoard] {
        store.vitrinkaBoards.filter { $0.matches(filter) }
    }

    /// Opening a URL activates the browser, which resigns the panel's key
    /// status — it closes itself, exactly as a mouse click does today.
    private static func open(_ url: String) {
        if let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }

    private func isSelected(_ id: String) -> Bool {
        selectedID == id
    }

    /// The panel's field editor is shared window machinery — grab it and park
    /// the insertion point after the last character.
    private func moveCaretToEnd() {
        guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    private func currentIndex(in items: [PaletteItem]) -> Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    private func handleKey(_ event: NSEvent, synthetic: Bool = false) -> NSEvent? {
        // The monitor is app-wide; Settings and other windows keep their keys.
        // A PanelDriver event is addressed to this panel by construction.
        guard synthetic || NSApp.keyWindow is StatusPanel else { return event }
        // The workspace search (and note editors) own their editing keys — but
        // never Esc. It peels one panel layer (case 53), and a note edit has to
        // stay cancellable with the key that opened it; case 53 returns the
        // event when there is no layer to peel, so a field keeps its own Esc.
        guard synthetic || paletteFocused || event.keyCode == 53
            || !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
        let items = paletteItems
        switch event.keyCode {
        case 125: // ↓
            guard !items.isEmpty else { return event }
            let next = currentIndex(in: items).map { min($0 + 1, items.count - 1) } ?? 0
            selectedID = items[next].id
            return nil
        case 126: // ↑
            guard let current = currentIndex(in: items) else { return event }
            // Past the top the palette takes over again — the caret comes back.
            selectedID = current == 0 ? nil : items[current - 1].id
            // The field held focus the whole time, but the trip through the
            // list leaves its insertion point at 0 — put it back at the end,
            // where typing would naturally continue.
            if selectedID == nil { moveCaretToEnd() }
            return nil
        case 48: // ⇥
            // A path card owns ⇥: it walks the verb row.
            if let target = pathTarget, selectedID == nil {
                let count = target.verbs.count
                let step = event.modifierFlags.contains(.shift) ? -1 : 1
                pathVerbIndex = (pathVerbIndex + step + count) % count
                return nil
            }
            // On a highlighted row, ⇥ is TRIAGE: resolved ↔ unresolved. The
            // row dims now and disappears on the next panel open.
            if let selectedID {
                ResolvedStore.shared.toggle(selectedID)
                return nil
            }
            // Otherwise it completes: the first listed slash verb or mode —
            // exactly what the on-screen completion card promises.
            if let command = slashMatches.first {
                let completed = "/" + command.name + " "
                if query != completed {
                    query = completed
                    // The text change rebuilds the field — park the caret after it.
                    DispatchQueue.main.async { moveCaretToEnd() }
                }
                return nil
            }
            if let mode = modePickerMatches.first {
                enterMode(mode)
                return nil
            }
            return event
        case 36, 76: // ↵ / numpad ↵
            // While a note edit is up, ↵ belongs to the TextEditor (and ⌘↵
            // to its Save shortcut) — activating the selected row under a
            // half-typed draft would be Esc's bug in reverse.
            guard editingNoteID == nil else { return event }
            // A path card: ↵ runs the highlighted verb, a chord picks one
            // outright. Handled here so ⌘↵ never reaches the field editor.
            if let target = pathTarget, selectedID == nil {
                let verb = PathVerb.forModifiers(event.modifierFlags)
                    ?? target.verbs[min(pathVerbIndex, target.verbs.count - 1)]
                runPathVerb(verb)
                return nil
            }
            guard let index = currentIndex(in: items) else { return event }
            items[index].activate()
            if !items[index].keepsSelection { selectedID = nil }
            return nil
        case 53: // Esc
            // Esc peels one layer at a time. Without this the window's
            // `cancelOperation` closes the whole panel — an expanded note
            // could never be folded with the key that opened it, and an
            // in-flight edit would be thrown away with the window.
            if editingNoteID != nil {
                editingNoteID = nil
                return nil
            }
            guard expandedNoteID != nil || expandedRailNoteID != nil else { return event }
            withAnimation(.easeOut(duration: 0.16)) {
                expandedNoteID = nil
                expandedRailNoteID = nil
            }
            return nil
        case 8 where event.modifierFlags.contains(.command): // ⌘C
            // A note you can read but not retrieve is half a feature — the
            // whole point of a pasted spec is pasting it back somewhere.
            //
            // Scoped to the KEYBOARD-selected row on purpose: an expanded note
            // is text-selectable, and hijacking ⌘C there would copy the whole
            // note instead of the words the user just dragged over. Mouse
            // users get the ⧉ button.
            guard editingNoteID == nil,
                  let id = selectedNoteID,
                  let note = notes.notes.first(where: { $0.id == id })
            else { return event }
            copyNote(note)
            return nil
        default:
            return event
        }
    }

    /// The selected row's note, when the selection is on one.
    private var selectedNoteID: String? {
        guard let selectedID, selectedID.hasPrefix("note:") else { return nil }
        return String(selectedID.dropFirst("note:".count))
    }

    @ViewBuilder
    private var commandResults: some View {
        if let notice = commandNotice {
            HStack(spacing: 6) {
                Image(systemName: notice.isFailure ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 10))
                Text(notice.text)
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(notice.isFailure ? Color.orange : .secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
        if todosMatch, !showTodos {
            Button {
                query = ""
                showTodos = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text("Todos")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("vitrinka — \(todoStore.openTodos.count) open")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if selectedID == nil || isSelected("todos") { KeyChip("↵") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                selectedID == nil || isSelected("todos")
                    ? Theme.accentSoft.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        if let project = store.matchProject(query), activeProject == nil {
            Button {
                query = ""
                activeProject = project
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(project.title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text("project page — PRs, prod, services, links")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if selectedID == nil || isSelected("project:\(project.id)") { KeyChip("↵") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                // With nothing arrowed-to, ↵ still lands here — keep the cue.
                selectedID == nil || isSelected("project:\(project.id)")
                    ? Theme.accentSoft.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        let commands = QuickCommand.matching(query)
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    Button {
                        query = ""
                        command.run()
                        AppDelegate.shared?.closePanel()
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: command.systemImage)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Text(command.title)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(command.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if commandIsEnterTarget(command, index: index) { KeyChip("↵") }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        commandIsHighlighted(command, index: index)
                            ? Theme.accentSoft.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    /// Where an un-arrowed ↵ goes: `submitPalette` prefers a project match, so
    /// the first command only owns ↵ when there is no project to beat it.
    private func commandIsEnterTarget(_ command: QuickCommand, index: Int) -> Bool {
        if selectedID != nil { return isSelected("cmd:\(command.id)") }
        return index == 0 && store.matchProject(query) == nil
    }

    private func commandIsHighlighted(_ command: QuickCommand, index: Int) -> Bool {
        if selectedID != nil { return isSelected("cmd:\(command.id)") }
        return index == 0
    }

    // MARK: - Eve

    private func askEve(_ prompt: String) {
        askTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            eveAskedPrompt = prompt
        }
        // The field is rebuilt in its new home, which drops first-responder —
        // hand focus back so the conversation can continue by typing.
        DispatchQueue.main.async { paletteFocused = true }
        eveReply = ""
        eveDone = false
        eveError = nil
        eveExpanded = false
        askTask = Task {
            do {
                for try await event in await EveClient.shared.ask(prompt, settingsToken: store.eveToken) {
                    if Task.isCancelled { return }
                    eveReply = event.text
                    if event.done { eveDone = true }
                }
                eveDone = true
            } catch {
                if !Task.isCancelled {
                    eveError = error.localizedDescription
                    eveDone = true
                }
            }
        }
    }

    private func dismissEve() {
        askTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            eveAskedPrompt = nil
        }
        eveReply = ""
        eveError = nil
        DispatchQueue.main.async { paletteFocused = true }
    }

    // MARK: - Prod strip (Sentry)

    /// Exists only when production is non-quiet — the calmest possible default.
    /// Pinned at the BOTTOM of the center column (2026-07-29), so Sentry noise
    /// never pushes the fixed-order inbox around.
    @ViewBuilder
    private var prodStrip: some View {
        let issues = filteredProdIssues
        if !issues.isEmpty, store.isSectionVisible("prod") {
            hairline
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Kicker(text: "▲ Prod", count: issues.count, tone: .red,
                           action: { enterMode(.prod) },
                           actionHelp: "Open all production issues")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
                ForEach(issues.prefix(4)) { prodIssue in
                    ProdIssueRow(prodIssue: prodIssue,
                                 selected: isSelected("prod:\(prodIssue.id)"))
                        .opacity(resolvedStore.isResolved("prod:\(prodIssue.id)") ? 0.35 : 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .background(Color.red.opacity(0.06))
        }
    }

    // MARK: - Links strip (sticky, prod-strip idiom)

    /// Saved links pinned above the scroll area, same contract as the prod
    /// strip: exists when there is something to show, capped at four rows,
    /// narrowed by the palette. A `/add-link` lands here instantly.
    @ViewBuilder
    private var linksStrip: some View {
        let items = filteredLinks
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Kicker(text: "Links", count: items.count)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
                ForEach(items.prefix(4)) { link in
                    LinkStripRow(link: link, selected: isSelected("link:\(link.id)")) {
                        openLink(link)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            hairline
        }
    }

    private var filteredLinks: [SavedLink] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ordered = links.ordered
        guard !q.isEmpty, !q.hasPrefix("/") else { return ordered }
        return ordered.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    private func openLink(_ link: SavedLink) {
        links.recordOpen(id: link.id)
        Self.open(link.url)
    }

    private var filteredProdIssues: [ProdIssue] {
        let visible = store.prodIssues.filter { !hiddenResolved.contains("prod:\($0.id)") }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, !q.hasPrefix("."), !q.hasPrefix("/") else { return visible }
        return visible.filter {
            $0.issue.title.lowercased().contains(q)
                || $0.project.lowercased().contains(q)
                || $0.issue.shortId.lowercased().contains(q)
        }
    }

    // MARK: - PR inbox (fixed repo order)

    @ViewBuilder
    private var inbox: some View {
        let entries = filteredInbox
        if entries.isEmpty {
            // Silent while the archive has (or is fetching) something to say —
            // "no matches" above a list of matches would be a lie.
            if searchActive && (store.isSearching || store.isSearchingSentry
                || !store.searchMatches.isEmpty || !store.sentryMatches.isEmpty)
            {
                EmptyView()
            } else if filteredTodos.isEmpty && filteredVitrinka.isEmpty && filteredNotes.isEmpty {
                Text(query.isEmpty
                    ? "no open PRs"
                    : "no matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            // No PRs doesn't mean nothing to show — todos and listeners
            // keep their sections.
            todosSection
            vitrinkaSection
        } else {
            // Fixed order (2026-07-29): one section per repo, always in the
            // same sequence (preferences.repoOrder, rest by recency) — the
            // eye knows where each project lives. Attention still shows as
            // an orange kicker when a repo has a needs-you PR, but it never
            // moves anything.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(repoGroups(entries), id: \.slug) { group in
                    repoSection(group)
                }
                todosSection
                vitrinkaSection
            }
        }
    }

    /// Consecutive inbox entries bucketed by repo — `store.inbox` already
    /// carries the fixed repo order, so grouping just preserves it.
    private func repoGroups(_ entries: [StatusStore.InboxPR])
        -> [(slug: String, name: String, entries: [StatusStore.InboxPR])]
    {
        var groups: [(slug: String, name: String, entries: [StatusStore.InboxPR])] = []
        for entry in entries {
            if groups.last?.slug == entry.repoSlug {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.repoSlug, entry.repoName, [entry]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func repoSection(_ group: (slug: String, name: String, entries: [StatusStore.InboxPR])) -> some View {
        Kicker(
            text: group.name,
            count: group.entries.count,
            tone: group.entries.contains { $0.info.attentionRank == 0 } ? .orange : .secondary,
            action: { OverviewURL.open(OverviewURL.repoPulls(group.slug)) },
            actionRole: .link,
            actionHelp: "Open \(group.slug) pull requests on GitHub"
        )
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)
        ForEach(group.entries) { entry in
            InboxPRRow(entry: entry, selected: isSelected("pr:\(entry.id)"))
                .opacity(resolvedStore.isResolved("pr:\(entry.id)") ? 0.35 : 1)
                .id("pr:\(entry.id)")
        }
    }

    private var filteredInbox: [StatusStore.InboxPR] {
        let visible = store.inbox.filter { !hiddenResolved.contains("pr:\($0.id)") }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, !q.hasPrefix("."), !q.hasPrefix("/") else { return visible }
        return visible.filter { entry in
            entry.repoSlug.lowercased().contains(q)
                || entry.info.pr.title.lowercased().contains(q)
                || "#\(entry.info.pr.number)".contains(q)
                || entry.info.pr.head.ref.lowercased().contains(q)
        }
    }

    // MARK: - Todos (main list section)

    /// Open todos in the main list, below the PR inbox — the tab is the full
    /// view (with broken-file diagnostics); this is the glance.
    @ViewBuilder
    private var todosSection: some View {
        let todos = filteredTodos
        if !todos.isEmpty {
            Kicker(text: "Todos", count: todos.count,
                   action: { enterMode(.todos) },
                   actionHelp: "Open all todos")
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
            ForEach(todos) { todo in
                TodoRow(todo: todo, selected: isSelected("todo:\(todo.id)"))
                    .opacity(resolvedStore.isResolved("todo:\(todo.id)") ? 0.35 : 1)
                    .id("todo:\(todo.id)")
            }
        }
    }

    // MARK: - Vitrinka listeners (main list section)

    /// Boards a Claude Code session is currently tuned into — the same data
    /// as the rail, in the wide palette-navigable idiom the inbox uses.
    @ViewBuilder
    private var vitrinkaSection: some View {
        let entries = filteredVitrinka
        if !entries.isEmpty {
            Kicker(text: "🧷 Vitrinka", count: entries.count,
                   action: { enterMode(.vit) },
                   actionHelp: "Open all active Vitrinka listeners")
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
            ForEach(entries) { entry in
                VitrinkaListRow(entry: entry, selected: isSelected("vit:\(entry.id)"))
                    .opacity(resolvedStore.isResolved("vit:\(entry.id)") ? 0.35 : 1)
                    .id("vit:\(entry.id)")
            }
        }
    }

    // MARK: - Search results (all PRs, incl. merged & closed)

    private var searchActive: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// The archive: everything GitHub knows about, fetched only while you are
    /// searching. Empty palette → this section does not exist.
    @ViewBuilder
    private var searchSection: some View {
        let matches = store.searchMatches
        if searchActive, store.isSearching || !matches.isEmpty || store.searchError != nil {
            HStack(spacing: 6) {
                Kicker(text: "All PRs on GitHub", count: matches.count,
                       action: { OverviewURL.open(OverviewURL.githubPulls) },
                       actionRole: .link,
                       actionHelp: "Open the GitHub pull-request overview")
                if store.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(height: 10)
                }
                Spacer()
                if let error = store.searchError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(error)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ForEach(matches) { pr in
                ArchivedPRRow(pr: pr, selected: isSelected("archive:\(pr.id)"))
                    .id("archive:\(pr.id)")
            }
        }
    }

    // MARK: - Sentry search results (org-wide, incl. resolved & non-prod)

    /// Sentry's answer to the typed query — short ids ("EXAMPLEAPP-API-86") resolve
    /// exactly, anything else is full text. Same contract as the PR archive:
    /// exists only while searching, hides what the prod strip already shows.
    @ViewBuilder
    private var sentrySection: some View {
        let matches = store.sentryMatches
        if searchActive, store.isSearchingSentry || !matches.isEmpty {
            HStack(spacing: 6) {
                Kicker(text: "Sentry", count: matches.count,
                       action: { OverviewURL.open(OverviewURL.sentryIssues) },
                       actionRole: .link,
                       actionHelp: "Open the Sentry issue overview")
                if store.isSearchingSentry {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(height: 10)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ForEach(matches) { prodIssue in
                ProdIssueRow(prodIssue: prodIssue,
                             selected: isSelected("sentry:\(prodIssue.id)"))
                    .id("sentry:\(prodIssue.id)")
            }
        }
    }

    // MARK: - Notes (search hits only)

    /// Notes matching the query, at the TAIL of the results — a note you wrote
    /// five minutes ago must never outrank the PR you were hunting for. ↵
    /// expands the hit in place; the 680px column is where a long note reads.
    @ViewBuilder
    private var notesSection: some View {
        let matches = filteredNotes
        if !matches.isEmpty {
            Kicker(text: "Notes", count: matches.count,
                   action: { enterMode(.notes) },
                   actionHelp: "Open all notes")
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
            ForEach(matches) { note in
                NoteRow(
                    note: note,
                    style: .wide,
                    selected: isSelected("note:\(note.id)"),
                    expanded: expandedNoteID == note.id,
                    onToggle: { toggleNote(note) },
                    onRemove: { notes.remove(id: note.id) },
                    onCopy: { copyNote(note) }
                )
                .id("note:\(note.id)")
            }
        }
    }

    private func copyNote(_ note: SavedNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        commandNotice = .ok("copied the note")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pin.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No repositories pinned")
                .foregroundStyle(.secondary)
            Button("Open Settings…") {
                AppDelegate.shared?.openSettings()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// One sticky-strip link row: same dense idiom as the rail's rows, plus the
/// keyboard-selection chrome the strip's siblings (prod, PRs, todos) carry.
private struct LinkStripRow: View {
    let link: SavedLink
    var selected = false
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(link.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(link.url)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(selected ? Theme.accent.opacity(0.16)
            : hovering ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(link.url) — /rm-link \(link.title) to remove")
    }
}

private struct KeyChip: View {
    let label: String
    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Eve reply overlay

/// Floats over the dashboard (dim scrim behind), grows with the reply, and
/// expands to near-full panel height on demand — the inbox never squeezes.
private struct EveOverlay: View {
    let prompt: String
    let reply: String
    let done: Bool
    let error: String?
    @Binding var expanded: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: click to collapse/dismiss, dims the dashboard below.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("✦").foregroundStyle(Theme.eve)
                    Text("eve")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .kerning(1.3)
                        .foregroundStyle(.secondary)
                    Text("· \(prompt)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if !done {
                        ProgressView().controlSize(.mini)
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(expanded ? "Collapse" : "Expand")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss (Esc)")
                }

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                } else if reply.isEmpty {
                    Text(done ? "no answer" : "thinking…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Text(LocalizedStringKey(reply))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: expanded ? 520 : 240)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(Theme.eveSoft, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.eve.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

// MARK: - Project page (the on-call view)

/// One product at a glance: its prod issues, PRs, service tiles, quick links.
struct ProjectPageView: View {
    let project: ProjectSpec
    let store: StatusStore
    let onBack: () -> Void

    private var projectPRs: [StatusStore.InboxPR] {
        let repos = Set(project.repos.map { $0.lowercased() })
        return store.inbox.filter { repos.contains($0.repoSlug.lowercased()) }
    }

    private var projectIssues: [ProdIssue] {
        store.prodIssues.filter { project.sentryProjects.contains($0.project) }
    }

    private var projectServices: [ServiceStatus] {
        store.serviceStatuses.filter { project.services.contains($0.name) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text(project.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    ForEach(project.links) { link in
                        Button {
                            if let url = URL(string: link.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(link.title)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if !projectServices.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(projectServices) { service in
                            ServiceTile(service: service)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

                if !projectIssues.isEmpty {
                    Kicker(
                        text: "▲ Prod",
                        count: projectIssues.count,
                        tone: .red,
                        action: { OverviewURL.open(OverviewURL.sentryIssues) },
                        actionRole: .link,
                        actionHelp: "Open the Sentry issue overview"
                    )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(projectIssues.prefix(6)) { prodIssue in
                        ProdIssueRow(prodIssue: prodIssue)
                    }
                }

                if projectPRs.isEmpty {
                    Text("no open PRs")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                } else {
                    Kicker(
                        text: "Pull Requests",
                        count: projectPRs.count,
                        action: { OverviewURL.open(OverviewURL.projectPulls(project.repos)) },
                        actionRole: .link,
                        actionHelp: "Open the GitHub pull-request overview"
                    )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(projectPRs) { entry in
                        InboxPRRow(entry: entry)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}
