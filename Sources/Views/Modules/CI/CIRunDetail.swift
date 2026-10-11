import SwiftUI

/// A failed run's own content under the detail header (WP6, AC 10; the D4-B
/// frame, card 77428): the failing job's steps with their durations, the
/// tail of its log around the error, every job, and context — the repo's 7 d
/// failure rate, the workflow's recent runs, the PR. Re-run failed (⌘R) is
/// the header's primary verb. Read on open, never polled.
struct CIRunDetailContent: View {
    let store: StatusStore
    let ref: CIRunRef

    @State private var detail: GitHubCIRun.Detail?
    @State private var log: GitHubCIRun.LogTail?
    @State private var health: SemaforRepoHealth?
    @State private var failure: String?
    @State private var logFailure: String?
    @State private var showsPassedJobs = false
    @State private var showsPassedSteps = false

    init(store: StatusStore, ref: CIRunRef) {
        self.store = store
        self.ref = ref
        _detail = State(initialValue: store.cachedCIRun(ref))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rerun = CIRerunCenter.shared.outcomes[ref.runID] { rerunLine(rerun) }
            if let detail {
                if let job = detail.failingJob {
                    steps(job)
                    logTile(job)
                }
                jobs(detail)
                context(detail.run)
            } else if let failure {
                Tile(kicker: "Run") { Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.ink2) }
            } else {
                Tile { SkeletonBars(widths: [0.6, 0.4]) }
                Tile { SkeletonBars(widths: [0.8, 0.7, 0.75, 0.5]) }
            }
        }
        // A settled re-run bumps the generation: the run is read again.
        .task(id: LoadKey(ref: ref, generation: CIRerunCenter.shared.generations[ref.runID] ?? 0)) { await load() }
        // Semafor is context: it never holds back the log.
        .task(id: ref) { health = (try? await store.semaforRepoHealth())?.first { $0.repo == ref.repo } }
    }

    private struct LoadKey: Equatable {
        let ref: CIRunRef
        let generation: Int
    }

    private func load() async {
        do {
            let fresh = try await store.ciRun(ref)
            try Task.checkCancellation()
            // Another attempt or failing job: the old log no longer explains it.
            if fresh.run.runAttempt != detail?.run.runAttempt || fresh.failingJob?.id != detail?.failingJob?.id {
                log = nil
                logFailure = nil
            }
            detail = fresh
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: CI run %@ %d failed: %@", ref.repo, ref.runID, error.localizedDescription)
            failure = error.localizedDescription
        }
        guard let job = detail?.failingJob, !Task.isCancelled else { return }
        do {
            let tail = try await store.ciLogTail(ref, job: job)
            try Task.checkCancellation()
            log = tail
            logFailure = nil
        } catch is CancellationError {
        } catch {
            NSLog("pultik: CI log %@ job %d failed: %@", ref.repo, job.id, error.localizedDescription)
            logFailure = error.localizedDescription
        }
    }

    // MARK: - Re-run

    private func rerunLine(_ outcome: CIRerunCenter.Outcome) -> some View {
        HStack(spacing: 8) {
            switch outcome {
            case .checking: Chip("checking the run…", .neutral, symbol: "arrow.clockwise")
            case .requested: Chip("re-run of the failed jobs requested", .ok, symbol: "arrow.clockwise")
            case let .skipped(why): Chip("not re-run · \(why)", .dashed)
            case let .failed(why): Chip("re-run failed", .danger).help(why)
            }
            Spacer()
        }
    }

    // MARK: - Steps

    private func steps(_ job: GitHubCIRun.Job) -> some View {
        let passed = job.steps.filter { $0.conclusion == "success" }.count
        let total = job.duration.map(PultikFormat.duration) ?? ""
        // A long job folds its passed steps: the failing one leads the glance.
        let folds = job.steps.count > 8 && passed > 0
        let shown = folds && !showsPassedSteps ? job.steps.filter { $0.conclusion != "success" } : job.steps
        return Tile(kicker: "Steps · \(job.name)", caption: "\(passed)/\(job.steps.count) passed · \(total)") {
            VStack(alignment: .leading, spacing: 10) {
                FlowRow(hSpacing: 6, vSpacing: 6) {
                    ForEach(shown) { step in stepChip(step) }
                }
                if folds {
                    DisclosureLine(text: showsPassedSteps ? "hide the \(passed) passed" : "\(passed) passed",
                                   open: $showsPassedSteps) {
                        StatusDot(tone: Theme.ok, size: 5)
                    }
                }
                StepBar(steps: job.steps)
            }
        }
    }

    private func stepChip(_ step: GitHubCIRun.Step) -> Chip {
        let label = [step.name, step.duration.map(PultikFormat.duration)].compactMap { $0 }.joined(separator: " ")
        switch step.conclusion {
        case "success": return Chip(label, .passing)
        case "failure", "timed_out", "startup_failure": return Chip(label, .failing)
        case "skipped": return Chip(label, .dashed)
        case nil: return Chip(label, .neutral, symbol: "circle.dotted")
        default: return Chip(label, .neutral)
        }
    }

    // MARK: - Log

    private func logTile(_ job: GitHubCIRun.Job) -> some View {
        let step = job.failingStep?.name ?? job.name
        let caption: String? = log.map { tail in
            guard let first = tail.lines.first?.number, let last = tail.lines.last?.number else { return "empty log" }
            return "lines \(first)–\(last) of \(tail.totalLines)"
        }
        return Tile(kicker: "Log · \(step) · tail", caption: caption) {
            if let log {
                LogWell(tail: log)
                if !log.anchored {
                    Text("No ##[error] line — the log's last lines").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            } else if let logFailure {
                Text(verbatim: "Log not loaded — \(logFailure)").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            } else {
                SkeletonBars(widths: [0.9, 0.7, 0.8, 0.6, 0.85])
            }
        }
    }

    // MARK: - Jobs

    private func jobs(_ detail: GitHubCIRun.Detail) -> some View {
        let failing = detail.jobs.filter(\.failed)
        let other = detail.jobs.filter { !$0.failed }
        let caption = "attempt \(detail.run.runAttempt) · \(failing.count) failed · \(other.count) other"
            + (detail.jobsTruncated ? " · first \(GitHubCIRun.jobLimit)" : "")
        return Tile(kicker: "Jobs", caption: caption) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(failing) { JobRow(job: $0) }
                if !other.isEmpty {
                    DisclosureLine(text: "\(other.count) passed, skipped or running", open: $showsPassedJobs) {
                        StatusDot(tone: Theme.ok, size: 5)
                    }
                    if showsPassedJobs { ForEach(other) { JobRow(job: $0) } }
                }
            }
        }
    }

    // MARK: - Context

    private func context(_ run: GitHubCIRun.Run) -> some View {
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
                            ForEach(recent) { past in
                                RunDot(run: past, current: past.id == run.id)
                            }
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
                    ForEach(run.pullRequests, id: \.self) { number in
                        Chip("PR #\(number)", .neutral, symbol: "arrow.triangle.pull")
                    }
                    if let branch = run.headBranch {
                        Chip("\(branch) @ \(run.headSha.prefix(7))", .neutral, symbol: "arrow.triangle.branch")
                    }
                }
            }
        }
    }
}

/// Each step's share of the job's time on one 4 pt track: the failing
/// step in `danger`, the rest quiet.
private struct StepBar: View {
    let steps: [GitHubCIRun.Step]

    var body: some View {
        let durations = steps.map { max($0.duration ?? 0, 0) }
        let total = max(durations.reduce(0, +), 1)
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(GitHubCIRun.Run.failing.contains(steps[index].conclusion ?? "") ? Theme.danger : Theme.hairlineStrong)
                        .frame(width: max(2, (proxy.size.width - CGFloat(steps.count) * 2) * durations[index] / total))
                }
            }
        }
        .frame(height: 4)
    }
}

/// The log tail in a `canvasDeep` well: a gutter of line numbers, the error
/// lines on a `danger` rule and wash (DESIGN.md LogWell).
private struct LogWell: View {
    let tail: GitHubCIRun.LogTail

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
                .background(line.error ? Theme.danger.opacity(0.08) : .clear)
                .overlay(alignment: .leading) {
                    if line.error { Rectangle().fill(Theme.danger).frame(width: 2) }
                }
            }
        }
        .padding(.vertical, 6)
        // Not selectable: a focused text view would take keys from the
        // search field (CLAUDE.md, every key through KeyboardCoordinator);
        // ⌘↵ opens the full log on GitHub to copy from.
        .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

private struct JobRow: View {
    let job: GitHubCIRun.Job

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if job.failed {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
                } else if job.status != "completed" {
                    StatusDot(tone: Theme.ok, style: .spin)
                } else if job.conclusion == "success" {
                    StatusDot(tone: Theme.ok)
                } else {
                    StatusDot(tone: Theme.ink3, style: .ring)
                }
            }
            .frame(width: 14)
            Text(job.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
            if let step = job.failingStep {
                Text("failed in \(step.name)").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(verbatim: job.duration.map(PultikFormat.duration) ?? "")
                .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                .frame(width: 64, alignment: .trailing)
            LinkGlyph(url: job.htmlUrl.flatMap(URL.init(string:)), label: "Open job \(job.name) on GitHub")
        }
        .frame(height: 24)
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
