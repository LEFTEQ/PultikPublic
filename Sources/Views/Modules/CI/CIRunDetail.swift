import SwiftUI

/// A CI run as a card over its change request (stay in Pultík D2, D11): a
/// header — the run's state, workflow, attempt, branch and timer, the mini
/// needs graph, Re-run failed (⌘R) on a failed run — over three keyboard
/// lists, jobs | steps | log. Any run opens: running, passed or failed. The
/// top card owns the keys: ↑/↓ walk the focused column, ⇥ moves between
/// columns, ↵ narrows the next one — never a mutation.
struct RunCard: View {
    let store: StatusStore
    let ref: CIRunRef
    let walk: DetailRef
    let router: ModuleRouter

    var body: some View {
        RunDetailLoader(store: store, ref: ref) { detail, graph in
            VStack(alignment: .leading, spacing: 10) {
                RunCardHeader(store: store, ref: ref, detail: detail, graph: graph)
                RunColumns(store: store, ref: ref, detail: detail, graph: graph, walk: walk, router: router)
            }
            .padding(14)
        }
    }
}

/// A failed run in the CI module's detail (WP6): the same columns under the
/// module's header, plus its re-run outcome and its context.
struct CIRunDetailContent: View {
    let store: StatusStore
    let ref: CIRunRef
    @State private var health: SemaforRepoHealth?

    var body: some View {
        RunDetailLoader(store: store, ref: ref) { detail, graph in
            VStack(alignment: .leading, spacing: 10) {
                if let rerun = CIRerunCenter.shared.outcomes[ref.runID] { RerunLine(outcome: rerun) }
                RunColumns(store: store, ref: ref, detail: detail, graph: graph, walk: nil, router: nil)
                    .frame(height: 420)
                context(detail.run)
            }
            // Semafor is context: it never holds back the run. The run's
            // runners name its host, whose Semafor alone saw its jobs.
            .task(id: ref) { health = (try? await store.semaforRepoHealth(of: detail)) ?? nil }
        }
    }

    private func context(_ run: CIRun) -> some View {
        let recent = store.repos.first { $0.slug == ref.repo }?.runs
            .filter { $0.name == run.name }
            .sorted { $0.createdAt < $1.createdAt } ?? []
        let failedRecent = recent.filter(\.failed).count
        return Tile(kicker: "Context", caption: run.event) {
            VStack(alignment: .leading, spacing: 10) {
                if !recent.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(run.name ?? "workflow") · last \(recent.count)").microLabel()
                        HStack(spacing: 3) {
                            ForEach(recent) { past in RunDot(run: past, current: past.id == run.id) }
                        }
                        Text(verbatim: "\(failedRecent) of \(recent.count) failed")
                            .font(Theme.Typo.meta).monospacedDigit()
                            .foregroundStyle(failedRecent > 1 ? Theme.warn : Theme.ink2)
                    }
                }
                FlowRow(hSpacing: 6, vSpacing: 6) {
                    if let health {
                        Chip("\(ref.repo.split(separator: "/").last.map(String.init) ?? ref.repo) fails "
                            + "\(PultikFormat.percent(health.failureRate, tenths: true)) of jobs · 7 d",
                            health.failureRate > 0.1 ? .warn : .neutral, symbol: "waveform.path.ecg")
                    }
                    ForEach(run.changeRequests, id: \.self) { number in
                        Chip("PR #\(number)", .neutral, symbol: "arrow.triangle.pull")
                    }
                    if let branch = run.headBranch {
                        Chip("\(branch) @ \(run.headSHA.prefix(7))", .neutral, symbol: "arrow.triangle.branch")
                    }
                }
            }
        }
    }
}

/// Reads the run (held first, then fresh), its graph from the mirror, and
/// reads it again on a re-run, on the CI watch's confirm, and every 30 s
/// while it runs on screen.
private struct RunDetailLoader<Content: View>: View {
    let store: StatusStore
    let ref: CIRunRef
    @ViewBuilder var content: (CIRunDetail, WorkflowGraph?) -> Content
    @Environment(\.panelIsPresented) private var presented
    @State private var detail: CIRunDetail?
    @State private var graph: WorkflowGraph?
    @State private var failure: String?

    init(store: StatusStore, ref: CIRunRef, @ViewBuilder content: @escaping (CIRunDetail, WorkflowGraph?) -> Content) {
        self.store = store
        self.ref = ref
        self.content = content
        _detail = State(initialValue: store.cachedCIRun(ref))
    }

    private struct LoadKey: Equatable {
        let ref: CIRunRef
        let rerun: Int
        let confirmed: Int
        let live: [CILiveJob]
    }

    var body: some View {
        Group {
            if let detail {
                content(detail, graph)
            } else if let failure {
                Tile(kicker: "Run") { Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.ink2) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Tile { SkeletonBars(widths: [0.6, 0.4]) }
                    Tile { SkeletonBars(widths: [0.8, 0.7, 0.75, 0.5]) }
                }
            }
        }
        .task(id: LoadKey(ref: ref, rerun: CIRerunCenter.shared.generations[ref.runID] ?? 0,
                          confirmed: store.ciConfirmReads, live: store.ciLive?.jobs[ref.runID] ?? [])) {
            await load()
            // Live while visible: a running run is read again every 30 s.
            while !Task.isCancelled, presented, detail?.run.status != .completed {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await load(maxAge: 30)
            }
        }
    }

    private func load(maxAge: TimeInterval = StatusStore.CIDetailResources.run.staleAfter) async {
        do {
            let fresh = try await store.ciRun(ref, maxAge: maxAge)
            try Task.checkCancellation()
            detail = fresh
            failure = nil
            if graph == nil { graph = await store.workflowGraph(fresh.run) }
        } catch is CancellationError {
        } catch {
            NSLog("pultik: CI run %@ failed: %@", ref.key, error.localizedDescription)
            failure = error.localizedDescription
        }
    }
}

/// The card's header: state, workflow, attempt, branch, the timer, the mini
/// graph and the verbs.
private struct RunCardHeader: View {
    let store: StatusStore
    let ref: CIRunRef
    let detail: CIRunDetail
    let graph: WorkflowGraph?
    @Environment(\.panelIsPresented) private var presented
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let run = detail.run
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RunStateGlyph(status: run.status, conclusion: run.conclusion)
                Text(run.name ?? "Run").font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
                if let title = run.displayTitle {
                    Text(title).font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 8)
                MiniGraph(waves: waves)
                if run.failed {
                    Button { CIRerunCenter.shared.rerun(ref, shown: run, store: store) } label: {
                        Label("Re-run failed", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .help("⌘R — re-run the failed jobs once the host confirms this attempt still failed")
                }
                LinkGlyph(url: URL(string: run.url), label: "Open the run — ⌘↵")
            }
            HStack(spacing: 6) {
                Text(verbatim: meta(run)).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
                timer(run)
                if let outcome = CIRerunCenter.shared.outcomes[ref.runID] { RerunLine(outcome: outcome) }
            }
        }
        .animation(Theme.Motion.status(reduceMotion), value: run.status)
    }

    private var waves: [[CIRunJob]] {
        graph.map { $0.ordered(detail.jobs) } ?? WorkflowGraph.timingWaves(detail.jobs)
    }

    private func meta(_ run: CIRun) -> String {
        // The state in words: a cancelled run's hollow rings explain themselves.
        var parts = [run.conclusion.map { $0 == .timedOut ? "timed out" : $0.rawValue } ?? run.status.rawValue,
                     "attempt \(run.attempt)", run.event]
        if let branch = run.headBranch { parts.append("\(branch) @ \(run.headSHA.prefix(7))") }
        parts.append("\(detail.jobs.filter { $0.conclusion == .success }.count)/\(detail.jobs.count) jobs passed")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func timer(_ run: CIRun) -> some View {
        if let start = run.startedAt {
            if run.status != .completed, presented {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: PultikFormat.duration(context.date.timeIntervalSince(start)))
                        .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ok)
                        .contentTransition(.numericText())
                }
            } else {
                Text(verbatim: PultikFormat.duration(max(0, run.updatedAt.timeIntervalSince(start))))
                    .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// Jobs | steps | log as three lists (D11). `walk` is the card's keyboard
/// state; without one (the CI module) clicks pick.
struct RunColumns: View {
    let store: StatusStore
    let ref: CIRunRef
    let detail: CIRunDetail
    let graph: WorkflowGraph?
    let walk: DetailRef?
    let router: ModuleRouter?
    @State private var clicked: [Int: String] = [:]
    @State private var log: LogTail?
    @State private var logFailure: String?

    private var waves: [[CIRunJob]] {
        graph.map { $0.ordered(detail.jobs) } ?? WorkflowGraph.timingWaves(detail.jobs)
    }

    private func pick(_ column: Int) -> String? {
        walk?.picks[column] ?? clicked[column]
    }

    /// The picked job, else the one to read first: failing, running, first.
    private var job: CIRunJob? {
        if let id = pick(0), let picked = detail.jobs.first(where: { "job:\($0.id)" == id }) { return picked }
        return WorkflowGraph.firstToRead(detail, waves: waves)
    }

    private var columnIDs: [[String]] {
        [waves.flatMap { $0 }.map { "job:\($0.id)" },
         job?.steps.map { "step:\($0.number)" } ?? [],
         log?.lines.map { "line:\($0.number)" } ?? []]
    }

    var body: some View {
        let job = job
        HStack(alignment: .top, spacing: 0) {
            column(0, "Jobs", width: 250) { jobsList }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            column(1, job.map { "Steps · \($0.name)" } ?? "Steps", width: 250) { stepsList(job) }
            Rectangle().fill(Theme.hairline).frame(width: 1)
            column(2, logTitle(job), width: nil) { logList }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .task(id: LogKey(job: job?.id, status: job?.status)) { await loadLog(job) }
        .onChange(of: columnIDs, initial: true) { _, ids in
            guard let router, router.stack.last == walk else { return }
            router.setCardColumns(ids)
        }
    }

    private struct LogKey: Equatable {
        let job: Int?
        let status: CIStatus?
    }

    private func logTitle(_ job: CIRunJob?) -> String {
        guard let log else { return "Log" }
        guard let first = log.lines.first?.number, let last = log.lines.last?.number else { return "Log · empty" }
        return "Log · \(job?.failingStep?.name ?? job?.name ?? "") · \(first)–\(last) of \(log.totalLines)"
    }

    private func column(_ index: Int, _ title: String, width: CGFloat?,
                        @ViewBuilder _ content: @escaping () -> some View) -> some View {
        let focused = walk?.column == index
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).microLabel()
                .foregroundStyle(focused ? Theme.ink : Theme.ink3)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .overlay(alignment: .bottomLeading) {
                    Rectangle().fill(Theme.accent).frame(width: 24, height: 2).opacity(focused ? 1 : 0)
                        .padding(.leading, 10).offset(y: 3)
                }
            ScrollViewReader { scroller in
                ScrollView { content().padding([.horizontal, .bottom], 6) }
                    .onChange(of: pick(index)) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id) } }
                    }
            }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
    }

    private var jobsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(waves.enumerated()), id: \.offset) { index, wave in
                if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 3) }
                ForEach(wave) { item in
                    ColumnRow(id: "job:\(item.id)", picked: job?.id == item.id) {
                        RunStateGlyph(status: item.status, conclusion: item.conclusion)
                        Text(item.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: item.duration.map(PultikFormat.duration) ?? "")
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                    } action: { clicked[0] = "job:\(item.id)" }
                }
            }
        }
    }

    private func stepsList(_ job: CIRunJob?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(job?.steps ?? []) { step in
                ColumnRow(id: "step:\(step.number)", picked: pick(1) == "step:\(step.number)"
                    || (pick(1) == nil && job?.failingStep?.number == step.number)) {
                    RunStateGlyph(status: step.status, conclusion: step.conclusion)
                    Text(step.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: step.duration.map(PultikFormat.duration) ?? "")
                        .font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                } action: { clicked[1] = "step:\(step.number)" }
            }
            if job?.steps.isEmpty ?? true {
                Text(job == nil ? "No jobs yet" : "Waiting for a runner").font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3).padding(8)
            }
        }
    }

    @ViewBuilder private var logList: some View {
        if let log {
            LogWell(tail: log, picked: pick(2))
            if !log.anchored {
                Text("No error line — the log's last lines").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).padding(6)
            }
        } else if let logFailure {
            Text(verbatim: "Log not loaded — \(logFailure)").font(Theme.Typo.meta).foregroundStyle(Theme.ink2).padding(6)
        } else {
            SkeletonBars(widths: [0.9, 0.7, 0.8, 0.6, 0.85]).padding(6)
        }
    }

    private func loadLog(_ job: CIRunJob?) async {
        // No runner yet, no log: GitHub answers 404 for a queued job's.
        guard let job, job.startedAt != nil, job.status == .running || job.status == .completed else {
            log = nil
            logFailure = nil
            return
        }
        do {
            let tail = try await store.ciLogTail(ref, job: job)
            try Task.checkCancellation()
            log = tail
            logFailure = nil
        } catch is CancellationError {
        } catch {
            NSLog("pultik: CI log %@ job %@ failed: %@", ref.key, String(job.id), error.localizedDescription)
            logFailure = error.localizedDescription
        }
    }
}

/// One row of a column: the pick is the neutral lift with the accent edge.
private struct ColumnRow<Label: View>: View {
    let id: String
    let picked: Bool
    @ViewBuilder let label: () -> Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { label() }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background { RowBackground(selected: picked, hovering: hovering) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .id(id)
    }
}

/// A run, job or step's state as a shape: ✗ broke, a spinning dot while it
/// runs, ✓ passed, a hollow ring for skipped or cancelled.
struct RunStateGlyph: View {
    let status: CIStatus
    let conclusion: CIConclusion?

    var body: some View {
        Group {
            if conclusion?.failing == true {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
            } else if status != .completed {
                StatusDot(tone: status == .running ? Theme.ok : Theme.ink3, style: status == .running ? .spin : .ring)
            } else if conclusion == .success {
                StatusDot(tone: Theme.ok)
            } else {
                StatusDot(tone: Theme.ink3, style: .ring)
            }
        }
        .frame(width: 14)
    }
}

/// The waves as columns of dots (D11's mini needs graph).
private struct MiniGraph: View {
    let waves: [[CIRunJob]]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(waves.prefix(8).enumerated()), id: \.offset) { index, wave in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 6, weight: .bold)).foregroundStyle(Theme.ink3)
                }
                VStack(spacing: 2) {
                    ForEach(wave.prefix(6)) { job in
                        Circle().fill(tone(job)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .accessibilityLabel("\(waves.count) waves")
    }

    private func tone(_ job: CIRunJob) -> Color {
        if job.conclusion?.failing == true { return Theme.danger }
        if job.status != .completed { return Theme.ok.opacity(0.5) }
        return job.conclusion == .success ? Theme.ok : Theme.ink3
    }
}

/// The log tail in a `canvasDeep` well: a gutter of line numbers, the error
/// lines on a `danger` rule and wash (DESIGN.md LogWell), the picked line lifted.
private struct LogWell: View {
    let tail: LogTail
    var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tail.lines, id: \.number) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(line.number)")
                        .font(Theme.Typo.code).foregroundStyle(Theme.ink3)
                        .frame(width: 44, alignment: .trailing)
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .font(Theme.Typo.code)
                        .foregroundStyle(line.error ? Theme.danger : Theme.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
                .padding(.trailing, 8)
                .background(picked == "line:\(line.number)" ? Theme.selection
                    : line.error ? Theme.danger.opacity(0.08) : .clear)
                .overlay(alignment: .leading) {
                    if line.error { Rectangle().fill(Theme.danger).frame(width: 2) }
                }
                .id("line:\(line.number)")
            }
        }
        .padding(.vertical, 6)
        // Not selectable: a focused text view would take keys from the
        // search field (CLAUDE.md, every key through KeyboardCoordinator);
        // ⌘↵ opens the full log on the host to copy from.
        .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

private struct RerunLine: View {
    let outcome: CIRerunCenter.Outcome

    var body: some View {
        switch outcome {
        case .checking: Chip("checking the run…", .neutral, symbol: "arrow.clockwise")
        case .requested: Chip("re-run of the failed jobs requested", .ok, symbol: "arrow.clockwise")
        case let .skipped(why): Chip("not re-run · \(why)", .dashed)
        case let .failed(why): Chip("re-run failed", .danger).help(why)
        }
    }
}

/// One past run of the workflow: ✗ failed, ✓ passed, a dotted circle while
/// running, a hollow ring for anything else (cancelled, skipped); the run on
/// screen is outlined.
private struct RunDot: View {
    let run: WorkflowRun
    let current: Bool

    private var look: (symbol: String, tone: Color, fill: Color) {
        if run.failed { return ("xmark", Theme.danger, Theme.danger.opacity(0.18)) }
        if run.isRunning { return ("circle.dotted", Theme.ink3, .clear) }
        if run.conclusion == "success" { return ("checkmark", Theme.ok, Theme.ok.opacity(0.14)) }
        return ("circle", Theme.ink3, .clear)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(look.fill)
            .overlay {
                Image(systemName: look.symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(look.tone)
            }
            .overlay {
                if current { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ink, lineWidth: 1) }
            }
            .frame(width: 14, height: 14)
            .help("\(run.headBranch ?? "") · \(run.conclusion ?? run.status)")
    }
}
