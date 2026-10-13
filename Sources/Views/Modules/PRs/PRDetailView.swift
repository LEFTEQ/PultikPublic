import SwiftUI

/// A change request's card (stay in Pultík D5): one header — the detail
/// header's title, state and ⌘↵, one meta line, and one rail of run badges,
/// review and threads — then a section only where there is something to
/// act on (a failing run, open threads, requested changes), the description
/// as GitHub-flavoured markdown (D8), and every changed file with its diff.
/// Drawn at once from what the warm set holds (D9); the CI watch keeps its
/// badges live while it is on screen (D7). ⇥ walks badges, open threads and
/// files (D3); ↵ on a badge slides its run card over the PR (D2).
struct PRDetailContent: View {
    let store: StatusStore
    let ref: ChangeRequestRef
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
    /// Files the operator expanded or collapsed against their default.
    @State private var toggledFiles: Set<String> = []
    /// The description parsed once per body (D8).
    @State private var description: (source: String, blocks: [GFMBlock])?

    /// A file this long starts collapsed, and so does every file once the
    /// diff drawn above it passes the page budget: layout stays bounded.
    static let collapseLines = 300
    static let pageLines = 1500

    #if DEBUG
    /// The sections the open card draws, for the panel driver (`prSections`).
    @MainActor static var drawnSections: [String] = []
    #endif

    init(store: StatusStore, ref: ChangeRequestRef) {
        self.store = store
        self.ref = ref
        let cached = store.cachedPRDetail(ref)
        _conversation = State(initialValue: cached.conversation)
        _files = State(initialValue: cached.files)
    }

    private var badges: [RunBadge] {
        guard let conversation else { return [] }
        let live = store.ciWatchTarget?.request == ref ? store.ciLive : nil
        return RunBadge.badges(conversation.checks, repo: ref.repo, host: ref.host, live: live)
    }

    /// Its own scroller over one lazy stack (`ModulePage.detailScrollsItself`):
    /// every section, description block, file header and diff chunk is a
    /// lazy item, so only what is near the viewport exists.
    var body: some View {
        let badges = badges
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let conversation {
                        VStack(alignment: .leading, spacing: 10) {
                            metaRow(conversation)
                            rail(conversation, badges: badges)
                            if let focused = badges.first(where: { $0.id == router.focus }) { jobsLine(focused) }
                        }
                        .padding(.bottom, 12)
                        let failing = badges.filter { $0.outcome == .failed }
                        if !failing.isEmpty { failingSection(failing).padding(.bottom, 10) }
                        if !conversation.openThreads.isEmpty || conversation.threads.contains(where: \.isResolved) {
                            if !conversation.openThreads.isEmpty || showsResolved {
                                threadsSection(conversation).padding(.bottom, 10)
                            }
                        }
                        let changes = conversation.reviews.filter { $0.verdict == .changesRequested }
                        if !changes.isEmpty { changesSection(changes).padding(.bottom, 10) }
                        descriptionItems(conversation)
                        filesItems(conversation)
                    } else if let failure {
                        Tile(kicker: "Pull request") {
                            Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                        }
                    } else {
                        skeleton
                    }
                }
                .padding([.horizontal, .bottom], 14)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: router.focus) { _, focus in
                guard let focus, focusTargets(badges).contains(focus) else { return }
                withAnimation(Theme.Motion.focus(reduceMotion)) { scroller.scrollTo(focus, anchor: .center) }
            }
        }
        .task(id: LoadKey(ref: ref, attempt: attempt, confirmed: store.ciConfirmed[ref] ?? 0)) { await load() }
        // D3: this card is the top layer while no card covers it.
        .onChange(of: FocusReport(targets: focusTargets(badges), top: ownsKeys), initial: true) { _, report in
            if report.top { router.setFocusTargets(report.targets) }
        }
        // D7: watched while on screen and something runs.
        .onChange(of: watchTarget(badges), initial: true) { _, target in store.watchCI(target) }
        .onDisappear { store.watchCI(nil) }
        .onChange(of: router.activated) { _, target in
            guard ownsKeys, let target, target.hasPrefix("file:") else { return }
            toggledFiles.formSymmetricDifference([String(target.dropFirst(5))])
            router.consumeActivation()
        }
        #if DEBUG
        .onChange(of: drawnSections(badges), initial: true) { _, sections in Self.drawnSections = sections }
        #endif
    }

    private struct LoadKey: Equatable {
        let ref: ChangeRequestRef
        let attempt: Int
        /// The CI watch confirmed a transition: read the held answer again.
        let confirmed: Int
    }

    private struct FocusReport: Equatable {
        let targets: [String]
        let top: Bool
    }

    /// This card is the detail on screen and no card covers it.
    private var ownsKeys: Bool {
        router.module == .prs && router.detailOpen && router.stack.isEmpty
    }

    /// ⇥'s walk (D3): run badges, then open threads, then files.
    private func focusTargets(_ badges: [RunBadge]) -> [String] {
        guard let conversation else { return [] }
        return badges.filter { $0.run != nil }.map(\.id) + conversation.openThreads.map { "thread:\($0.id)" }
            + (files?.files.map { "file:\($0.path)" } ?? [])
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
        // A departed selection stops here: the files read is the heavy one.
        guard let conversation, !Task.isCancelled else { return }
        do {
            let loaded = try await store.prFiles(conversation)
            try Task.checkCancellation()
            files = loaded
            filesStale = false
            filesFailure = nil
        } catch is CancellationError {
        } catch {
            NSLog("pultik: PR files %@ failed: %@", ref.key, error.localizedDescription)
            filesFailure = error.localizedDescription
        }
    }

    // MARK: - The header (D5)

    /// `lukas · main ← feat/x · opened Oct 2 · updated 4m ago`, then what
    /// the state chip never says.
    private func metaRow(_ pr: ChangeRequest) -> some View {
        let now = Date()
        var parts = [pr.author ?? "ghost", "\(pr.baseRef) ← \(pr.headRef)", "opened \(PultikFormat.date(pr.createdAt, now: now))"]
        if let merged = pr.mergedAt {
            parts.append("merged \(PultikFormat.ago(merged, now: now))")
        } else {
            parts.append("updated \(PultikFormat.ago(pr.updatedAt, now: now))")
        }
        parts.append("+\(pr.additions) −\(pr.deletions)")
        return HStack(spacing: 6) {
            Text(verbatim: parts.joined(separator: " · "))
                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if pr.state == .open, pr.mergeable == .conflicting {
                Chip("conflicts", .danger, symbol: "exclamationmark.triangle")
            }
            if let failure { Chip("not refreshed", .dashed, symbol: "clock").help(failure) }
        }
    }

    /// One rail: a badge per run (D6), then the review and the threads.
    private func rail(_ pr: ChangeRequest, badges: [RunBadge]) -> some View {
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
            reviewChip(pr)
            let open = pr.openThreads.count
            let resolved = pr.threads.count - open
            if open > 0 {
                Chip("\(open) open thread\(open == 1 ? "" : "s")", .warn, symbol: "text.bubble")
            } else if resolved > 0 {
                Button { showsResolved.toggle() } label: {
                    Chip("\(resolved) resolved", .neutral, symbol: "checkmark")
                }
                .buttonStyle(.plain)
            }
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
        let open = pr.openThreads
        let resolved = pr.threads.filter(\.isResolved)
        let caption = ["\(open.count) open", resolved.isEmpty ? nil : "\(resolved.count) resolved",
                       pr.threadsTruncated ? "first \(pr.threads.count)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Tile(kicker: "Threads", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(open) { thread in
                    ThreadView(thread: thread, repo: ref.repo, resolver: resolver)
                        .padding(4)
                        .focusRing(router.focus == "thread:\(thread.id)")
                        .id("thread:\(thread.id)")
                }
                if !resolved.isEmpty {
                    DisclosureLine(text: "\(resolved.count) resolved", open: $showsResolved) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ok)
                    }
                    if showsResolved {
                        ForEach(resolved) { ThreadView(thread: $0, repo: ref.repo, resolver: resolver) }
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

    // MARK: - Files

    /// The Files tile as lazy items stitched into one surface: its heading,
    /// each file's header, each `DiffView.chunkSize`-line chunk of an open
    /// diff and the notes — so a long diff costs only its visible chunks.
    @ViewBuilder
    private func filesItems(_ pr: ChangeRequest) -> some View {
        let caption = "\(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files") · +\(pr.additions) −\(pr.deletions)"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files").microLabel()
                Spacer(minLength: 8)
                Text(verbatim: caption).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if files != nil, filesStale {
                HStack(spacing: 8) {
                    Chip(filesFailure == nil ? "the base moved · refreshing" : "the base moved · not refreshed",
                         .dashed, symbol: "clock")
                        .help(filesFailure ?? "This diff was compared at an older base; the current one is loading")
                    if filesFailure != nil {
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
            if files == nil, let filesFailure {
                HStack(spacing: 8) {
                    Text(verbatim: "Files not loaded — \(filesFailure)")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(2)
                    Spacer(minLength: 6)
                    Button("Retry") { attempt += 1 }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else if files == nil {
                SkeletonBars(widths: [0.5, 0.7, 0.4])
            }
        }
        .tileSlice(top: true)
        if let files {
            ForEach(Self.items(files, toggled: toggledFiles)) { item in
                switch item.kind {
                case let .header(file, lines, collapsed):
                    FileHeader(file: file, lines: lines, collapsed: collapsed) {
                        toggledFiles.formSymmetricDifference([file.path])
                    }
                    .focusRing(router.focus == "file:\(file.path)", radius: Theme.Radius.kbd)
                    .id("file:\(file.path)")
                    .padding(.top, 8)
                    .tileSlice()
                case let .chunk(lines, digits, first, last):
                    DiffView(lines: lines, digits: digits)
                        .padding(.top, first ? 4 : 0)
                        .padding(.bottom, last ? 4 : 0)
                        .background(Theme.canvasDeep, in: UnevenRoundedRectangle(
                            topLeadingRadius: first ? Theme.Radius.row : 0, bottomLeadingRadius: last ? Theme.Radius.row : 0,
                            bottomTrailingRadius: last ? Theme.Radius.row : 0, topTrailingRadius: first ? Theme.Radius.row : 0,
                            style: .continuous))
                        .tileSlice()
                case let .note(text):
                    Text(verbatim: text).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .padding(.leading, 20)
                        .padding(.top, 2)
                        .tileSlice()
                }
            }
        }
        Color.clear.frame(height: 14).tileSlice(bottom: true)
    }

    /// The Files tile's lazy items. A file's default fold: past
    /// `collapseLines`, or once the lines drawn above pass `pageLines`.
    private static func items(_ files: ChangeSet, toggled: Set<String>) -> [FileItem] {
        var items: [FileItem] = []
        var drawn = 0
        for file in files.files {
            let lines = file.patch.map(DiffLine.parse) ?? []
            let byDefault = lines.count > collapseLines || drawn + lines.count > pageLines
            if !byDefault { drawn += lines.count }
            let collapsed = byDefault != toggled.contains(file.path)
            items.append(FileItem(id: "file:\(file.path)", kind: .header(file, lines: lines.count, collapsed: collapsed)))
            if lines.isEmpty {
                items.append(FileItem(id: "note:\(file.path)", kind: .note(file.trimmed
                        ? "Past the patch budget — ⌘↵ opens it on the host" : "No diff — binary, renamed or too large")))
            } else if collapsed {
                items.append(FileItem(id: "note:\(file.path)", kind: .note("\(lines.count) lines — click or ↵ to show")))
            } else {
                let digits = DiffTextView.digits(lines)
                let starts = Array(stride(from: 0, to: lines.count, by: DiffView.chunkSize))
                for (index, start) in starts.enumerated() {
                    items.append(FileItem(id: "chunk:\(file.path):\(start)", kind: .chunk(
                        Array(lines[start ..< min(start + DiffView.chunkSize, lines.count)]), digits: digits,
                        first: index == 0, last: index == starts.count - 1)))
                }
                if file.trimmed {
                    items.append(FileItem(id: "note:\(file.path)",
                                          kind: .note("Diff cut at \(ChangeSet.patchLineLimit) lines — ⌘↵ opens the rest")))
                }
            }
        }
        if files.truncated {
            items.append(FileItem(id: "truncated", kind: .note("The host lists the first \(files.files.count) files — ⌘↵ opens the rest")))
        }
        return items
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

/// One lazy item of the Files tile.
private struct FileItem: Identifiable {
    enum Kind {
        case header(ChangedFile, lines: Int, collapsed: Bool)
        case chunk([DiffLine], digits: Int, first: Bool, last: Bool)
        case note(String)
    }

    let id: String
    let kind: Kind
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

/// A review thread: where it is, the lines it is about, its comments in
/// GitHub-flavoured markdown.
private struct ThreadView: View {
    let thread: ChangeRequest.ReviewThread
    let repo: String
    let resolver: AutolinkResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.head)
                if thread.isOutdated { Chip("outdated", .dashed) }
                if thread.isResolved { Chip("resolved", .ok, symbol: "checkmark") }
                Spacer(minLength: 6)
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
        }
    }

    /// The commented line and the three above it.
    static func tail(of hunk: String) -> [DiffLine] {
        Array(DiffLine.parse(hunk).filter { $0.kind != .hunk }.suffix(4))
    }
}

/// One changed file: its header, then its diff — or why there is none.
/// One changed file's header row: fold chevron, status, path, counts. Its
/// diff and notes follow as their own lazy items.
private struct FileHeader: View {
    let file: ChangedFile
    let lines: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: lines == 0 ? "doc" : collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 12)
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tone)
                    .help(file.status.rawValue)
                Text(verbatim: file.path).font(Theme.Typo.figure).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.head)
                if let previous = file.previousPath {
                    Text(verbatim: "← \(previous)").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                Text(verbatim: "+\(file.additions)").font(Theme.Typo.figure).foregroundStyle(Theme.ok)
                Text(verbatim: "−\(file.deletions)").font(Theme.Typo.figure).foregroundStyle(Theme.danger)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lines == 0)
    }

    private var symbol: String {
        switch file.status {
        case .added: "plus"
        case .removed: "minus"
        case .renamed, .copied: "arrow.right"
        default: "pencil"
        }
    }

    private var tone: Color {
        switch file.status {
        case .added: Theme.ok
        case .removed: Theme.danger
        default: Theme.ink2
        }
    }
}

