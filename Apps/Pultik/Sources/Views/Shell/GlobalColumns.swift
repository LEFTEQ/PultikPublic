import SwiftUI

/// Everything in the centre column that sits OUTSIDE the capped list — the
/// palette, its hairline, and the pinned prod/links strips. Summed, not maxed:
/// these are stacked siblings, and the cap has to leave room for all of them.
struct CentreChromeKey: PreferenceKey {
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

extension StatusPanelView {
    /// Todos worth interrupting for — overdue, inside their lead window, or
    /// milestone-ripe per the server (decision D4=B). A reminder that is not
    /// yet due is not yet information; a backend we cannot reach yields none,
    /// so the rail folds instead of alerting.
    var reminders: [TodoItem] {
        RemindersRail.attentionWorthy(todoStore.reminderCandidates)
    }

    var showAlerts: Bool {
        store.isSectionVisible("alerts") && !store.visibleAlerts.isEmpty
    }

    /// The right rail is the prod board (decision D2 C, 2026-10-03): one card
    /// per deployment over Hlídač, then reminders, estate firing and eve
    /// alerts (the left column is retired, WP8), with links and notes as one
    /// reference line at its foot.
    var showServiceRail: Bool {
        showProdBoard
            || !store.prodConfigIssues.isEmpty
            || needsYou
            // An answering estate holds the rail open for its all-clear line.
            || sourcesAnswered
            // Links and notes are local — they must be able to hold the rail
            // open on their own, or off-mesh they'd vanish with the probes.
            || !links.links.isEmpty
            || !notes.notes.isEmpty
    }

    /// The right rail's width beside results and palette pages.
    static let sideColumnWidth: CGFloat = 300

    /// Home (panel Home D2, 2026-10-07) owns the right region while the
    /// search is global, nothing is typed and nothing else is open; any
    /// query, mode, page or Eve reply swaps it back to results beside the
    /// prod rail, and an entered module takes the whole body.
    var showsHome: Bool {
        router.module == nil && query.isEmpty && activeMode == nil && !showTodos && activeProject == nil
            && eveAskedPrompt == nil
    }

    /// The global search's body: the centre (Home, results or a palette
    /// page) and the prod rail beside results. Home takes the whole body
    /// like a module (D5-A: the strip is the awareness, and its needs are
    /// Now's). There is no left column (WP8): its widgets' lists are the
    /// modules, and their awareness is the strip.
    var globalBody: some View {
        HStack(alignment: .top, spacing: 0) {
            // Home takes the centre and the right rail's room (D2); the
            // prod rail returns beside any results.
            centerColumn
                .frame(maxWidth: .infinity)
            if showServiceRail, !showsHome {
                hairlineV
                ScrollColumn(maxHeight: columnBudget) {
                    railsColumn
                }
                .frame(width: Self.sideColumnWidth)
                // A fixed-width frame centers (never clips) an oversized
                // child, so any row that escapes the rail would bleed into
                // the centre column — clip here so it can't.
                .clipped()
            }
        }
    }

    /// Home's PR tile, folded (D3) — resolved-and-hidden PRs already gone.
    var homeDigest: PRDigest<StatusStore.InboxPR> {
        PRDigest(filteredInbox, repo: \.repoSlug, info: \.info)
    }

    /// Tallest a column may be before it has to scroll: the panel's fixed
    /// frame (`PanelMetrics.panelSize`, D4) less the top bar above the
    /// content sheet and the footer beneath it. The floor keeps the hub
    /// usable on a very short screen.
    var columnBudget: CGFloat {
        max(280, PanelMetrics.shared.panelSize.height - topBarHeight - footerHeight)
    }

    /// The centre's list height: the fixed frame less the palette and the
    /// pinned strips stacked around it (D4 — the old 560 pt design cap and
    /// the tallest-side stretch went with content sizing).
    var centreCap: CGFloat {
        max(160, columnBudget - centreChrome)
    }

    /// The original 680px panel — palette, prod strip, inbox (or a project
    /// page), CI footer — with the eve reply floating over the scroll area.

    /// The right rail's stacked sections — extracted so the scroller can be
    /// measured (RightRailsHeightKey) without burying the GeometryReader
    /// eight indentation levels deep in the body.
    var railsColumn: some View {
        VStack(alignment: .leading, spacing: TileMetrics.gap) {
            // F4: settings problems stand on their own above the board — a
            // folded or hidden board must not hide a broken settings.json.
            let issues = store.prodConfigIssues
            if !issues.isEmpty {
                ProdConfigIssues(issues: issues)
            }
            if showProdBoard {
                ProdBoardSection(glance: store.prodGlance,
                                 now: Date(), onOpen: { enterMode(.health, filter: $0) })
            }
            // Until Hlídač has answered once, the Mac's own Sentry sweep keeps
            // prod issues visible — nothing is lost while it is not deployed.
            if !prodSentryLive, !railProdIssues.isEmpty {
                RailSection(key: "prodSentry", title: "Sentry", count: railProdIssues.count, tone: .red) {
                    ProdRail(issues: railProdIssues,
                             isResolved: { resolvedStore.isResolved("prod:\($0.id)") })
                }
            }
            attentionRails
            if !needsYou, sourcesAnswered, !showProdBoard {
                // An empty rail still says something: the sources answered
                // and none of them needs you. Off the mesh it says nothing.
                Text("✓ all clear")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, RailRowMetrics.inset + 2)
                    .padding(.top, 12)
            }
            if !links.links.isEmpty || !notes.notes.isEmpty {
                RailFoot(links: links.ordered, notes: notes.notes.count,
                         onOpenLink: { openLink($0) },
                         onOpenNotes: { enterMode(.notes) })
            }
        }
        .padding(TileMetrics.gap)
    }

    /// Reminders, estate firing and eve alerts — what needs you that is not a
    /// deployment, under the prod board. Reminders stay here until Work
    /// absorbs `TodoStore`'s candidates; firing is Estate's, eve alerts
    /// Sessions'.
    @ViewBuilder
    var attentionRails: some View {
        if !reminders.isEmpty {
            RailSection(key: "reminders", title: "Reminders",
                        count: reminders.count,
                        tone: reminders.contains(where: { $0.isOverdue() })
                            ? .red : .orange)
            {
                RemindersRail(todos: reminders)
            }
        }
        let firing = firingGlance
        if !firing.rows.isEmpty {
            RailSection(key: "firing", title: prodBoardClaims ? "Firing · estate" : "Firing",
                        count: firing.rows.count,
                        tone: firing.critical > 0 ? .red : .orange)
            {
                FiringAlertsRail(glance: firing)
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
    }

    /// Hlídač serves prod Sentry now (`ProdClaims.sentryLive`): the Mac's own
    /// Sentry sweep, the fallback, stays hidden.
    var prodSentryLive: Bool {
        ProdClaims.sentryLive(digest: store.prodDigest, unreachableSince: store.prodUnreachableSince)
    }

    /// The board is answering and can claim deployment alerts, so FIRING
    /// holds only the estate's own weather — and says so in its title.
    var prodBoardClaims: Bool {
        showProdBoard && store.prodDigest != nil && store.prodUnreachableSince == nil
            && store.prodDigest?.sources["alertmanager"]?.ok != false
    }

    /// AC S5: the deployment `.h <filter>` names (the matrix narrows to the
    /// rows it matches; ↵ opens one) — reported to the panel driver as
    /// `prodExpanded`.
    var prodExpandedKey: String? {
        guard router.module == .prod else { return nil }
        return ProdMatrix.expandedKey(filter: query,
                                      rows: store.prodGlance.cards.map { (key: $0.key, title: $0.title) })
    }

    /// The prod board shows whenever Hlídač is configured and not hidden —
    /// with cards, or (F10) one blind row while nothing has answered yet.
    /// `/hide prod` or `hlidacURL: ""` turn it off.
    var showProdBoard: Bool {
        guard store.isSectionVisible("prod"), store.hlidacConfigured else { return false }
        let glance = store.prodGlance
        return !glance.cards.isEmpty || glance.waiting != nil
    }

    /// A deployment that is not green — or a board still waiting on Hlídač —
    /// asks for attention like any rail row, and suppresses all-clear.
    var prodNeedsYou: Bool {
        guard showProdBoard else { return false }
        let glance = store.prodGlance
        return glance.waiting != nil || glance.cards.contains { $0.tone != .green }
    }

    /// Production issues for the rail — resolved-and-hidden ones gone, never
    /// narrowed by the palette query (the rail is not a search result).
    var railProdIssues: [ProdIssue] {
        guard store.isSectionVisible("prod") else { return [] }
        return store.prodIssues.filter { !hiddenResolved.contains("prod:\($0.id)") }
    }

    /// Firing alerts as the rail shows them — gated here too, so `/hide
    /// firing` empties the section at once rather than at the next poll.
    ///
    /// Once Hlídač answers, an alert carrying a `deployment` label belongs to
    /// that deployment's card; FIRING keeps only the estate's own weather.
    /// With the board hidden (`/hide prod`) no card shows them, so FIRING does.
    var firingGlance: AlertGlance {
        AlertGlance(estateFiring)
    }

    /// The estate's own firing rules at any severity, the heartbeat gone —
    /// Estate's objects, where Now's unclaimed alerts open.
    var estateFiring: [FiringAlert] {
        guard store.isSectionVisible("firing") else { return [] }
        let boardShown = showProdBoard
        return store.firingAlerts.filter {
            $0.state == "firing" && !$0.isHeartbeat && !(boardShown && store.prodClaims($0))
        }
    }

    /// Anything in the rail that asks for attention, as opposed to the
    /// reference line at its foot.
    var needsYou: Bool {
        !reminders.isEmpty || (!prodSentryLive && !railProdIssues.isEmpty) || showAlerts
            || !firingGlance.rows.isEmpty || prodNeedsYou
    }

    /// Prometheus answered this pass (its metrics or probes are in), so an
    /// empty rail is a real "all clear" rather than an unreachable mesh.
    var sourcesAnswered: Bool {
        !store.serverMetrics.isEmpty || !store.serviceStatuses.isEmpty
    }

    var centerColumn: some View {
        VStack(spacing: 0) {
            // The search lives in the top bar (D11's decided chrome); asking
            // eve keeps it there and the reply floats over this column.
            if eveAskedPrompt == nil {
                commandResults.measuringCentreChrome()
            }

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
                if showsHome {
                    home
                        .frame(height: centreCap)
                } else {
                    // The fixed frame (D4) gives the list a definite height:
                    // it fills what the palette and strips leave.
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
                        }
                        .frame(height: centreCap)
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

            // Saved links anchor the BOTTOM of the center column only while
            // searching — they are search results there; at rest they sit at
            // the right rail's foot. Prod issues moved to the rail (2026-09-27).
            if activeMode == nil, !showTodos, activeProject == nil, eveAskedPrompt == nil, searchActive {
                linksStrip.measuringCentreChrome()
            }
        }
        .overlay(alignment: .top) {
            // Slash verbs and palette modes float OVER the list on glass —
            // they are transient completions, not content.
            if eveAskedPrompt == nil, !slashMatches.isEmpty || !modePickerMatches.isEmpty {
                floatingResults
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            } else if eveAskedPrompt == nil, let target = pathTarget {
                PathCard(target: target, highlighted: pathVerbIndex) { runPathVerb($0) }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
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
                .padding(.top, 8)
            }
        }
    }

    var hairline: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    var hairlineV: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }

    // MARK: - Home

    /// Home (vt-7727 D8): the Now column, the widgets beside it.
    var home: some View {
        HomeView(model: nowHomeModel, widgets: homeWidgets, onActivate: activateNow) { homeWidget($0) }
    }

    var nowHomeModel: NowHomeModel {
        let now = NowStore.shared
        return NowHomeModel(queue: now.queue, rows: homeNowRows, handled: now.handled, selectedID: selectedID,
                            expanded: nowExpanded, asOf: now.restoredAsOf, awaiting: now.awaitingFirstRead)
    }

    /// The widgets drawn, in their one order: one sits out while its backend
    /// has nothing true to say — Production excepted while Hlídač is
    /// configured, it reads blind rather than vanishing.
    var homeWidgets: [HomeWidget] {
        HomeWidget.allCases.filter { widget in
            switch widget {
            case .prod: showProdBoard || !store.prodConfigIssues.isEmpty || (!prodSentryLive && !railProdIssues.isEmpty)
            case .prs: true
            case .ci: CITile.isShown(store: store)
            case .devbox: DevboxTile.isShown(store: store)
            case .estate: EstateTile.isShown(store: store)
            case .mac: MacTile.isShown(store: store)
            }
        }
    }

    @ViewBuilder
    func homeWidget(_ widget: HomeWidget) -> some View {
        switch widget {
        case .prod:
            ProdTile(glance: showProdBoard ? store.prodGlance : ProdGlance(cards: [], waiting: nil),
                     configIssues: store.prodConfigIssues,
                     sentryIssues: prodSentryLive ? [] : railProdIssues,
                     isResolved: { resolvedStore.isResolved("prod:\($0.id)") },
                     now: Date(), onOpen: { enterMode(.health, filter: $0) })
        case .prs:
            if store.pinned.isEmpty {
                emptyState.frame(maxHeight: .infinity).tileSurface()
            } else {
                PRDigestTile(digest: homeDigest, expanded: $homeExpanded, selectedID: nil,
                             isResolved: { resolvedStore.isResolved($0) })
            }
        case .ci:
            CITile(store: store, onOpen: { enterMode(.ci, filter: $0) })
        case .devbox:
            DevboxTile(store: store, onOpen: { enterMode(.devbox, filter: $0) })
        case .estate:
            EstateTile(store: store, firing: estateFiring) { openObject(.estate, $0) }
        case .mac:
            // This Mac is Estate's (vt-7727 D1): the widget opens it, or a finding under it.
            MacTile { openObject(.estate, $0 ?? PaletteMode.thisMac) }
        }
    }

    // MARK: - Empty state

    var emptyState: some View {
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
