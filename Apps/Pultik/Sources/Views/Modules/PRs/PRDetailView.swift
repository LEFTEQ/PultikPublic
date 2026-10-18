import SwiftUI

/// The workbench's tabs (PR workbench D5), in ←/→ order.
enum PRTab: String, CaseIterable {
    case overview, commits, files, merge, checks

    var title: String {
        switch self {
        case .overview: "Overview"
        case .commits: "Commits"
        case .files: "Files changed"
        case .merge: "Merge"
        case .checks: "Checks"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// A change request's workbench (PR workbench D5–D7, stay in Pultík D5): a
/// compact header — title, state and verbs, one meta line, one roll-up of
/// checks, review, threads and mergeability — over Overview · Commits ·
/// Files changed · Checks, each tab in its own scroller. ↵ on the list
/// enters it: ←/→ walk the tabs, ↑/↓ scroll, ⇥ walks the tab's targets
/// (threads, files, run badges) and ↵ on a badge slides its run card over
/// the PR (D2). Drawn at once from what the warm set holds (D9); the CI
/// watch keeps its badges live while it is on screen (D7).
struct PRWorkbench: View {
    let store: StatusStore
    let ref: ChangeRequestRef
    /// The list's row: its title, glyph and page until the conversation lands.
    let object: ModuleObject
    @Environment(ModuleRouter.self) private var router
    @Environment(\.panelIsPresented) private var presented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var conversation: ChangeRequest?
    /// The files of `conversation`'s own diff, or nil. The one exception is
    /// `filesStale`: the same head compared at an older base, shown marked
    /// while its exact diff loads — never another head's.
    @State private var files: ChangeSet?
    @State private var filesStale = false
    /// The conversation read failed (the held one may still show).
    @State private var failure: String?
    /// The files read failed; the conversation stands.
    @State private var filesFailure: String?
    @State private var attempt = 0
    @State private var showsResolved = false
    /// The description parsed once per body (D8).
    @State private var description: (source: String, blocks: [GFMBlock])?
    /// Tabs drawn once stay mounted, so going back keeps their scroll.
    @State private var visited: Set<PRTab> = []
    /// The timeline, merge options and verb handles (D4, D8).
    @State private var activity: ChangeRequestActivity?
    /// The sheet a verb opened over the tab, and how its run went.
    @State private var sheet: VerbSheet?
    @State private var sheetBusy = false
    @State private var sheetFailure: String?
    @State private var mergeMethod: MergeMethod = .squash
    @State private var deleteBranch = true
    @State private var sheetText = ""
    @State private var sheetTitle = ""
    @State private var picked: Set<String> = []
    @State private var choices: MetadataChoices?
    /// The Overview composer: optimistic until the re-read holds it.
    @State private var comment = ""
    @State private var commentSending = false
    @FocusState private var commentFocused: Bool
    /// Threads resolved or reopened here before the re-read confirms it.
    @State private var resolvedHere: [String: Bool] = [:]
    /// The last verb's outcome, in the host's words when it refused.
    @State private var notice: (text: String, failed: Bool)?
    /// `base..head` from the mirror (WP5), and the commit Files changed is
    /// scoped to with its own diff.
    @State private var commits: [ChangeCommit]?
    @State private var commitsFailure: String?
    @State private var scopedCommit: ChangeCommit?
    @State private var scopedFiles: ChangeSet?
    /// A merge commit ↵ picked in Commits: the Merge tab shows its own merge (vt-7968).
    @State private var mergeCommit: ChangeCommit?

    #if DEBUG
    /// The sections the open workbench draws, for the panel driver (`prSections`).
    @MainActor static var drawnSections: [String] = []
    #endif

    init(store: StatusStore, ref: ChangeRequestRef, object: ModuleObject) {
        self.store = store
        self.ref = ref
        self.object = object
        let cached = store.cachedPRDetail(ref)
        _conversation = State(initialValue: cached.conversation)
        _files = State(initialValue: cached.files)
        _activity = State(initialValue: store.cachedPRActivity(ref))
    }

    private var verbs: [PRVerb] {
        conversation.map { PRVerbCatalogue.verbs($0, activity: activity) } ?? []
    }

    private var badges: [RunBadge] {
        guard let conversation else { return [] }
        let live = store.ciWatchTarget?.request == ref ? store.ciLive : nil
        return RunBadge.badges(conversation.checks, repo: ref.repo, host: ref.host, live: live)
    }

    private var shownTab: PRTab {
        router.shownTab.flatMap(PRTab.init(rawValue:)) ?? .overview
    }

    var body: some View {
        let badges = badges
        let shown = shownTab
        VStack(alignment: .leading, spacing: 0) {
            header(badges)
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 8)
            DetailTabs(tabs: tabs(badges), selected: shown.rawValue, entered: ownsKeys && router.entered) { name in
                withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(name) }
            }
            ZStack(alignment: .topLeading) {
                ForEach(PRTab.allCases.filter { visited.contains($0) || $0 == shown }, id: \.self) { tab in
                    content(tab, badges: badges)
                        .opacity(tab == shown ? 1 : 0)
                        // WP7: a tab sits to the side it lies on; the shown one slides in.
                        .offset(x: tab == shown ? 0 : Theme.Motion.tabShift(reduceMotion) * (tab.order < shown.order ? -1 : 1))
                        .allowsHitTesting(tab == shown)
                        .accessibilityHidden(tab != shown)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if let sheet {
                    sheetView(sheet)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Chip(notice.text, notice.failed ? .danger : .ok, symbol: notice.failed ? "exclamationmark.triangle" : "checkmark")
                        .padding(.bottom, 14)
                        .transition(Theme.Motion.toast(reduceMotion))
                        .task(id: notice.text) {
                            try? await Task.sleep(for: .seconds(notice.failed ? 6 : 3))
                            withAnimation(Theme.Motion.status(reduceMotion)) { self.notice = nil }
                        }
                }
            }
        }
        .task(id: LoadKey(ref: ref, attempt: attempt, confirmed: store.ciConfirmed[ref] ?? 0,
                          revision: store.prVerbRevision[ref] ?? 0)) { await load() }
        .onAppear { router.setTabs(PRTab.allCases.map(\.rawValue)) }
        // D5: the letters this PR takes while entered, and what they reach.
        .onChange(of: ownsKeys ? PRVerbCatalogue.keys(verbs) : [], initial: true) { _, keys in
            if ownsKeys { router.setVerbKeys(keys) }
        }
        .onChange(of: router.verbRequest) { _, request in
            guard ownsKeys, let request else { return }
            router.consumeVerb()
            if request.key == VerbRequest.menu {
                open(sheet == .menu ? nil : .menu)
            } else if let verb = verbs.first(where: { $0.key == request.key }) {
                reach(verb)
            }
        }
        .onChange(of: router.composerCommand) { _, command in
            guard ownsKeys, let command else { return }
            if sheet != nil {
                command.action == .submit ? runSheet() : open(nil)
            } else if commentFocused {
                if command.action == .submit { postComment() } else { commentFocused = false }
            }
        }
        .onChange(of: SheetFlags(confirm: sheet?.isConfirm == true, typing: (sheet != nil && sheet?.isConfirm == false) || commentFocused),
                  initial: true) { _, flags in
            guard ownsKeys else { return }
            router.setVerbConfirm(flags.confirm)
            router.setComposing(flags.typing)
        }
        .onDisappear {
            router.setVerbConfirm(false)
            router.setComposing(false)
        }
        .onChange(of: shown, initial: true) { _, tab in visited.insert(tab) }
        // D3: the shown tab is the top layer while no card covers it.
        .onChange(of: FocusReport(targets: focusTargets(shown, badges), top: ownsKeys), initial: true) { _, report in
            if report.top { router.setFocusTargets(report.targets) }
        }
        // D7: watched while on screen and something runs.
        .onChange(of: watchTarget(badges), initial: true) { _, target in store.watchCI(target) }
        .onDisappear { store.watchCI(nil) }
        #if DEBUG
        .onChange(of: drawnSections(badges), initial: true) { _, sections in Self.drawnSections = sections }
        #endif
    }

    private struct LoadKey: Equatable {
        let ref: ChangeRequestRef
        let attempt: Int
        /// The CI watch confirmed a transition: read the held answer again.
        let confirmed: Int
        /// A verb landed: the store re-read both; draw what it holds.
        let revision: Int
    }

    private struct SheetFlags: Equatable {
        let confirm: Bool
        let typing: Bool
    }

    private struct FocusReport: Equatable {
        let targets: [String]
        let top: Bool
    }

    /// This workbench is the detail on screen and no card covers it.
    private var ownsKeys: Bool {
        router.module == .prs && router.detailOpen && router.stack.isEmpty
    }

    /// ⇥'s walk on the shown tab (D3): open threads, files, run badges.
    private func focusTargets(_ tab: PRTab, _ badges: [RunBadge]) -> [String] {
        guard let conversation else { return [] }
        switch tab {
        case .overview: return openThreads(conversation).map { "thread:\($0.id)" }
        case .commits: return PRCommitsTab.focusTargets(commits)
        case .files: return PRFilesTab.focusTargets(files)
        case .merge: return PRMergeTab.focusTargets()
        case .checks: return badges.filter { $0.run != nil }.map(\.id)
        }
    }

    private func tabs(_ badges: [RunBadge]) -> [DetailTabs.Tab] {
        PRTab.allCases.map { tab in
            switch tab {
            case .overview: DetailTabs.Tab(id: tab.rawValue, title: tab.title)
            case .commits: DetailTabs.Tab(id: tab.rawValue, title: tab.title, count: commits?.count)
            case .files: DetailTabs.Tab(id: tab.rawValue, title: tab.title, count: conversation?.changedFiles)
            case .merge: DetailTabs.Tab(id: tab.rawValue, title: tab.title,
                                        alarming: conversation?.state == .open && conversation?.mergeable == .conflicting)
            case .checks: DetailTabs.Tab(id: tab.rawValue, title: tab.title, count: conversation == nil ? nil : badges.count,
                                         alarming: badges.contains { $0.outcome == .failed })
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private func content(_ tab: PRTab, badges: [RunBadge]) -> some View {
        let active = ownsKeys && tab == shownTab
        if let conversation {
            switch tab {
            case .overview: overview(conversation, active: active)
            case .commits:
                PRCommitsTab(commits: commits, failure: commitsFailure, active: active, scoped: scopedCommit?.sha) {
                    scope($0)
                }
            case .files:
                PRFilesTab(store: store, pr: conversation, files: scopedCommit == nil ? files : scopedFiles,
                           stale: scopedCommit == nil && filesStale, failure: filesFailure, active: active,
                           scope: scopedCommit.map { commit in
                               (title: "\(commit.sha.prefix(7)) · \(commit.subject)", clear: { scope(nil) })
                           }) {
                    attempt += 1
                }
            case .merge:
                PRMergeTab(store: store, pr: conversation, commit: mergeCommit, active: active) { mergeCommit = nil }
            case .checks: checks(conversation, badges: badges, active: active)
            }
        } else if let failure {
            Tile(kicker: "Pull request") {
                Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            }
            .padding(14)
        } else {
            skeleton.padding(14)
        }
    }

    /// The description (D8), the open threads and who asked for changes.
    /// Timeline + metadata column (D8): the description, the open threads
    /// and who asked for changes, the story, the merge box, the composer —
    /// and reviewers, assignees, labels and milestone beside it.
    private func overview(_ pr: ChangeRequest, active: Bool) -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        descriptionItems(pr)
                        if !openThreads(pr).isEmpty || (showsResolved && pr.threads.contains(where: \.isResolved)) {
                            threadsSection(pr).padding(.bottom, 10)
                        }
                        let changes = pr.reviews.filter { $0.verdict == .changesRequested }
                        if !changes.isEmpty { changesSection(changes).padding(.bottom, 10) }
                        if let activity {
                            PRTimeline(events: activity.timeline, truncated: activity.timelineTruncated, repo: ref.repo,
                                       resolver: resolver)
                                .padding(.bottom, 10)
                        } else {
                            SkeletonBars(widths: [0.5, 0.65, 0.4]).padding(.bottom, 10)
                        }
                        MergeBox(pr: pr, activity: activity, verbs: verbs) { reach($0) }
                            .padding(.bottom, 10)
                        CommentComposer(text: $comment, repo: ref.repo, resolver: resolver, sending: commentSending,
                                        focused: $commentFocused, submit: postComment)
                            .id("composer")
                    }
                    .padding([.horizontal, .bottom], 14)
                    .padding(.top, 12)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .workbenchScroll(active: active)
                .onChange(of: router.focus) { _, focus in
                    guard active, let focus, focus.hasPrefix("thread:") else { return }
                    withAnimation(Theme.Motion.focus(reduceMotion)) { scroller.scrollTo(focus, anchor: .center) }
                }
                .onChange(of: commentFocused) { _, focused in
                    guard focused else { return }
                    withAnimation(Theme.Motion.focus(reduceMotion)) { scroller.scrollTo("composer", anchor: .bottom) }
                }
            }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            PRMetadataColumn(pr: pr, activity: activity, verbs: verbs) { reach($0) }
                .frame(width: 240)
                .background(Theme.canvas)
        }
    }

    /// Open threads, with what was resolved or reopened here applied.
    private func openThreads(_ pr: ChangeRequest) -> [ChangeRequest.ReviewThread] {
        pr.threads.filter { !(resolvedHere[$0.id] ?? $0.isResolved) }
    }

    /// ↵ on a commit (WP5): Files changed shows that commit's own diff until
    /// the scope is cleared; nil returns to the whole PR.
    /// A merge commit opens its own merge in the Merge tab instead (vt-7968).
    private func scope(_ commit: ChangeCommit?) {
        if let commit, commit.parents.count > 1 {
            mergeCommit = commit
            withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(PRTab.merge.rawValue) }
            return
        }
        scopedCommit = commit
        scopedFiles = nil
        guard let commit else { return }
        withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(PRTab.files.rawValue) }
        let repo = ref.repo
        Task {
            do {
                let files = try await store.commitFiles(repo, sha: commit.sha)
                if scopedCommit?.sha == commit.sha { scopedFiles = files }
            } catch {
                NSLog("pultik: commit %@ files failed: %@", commit.sha, error.localizedDescription)
                show(error.localizedDescription, failed: true)
            }
        }
    }

    /// Every run as a badge (D6) — ⇥ rings one, ↵ slides its card over the
    /// PR — the failing runs, then every check on the head commit.
    private func checks(_ pr: ChangeRequest, badges: [RunBadge], active: Bool) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        rail(badges)
                        if let focused = badges.first(where: { $0.id == router.focus }) { jobsLine(focused) }
                    }
                    let failing = badges.filter { $0.outcome == .failed }
                    if !failing.isEmpty { failingSection(failing) }
                    if !pr.checks.isEmpty { checkList(pr) }
                }
                .padding([.horizontal, .bottom], 14)
                .padding(.top, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .workbenchScroll(active: active)
            .onChange(of: router.focus) { _, focus in
                guard active, let focus, focus.hasPrefix("run:") else { return }
                withAnimation(Theme.Motion.focus(reduceMotion)) { scroller.scrollTo(focus, anchor: .center) }
            }
        }
    }

    private func watchTarget(_ badges: [RunBadge]) -> StatusStore.CIWatchTarget? {
        guard presented else { return nil }
        let running = Set(badges.filter { $0.outcome == .running }.compactMap(\.run))
        return running.isEmpty ? nil : StatusStore.CIWatchTarget(request: ref, runs: running)
    }

    private func drawnSections(_ badges: [RunBadge]) -> [String] {
        guard let conversation else { return [] }
        var sections: [String] = []
        if badges.contains(where: { $0.outcome == .failed }) { sections.append("failing") }
        if !conversation.openThreads.isEmpty { sections.append("threads") }
        if conversation.reviews.contains(where: { $0.verdict == .changesRequested }) { sections.append("changes") }
        if !conversation.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append("description") }
        sections.append("files")
        return sections
    }

    private func load() async {
        do {
            let fresh = try await store.prConversation(ref)
            try Task.checkCancellation()
            if let exact = store.cachedPRFiles(fresh) {
                files = exact
                filesStale = false
            } else if files != nil, conversation?.headSHA == fresh.headSHA {
                filesStale = true // same head, the base moved: keep it, marked
            } else {
                files = nil
                filesStale = false
            }
            withAnimation(Theme.Motion.status(reduceMotion)) { conversation = fresh }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: PR detail %@ failed: %@", ref.key, error.localizedDescription)
            failure = error.localizedDescription
        }
        // The verbs' handles and the timeline: a refusal leaves the verbs
        // saying they are still reading, never guessing.
        do {
            let fresh = try await store.prActivity(ref)
            try Task.checkCancellation()
            withAnimation(Theme.Motion.status(reduceMotion)) { activity = fresh }
            resolvedHere = [:]
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: PR activity %@ failed: %@", ref.key, error.localizedDescription)
        }
        // A departed selection stops here: the files read is the heavy one.
        guard let conversation, !Task.isCancelled else { return }
        do {
            let loaded = try await store.prFiles(conversation)
            try Task.checkCancellation()
            files = loaded
            filesStale = false
            filesFailure = nil
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: PR files %@ failed: %@", ref.key, error.localizedDescription)
            filesFailure = error.localizedDescription
        }
        // The mirror holds both ends once the files are read: its log is local.
        do {
            let loaded = try await store.prCommits(conversation)
            try Task.checkCancellation()
            commits = loaded
            commitsFailure = nil
        } catch is CancellationError {
        } catch {
            NSLog("pultik: PR commits %@ failed: %@", ref.key, error.localizedDescription)
            commitsFailure = error.localizedDescription
        }
    }

    // MARK: - Verbs (D4, D5)

    /// A verb reached by its letter, the bar or ⌘K: one that needs nothing
    /// more runs, the rest open their sheet — merge and close a confirm.
    private func reach(_ verb: PRVerb) {
        guard verb.enabled else {
            show(verb.disabledReason ?? "Not now", failed: true)
            return
        }
        switch verb.action {
        case let .run(change): perform(change, done: "\(verb.title) — done")
        case let .confirm(change): open(.confirm(change, title: verb.title))
        case .merge: open(.merge)
        case let .review(event): open(.review(event))
        case .comment:
            open(nil)
            withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(PRTab.overview.rawValue) }
            DispatchQueue.main.async { commentFocused = true }
        case .edit: open(.edit)
        case let .pick(field): open(.pick(field))
        }
    }

    /// Opens a sheet with its starting values, or closes the open one.
    private func open(_ next: VerbSheet?) {
        sheetFailure = nil
        sheetBusy = false
        switch next {
        case .merge:
            let options = activity?.merge
            mergeMethod = options?.preferred ?? options?.methods.first ?? .merge
            deleteBranch = !(options?.deleteBranchOnMerge ?? false) && options?.headRefID != nil
        case .review:
            sheetText = ""
        case .edit:
            sheetTitle = conversation?.title ?? ""
            sheetText = conversation?.body ?? ""
        case let .pick(field):
            picked = currentPicks(field)
            choices = nil
            let repo = ref.repo
            Task {
                do { choices = try await store.prChoices(repo: repo) } catch {
                    NSLog("pultik: PR choices %@ failed: %@", repo, error.localizedDescription)
                    sheetFailure = error.localizedDescription
                }
            }
        default:
            break
        }
        withAnimation(Theme.Motion.push(reduceMotion)) { sheet = next }
    }

    private func currentPicks(_ field: MetadataField) -> Set<String> {
        guard let activity else { return [] }
        switch field {
        case .labels: return Set(activity.labels.map(\.id))
        case .assignees: return Set(activity.assignees.map(\.id))
        case .reviewers: return Set(activity.requestedReviewers.map(\.id) + activity.requestedTeams.map(\.id))
        case .milestone: return Set(activity.milestone.map { [$0.id] } ?? [])
        }
    }

    /// ↵ in a confirm, ⌘↵ in a typed sheet.
    private func runSheet() {
        guard let sheet, let pr = conversation, !sheetBusy else { return }
        switch sheet {
        case .menu:
            open(nil)
        case .merge:
            perform(.merge(mergeMethod, expectedHead: pr.headSHA, deleteBranch: deleteBranch),
                    done: "Merged into \(pr.baseRef)", closing: true)
        case let .confirm(change, title):
            perform(change, done: "\(title.replacingOccurrences(of: "…", with: "")) — done", closing: true)
        case let .review(event):
            perform(.submitReview(event, body: sheetText), done: "Review submitted", closing: true)
        case .edit:
            perform(.edit(title: sheetTitle == pr.title ? nil : sheetTitle, body: sheetText == pr.body ? nil : sheetText),
                    done: "Saved", closing: true)
        case let .pick(field):
            perform(pickVerb(field), done: "\(field.rawValue.capitalized) updated", closing: true)
        }
    }

    private func pickVerb(_ field: MetadataField) -> ChangeRequestVerb {
        switch field {
        case .labels: return .setLabels(Array(picked))
        case .assignees: return .setAssignees(Array(picked))
        case .reviewers:
            let teams = Set(choices?.teams.map(\.id) ?? activity?.requestedTeams.map(\.id) ?? [])
            return .setReviewers(users: picked.filter { !teams.contains($0) }.sorted(), teams: picked.filter(teams.contains).sorted())
        case .milestone:
            return .setMilestone(choices?.milestones.first { picked.contains($0.id) }
                ?? activity?.milestone.flatMap { picked.contains($0.id) ? $0 : nil })
        }
    }

    /// Runs one verb through the host; the sheet stays open with the host's
    /// words when it refuses.
    private func perform(_ change: ChangeRequestVerb, done: String, closing: Bool = false) {
        sheetBusy = true
        sheetFailure = nil
        let ref = ref
        Task {
            do {
                try await store.performPRVerb(change, ref: ref)
                if closing { open(nil) }
                show(done, failed: false)
            } catch {
                NSLog("pultik: PR verb on %@ failed: %@", ref.key, error.localizedDescription)
                sheetFailure = error.localizedDescription
                if sheet == nil { show(error.localizedDescription, failed: true) }
            }
            sheetBusy = false
        }
    }

    private func show(_ text: String, failed: Bool) {
        withAnimation(Theme.Motion.status(reduceMotion)) { notice = (text, failed) }
    }

    /// The composer's comment, optimistic: the box empties at once and gets
    /// its text back if the host refuses.
    private func postComment() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !commentSending else { return }
        commentSending = true
        comment = ""
        let ref = ref
        Task {
            do {
                try await store.performPRVerb(.comment(text), ref: ref)
                show("Commented", failed: false)
            } catch {
                NSLog("pultik: comment on %@ failed: %@", ref.key, error.localizedDescription)
                comment = text
                show(error.localizedDescription, failed: true)
            }
            commentSending = false
        }
    }

    /// Resolve and unresolve are optimistic too: the thread moves at once
    /// and moves back if the host refuses.
    private func resolve(_ thread: ChangeRequest.ReviewThread, _ resolved: Bool) {
        resolvedHere[thread.id] = resolved
        let ref = ref
        Task {
            do {
                try await store.performPRVerb(resolved ? .resolve(thread: thread.id) : .unresolve(thread: thread.id), ref: ref)
            } catch {
                resolvedHere[thread.id] = nil
                show(error.localizedDescription, failed: true)
            }
        }
    }

    private func reply(_ thread: ChangeRequest.ReviewThread, _ text: String) async -> Bool {
        do {
            try await store.performPRVerb(.reply(thread: thread.id, body: text), ref: ref)
            return true
        } catch {
            show(error.localizedDescription, failed: true)
            return false
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: VerbSheet) -> some View {
        let pr = conversation
        let cancel = { open(nil) }
        switch sheet {
        case .menu:
            VerbSheetCard(title: "Every verb", confirm: false, action: nil, run: {}, cancel: cancel) {
                VerbMenuList(verbs: verbs) { verb in reach(verb) }
            }
        case .merge:
            VerbSheetCard(title: PRVerbCatalogue.mergeTitle(mergeMethod, base: pr?.baseRef ?? "main"), confirm: true,
                          action: "Merge", busy: sheetBusy, failure: sheetFailure, run: runSheet, cancel: cancel) {
                Text(verbatim: "\(pr?.headRef ?? "") → \(pr?.baseRef ?? "") · head \(PRTimeline.short(pr?.headSHA))")
                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                if let methods = activity?.merge.methods, methods.count > 1 {
                    Picker("", selection: $mergeMethod) {
                        ForEach(methods, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                if activity?.merge.headRefID != nil, activity?.merge.deleteBranchOnMerge == false {
                    Toggle("Delete \(pr?.headRef ?? "the branch") after merging", isOn: $deleteBranch)
                        .toggleStyle(.checkbox).font(Theme.Typo.meta)
                }
            }
        case let .confirm(_, title):
            VerbSheetCard(title: title.replacingOccurrences(of: "…", with: "") + "?", confirm: true,
                          action: title.replacingOccurrences(of: "…", with: ""), busy: sheetBusy, failure: sheetFailure,
                          run: runSheet, cancel: cancel) {
                Text(verbatim: "#\(ref.number) \(pr?.title ?? "")").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            }
        case let .review(event):
            let pending = activity?.pendingReview?.comments.count ?? 0
            VerbSheetCard(title: event == .approve ? "Approve" : event == .requestChanges ? "Request changes" : "Comment review",
                          confirm: false, action: "Submit review",
                          enabled: event == .approve || !sheetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || pending > 0,
                          busy: sheetBusy, failure: sheetFailure, run: runSheet, cancel: cancel) {
                if pending > 0 {
                    Text("With your \(pending) pending comment\(pending == 1 ? "" : "s")").font(Theme.Typo.meta)
                        .foregroundStyle(Theme.ink2)
                }
                sheetEditor($sheetText, height: 90)
            }
        case .edit:
            VerbSheetCard(title: "Edit title and description", confirm: false, action: "Save",
                          enabled: !sheetTitle.trimmingCharacters(in: .whitespaces).isEmpty,
                          busy: sheetBusy, failure: sheetFailure, run: runSheet, cancel: cancel) {
                TextField("Title", text: $sheetTitle)
                    .textFieldStyle(.plain).font(Theme.Typo.title)
                    .padding(6)
                    .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
                sheetEditor($sheetText, height: 180)
            }
        case let .pick(field):
            VerbSheetCard(title: field.rawValue.capitalized, confirm: false, action: "Apply", busy: sheetBusy,
                          failure: sheetFailure, run: runSheet, cancel: cancel) {
                MetadataPicker(field: field, choices: choices, picked: $picked)
            }
        }
    }

    private func sheetEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Theme.Typo.body)
            .scrollContentBackground(.hidden)
            .frame(height: height)
            .padding(6)
            .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    // MARK: - The header (D7)

    /// Three lines above the tabs: glyph · title · state chip · verbs; the
    /// meta line; the roll-up. The per-run badges live in Checks.
    private func header(_ badges: [RunBadge]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                ProjectGlyph(project: object.project ?? "", symbol: object.symbol)
                Text(conversation?.title ?? object.title)
                    .font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                stateChip
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if let pr = conversation {
                        VerbBar(verbs: verbs, mergeable: PRVerbCatalogue.mergeBlock(pr, activity) == nil) { reach($0) }
                    }
                    if let url = (conversation?.url).flatMap(URL.init(string:)) ?? object.url {
                        VerbButton(verb: DetailVerb(title: "Open", symbol: "arrow.up.right", kbd: "⌘↵",
                                                    help: url.absoluteString) { OverviewURL.open(url) })
                    }
                }
            }
            metaLine
            if let conversation { rollUp(conversation, badges: badges) }
        }
    }

    private var stateChip: Chip? {
        guard let conversation else { return object.status }
        switch conversation.state {
        case .merged: return Chip("merged", .neutral, symbol: "arrow.triangle.merge")
        case .closed: return Chip("closed", .danger)
        case .open: return conversation.isDraft ? Chip("draft", .dashed) : Chip("open", .ok)
        }
    }

    /// `#412 · ExampleApp · lukas · main ← feat/x · opened Oct 2 · updated 4m ago · +12 −3`.
    private var metaLine: some View {
        var parts = [object.label, object.meta].compactMap { $0 }
        if let pr = conversation {
            let now = Date()
            parts += [pr.author ?? "ghost", "\(pr.baseRef) ← \(pr.headRef)",
                      "opened \(PultikFormat.date(pr.createdAt, now: now))"]
            if let merged = pr.mergedAt {
                parts.append("merged \(PultikFormat.ago(merged, now: now))")
            } else {
                parts.append("updated \(PultikFormat.ago(pr.updatedAt, now: now))")
            }
            parts.append("+\(pr.additions) −\(pr.deletions)")
        }
        return Text(verbatim: parts.joined(separator: " · "))
            .font(Theme.Typo.figure).monospacedDigit().foregroundStyle(Theme.ink2)
            .lineLimit(1).truncationMode(.middle)
    }

    /// One line of summary chips (D7): checks, review, threads,
    /// mergeability — each a way into the tab that holds it.
    private func rollUp(_ pr: ChangeRequest, badges: [RunBadge]) -> some View {
        let open = pr.openThreads.count
        let resolved = pr.threads.count - open
        return HStack(spacing: 6) {
            rollChip(checksChip(badges), to: .checks)
            rollChip(reviewChip(pr), to: .overview)
            if open > 0 {
                rollChip(Chip("\(open) open thread\(open == 1 ? "" : "s")", .warn, symbol: "text.bubble"), to: .overview)
            } else if resolved > 0 {
                Button {
                    showsResolved.toggle()
                    withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(PRTab.overview.rawValue) }
                } label: {
                    Chip("\(resolved) resolved", .neutral, symbol: "checkmark")
                }
                .buttonStyle(.plain)
            }
            if pr.state == .open, pr.mergeable == .conflicting {
                rollChip(Chip("conflicts", .danger, symbol: "exclamationmark.triangle"), to: .merge)
            }
            if let failure { Chip("not refreshed", .dashed, symbol: "clock").help(failure) }
            Spacer(minLength: 0)
        }
    }

    private func rollChip(_ chip: Chip, to tab: PRTab) -> some View {
        Button {
            withAnimation(Theme.Motion.tab(reduceMotion)) { router.selectTab(tab.rawValue) }
        } label: { chip }
            .buttonStyle(.plain)
            .help("Show \(tab.title)")
    }

    /// The runs as one verdict: failing leads, then running, then passed.
    private func checksChip(_ badges: [RunBadge]) -> Chip {
        let failed = badges.filter { $0.outcome == .failed }.count
        let running = badges.filter { $0.outcome == .running }.count
        if failed > 0 { return Chip("\(failed) failing", .failing) }
        if running > 0 { return Chip("\(running) running", .neutral, symbol: "circle.dotted") }
        if badges.isEmpty { return Chip("no checks", .dashed) }
        return Chip("\(badges.count) passed", .passing)
    }

    /// The Checks tab's rail: a badge per run (D6).
    private func rail(_ badges: [RunBadge]) -> some View {
        FlowRow(hSpacing: 6, vSpacing: 6) {
            ForEach(badges) { badge in
                RunBadgeView(badge: badge, focused: router.focus == badge.id) {
                    guard badge.run != nil else { return }
                    withAnimation(Theme.Motion.push(reduceMotion)) {
                        router.push(DetailRef(kind: .run, id: String(badge.id.dropFirst(4))))
                    }
                }
                .id(badge.id)
            }
            if badges.isEmpty { Chip("no checks", .dashed) }
        }
    }

    /// Every check on the head commit, failing first, with its duration.
    private func checkList(_ pr: ChangeRequest) -> some View {
        let caption = pr.checksTruncated ? "first \(pr.checks.count)" : "\(pr.checks.count)"
        return Tile(kicker: "All checks", caption: caption) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pr.checks) { check in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(check.outcome)).font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Self.tone(check.outcome)).frame(width: 14)
                        Text(check.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: check.duration.map(PultikFormat.duration) ?? "")
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                        LinkGlyph(url: check.url.flatMap(URL.init(string:)), label: "Open \(check.title)")
                    }
                    .frame(height: 22)
                }
            }
        }
    }

    private static func symbol(_ outcome: ChangeRequest.Check.Outcome) -> String {
        switch outcome {
        case .failed: "xmark"
        case .running: "circle.dotted"
        case .passed: "checkmark"
        case .skipped: "minus"
        }
    }

    private static func tone(_ outcome: ChangeRequest.Check.Outcome) -> Color {
        switch outcome {
        case .failed: Theme.danger
        case .running, .passed: Theme.ok
        case .skipped: Theme.ink3
        }
    }

    private func reviewChip(_ pr: ChangeRequest) -> Chip {
        let requested = pr.requested.isEmpty ? "" : " · \(pr.requested.count) asked"
        switch pr.reviewVerdict {
        case .approved: return Chip("approved\(requested)", .ok, symbol: "checkmark")
        case .changesRequested: return Chip("changes requested", .warn, symbol: "exclamationmark")
        default: return Chip(pr.requested.isEmpty ? "no review" : "awaiting review\(requested)", .dashed)
        }
    }

    /// The focused badge's jobs and lane (D6: ⇥ focus or hover lists them).
    private func jobsLine(_ badge: RunBadge) -> some View {
        let jobs = badge.jobs.map { job in
            let mark = switch job.outcome {
            case .failed: "✗"
            case .running: "●"
            case .passed: "✓"
            case .skipped: "–"
            }
            return "\(mark) \(job.name)"
        }
        let lane = badge.live.first.map { " · on \($0.lane)" } ?? ""
        return HStack(spacing: 8) {
            Text(verbatim: jobs.joined(separator: "  ") + lane)
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(2)
            Spacer(minLength: 6)
            KbdHint("↵")
            Text("run").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .transition(.opacity)
    }

    // MARK: - Sections (only when there is something to act on)

    private func failingSection(_ failing: [RunBadge]) -> some View {
        Tile(kicker: "Failing", caption: failing.count == 1 ? "1 run" : "\(failing.count) runs") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(failing) { badge in
                    Button {
                        withAnimation(Theme.Motion.push(reduceMotion)) {
                            router.push(DetailRef(kind: .run, id: String(badge.id.dropFirst(4))))
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
                                .frame(width: 14)
                            Text(badge.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                            if let job = badge.failingJob {
                                Text("failed in \(job)").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(verbatim: badge.elapsed(now: Date()).map(PultikFormat.duration) ?? "")
                                .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.ink3)
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(badge.run == nil)
                }
            }
        }
    }

    private func threadsSection(_ pr: ChangeRequest) -> some View {
        let open = openThreads(pr)
        let resolved = pr.threads.filter { resolvedHere[$0.id] ?? $0.isResolved }
        let caption = ["\(open.count) open", resolved.isEmpty ? nil : "\(resolved.count) resolved",
                       pr.threadsTruncated ? "first \(pr.threads.count)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Tile(kicker: "Threads", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(open) { thread in
                    ThreadView(thread: thread, repo: ref.repo, resolver: resolver, resolved: false,
                               resolve: { resolve(thread, true) }, reply: { await reply(thread, $0) })
                        .padding(4)
                        .focusRing(router.focus == "thread:\(thread.id)")
                        .id("thread:\(thread.id)")
                }
                if !resolved.isEmpty {
                    DisclosureLine(text: "\(resolved.count) resolved", open: $showsResolved) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ok)
                    }
                    if showsResolved {
                        ForEach(resolved) { thread in
                            ThreadView(thread: thread, repo: ref.repo, resolver: resolver, resolved: true,
                                       resolve: { resolve(thread, false) }, reply: { await reply(thread, $0) })
                        }
                    }
                }
            }
        }
    }

    private func changesSection(_ changes: [ChangeRequest.Review]) -> some View {
        Tile(kicker: "Changes requested") {
            FlowRow(hSpacing: 6, vSpacing: 6) {
                ForEach(changes, id: \.author) { review in
                    Chip("\(review.author) · \(review.submittedAt.map { PultikFormat.ago($0, now: Date()) } ?? "")",
                         .warn, symbol: "exclamationmark")
                }
            }
        }
    }

    // MARK: - Description (D8)

    /// The host's references, resolved against Pultík's own indexes.
    private var resolver: AutolinkResolver {
        store.autolinks
    }

    @ViewBuilder
    private func descriptionItems(_ pr: ChangeRequest) -> some View {
        let body = pr.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let blocks = description?.source == body ? description?.blocks ?? [] : GFM.blocks(body, repo: ref.repo,
                                                                                               resolver: resolver)
            Text("Description").microLabel()
                .tileSlice(top: true)
                .onAppear { if description?.source != body { description = (body, blocks) } }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                GFMBlockView(block: block)
                    .padding(.top, 8)
                    .tileSlice()
            }
            Color.clear.frame(height: 14).tileSlice(bottom: true)
                .padding(.bottom, 10)
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Tile { SkeletonBars(widths: [0.6, 0.35]) }
            Tile { SkeletonBars(widths: [0.45, 0.7, 0.55]) }
        }
    }
}

/// One run badge (D6): its state's shape, the workflow, the failing job or
/// the jobs' count, a live timer while it runs, the lane our CI runs it on
/// and that lane's queue. Status changes crossfade with a one-shot symbol
/// effect; under Reduce Motion they only crossfade.
struct RunBadgeView: View {
    let badge: RunBadge
    var focused = false
    let action: () -> Void
    @Environment(\.panelIsPresented) private var presented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tone)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                Text(badge.name).font(Theme.Typo.meta.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let job = badge.failingJob {
                    Text(job).font(Theme.Typo.meta).foregroundStyle(Theme.danger).lineLimit(1)
                } else if badge.jobs.count > 1 {
                    Text(verbatim: "\(badge.passed)/\(badge.jobs.count)").font(Theme.Typo.meta).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                }
                timer
                if let lane = badge.live.first?.lane, badge.outcome == .running {
                    Text(lane).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                if let queue = badge.queuedOnLane {
                    Text(verbatim: queue.next ? "next · \(queue.waiting) queued" : "\(queue.waiting) queued")
                        .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.warn)
                }
                if badge.run != nil, hovering || focused {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 9)).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 2).opacity(focused ? 1 : 0) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(badge.jobs.map { "\($0.name) — \($0.outcome.rawValue)" }.joined(separator: "\n")
            + (badge.live.first.map { "\non \($0.lane)" } ?? ""))
        .animation(Theme.Motion.status(reduceMotion), value: badge.outcome)
        .animation(Theme.Motion.focus(reduceMotion), value: focused)
        .accessibilityLabel("\(badge.name) \(badge.outcome.rawValue)")
    }

    @ViewBuilder private var timer: some View {
        if badge.outcome == .running, presented, badge.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: badge.elapsed(now: context.date).map(PultikFormat.duration) ?? "")
                    .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                    .contentTransition(.numericText())
            }
        } else if let elapsed = badge.elapsed(now: Date()) {
            Text(verbatim: PultikFormat.duration(elapsed)).font(Theme.Typo.meta).monospacedDigit()
                .foregroundStyle(Theme.ink3)
        }
    }

    private var symbol: String {
        switch badge.outcome {
        case .failed: "xmark"
        case .running: "circle.dotted"
        case .passed: "checkmark"
        case .skipped: "minus"
        }
    }

    private var tone: Color {
        switch badge.outcome {
        case .failed: Theme.danger
        case .running, .passed: Theme.ok
        case .skipped: Theme.ink3
        }
    }

    private var fill: Color {
        switch badge.outcome {
        case .failed: Theme.danger.opacity(0.14)
        default: hovering ? Theme.surfaceRaised : Theme.surface
        }
    }
}

/// A review thread: where it is, the lines it is about, its comments in
/// GitHub-flavoured markdown.
private struct ThreadView: View {
    let thread: ChangeRequest.ReviewThread
    let repo: String
    let resolver: AutolinkResolver
    /// As drawn: what was resolved or reopened here applies at once.
    var resolved = false
    var resolve: () -> Void = {}
    /// Posts a reply; true once the host took it.
    var reply: (String) async -> Bool = { _ in false }
    @State private var replying = false
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.head)
                if thread.isOutdated { Chip("outdated", .dashed) }
                if resolved { Chip("resolved", .ok, symbol: "checkmark") }
                Spacer(minLength: 6)
                Button(replying ? "Cancel" : "Reply") { replying.toggle() }
                    .buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                Button(resolved ? "Unresolve" : "Resolve", action: resolve)
                    .buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                LinkGlyph(url: thread.comments.first.flatMap { URL(string: $0.url) },
                          label: "Open the review thread on \(thread.path)")
            }
            let hunk = Self.tail(of: thread.hunk)
            if !hunk.isEmpty {
                DiffView(lines: hunk)
                    .padding(.vertical, 4)
                    .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(comment.author).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                        Text(verbatim: PultikFormat.ago(comment.createdAt, now: Date()))
                            .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    }
                    GFMStack(blocks: GFM.blocks(comment.body, repo: repo, resolver: resolver), spacing: 6)
                }
            }
            if replying {
                HStack(alignment: .bottom, spacing: 8) {
                    TextEditor(text: $draft)
                        .font(Theme.Typo.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 54)
                        .padding(4)
                        .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    Button("Reply") {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        sending = true
                        Task {
                            if await reply(text) {
                                draft = ""
                                replying = false
                            }
                            sending = false
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// The commented line and the three above it.
    static func tail(of hunk: String) -> [DiffLine] {
        Array(DiffLine.parse(hunk).filter { $0.kind != .hunk }.suffix(4))
    }
}

private extension View {
    /// One horizontal slice of a tile drawn as several lazy items: the
    /// `surface` fill, the tile's 14 pt content edge, and the tile's corners
    /// on its first and last slice.
    func tileSlice(top: Bool = false, bottom: Bool = false) -> some View {
        let radius = Theme.Radius.tile
        return padding(.horizontal, 14)
            .padding(.top, top ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: UnevenRoundedRectangle(
                topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0, style: .continuous))
    }
}


