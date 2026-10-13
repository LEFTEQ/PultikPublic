import SwiftUI

/// `.ci` (spec 2026-09-23, D10): everything the right rail's CI section summarises —
/// running jobs with their runner cost, queues per lane, and GitHub's failed
/// runs. `running` / `queued` / `failed` as the filter narrow to that group;
/// any other text matches repo, workflow, job or lane.
struct CIPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?

    private enum Slice: String {
        case running, queued, failed
    }

    private var trimmed: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private var slice: Slice? {
        Slice(rawValue: trimmed.lowercased())
    }

    private var text: String {
        slice == nil ? trimmed : ""
    }

    private func shows(_ candidate: Slice) -> Bool {
        slice == nil || slice == candidate
    }

    private func matches(_ fields: String...) -> Bool {
        text.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private var jobs: [CIJob] {
        (store.laneBoard.lanes.flatMap(\.jobs) + store.laneBoard.elsewhere)
            .filter { matches($0.repo, $0.workflow, $0.jobName, $0.lane) }
            .sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// Lanes with a queue or a dead controller — the two things worth a row.
    private var waiting: [CILane] {
        store.laneBoard.lanes.filter { ($0.queued > 0 || !$0.up) && matches($0.name) }
    }

    private var failures: [FailedRun] {
        store.repos.flatMap { repo -> [FailedRun] in
            let name = repo.slug.split(separator: "/").last.map(String.init) ?? repo.slug
            let runs = repo.runs.filter(\.failed).map {
                FailedRun(id: "run:\($0.id)", repo: name, title: $0.name ?? "workflow",
                          branch: $0.headBranch, at: $0.updatedAt, url: URL(string: $0.htmlUrl))
            }
            let deploys = repo.deploys.filter(\.failed).map {
                FailedRun(id: "deploy:\($0.id)", repo: name, title: "deploy \($0.deployment.environment)",
                          branch: $0.deployment.ref, at: $0.deployment.createdAt,
                          url: $0.url.flatMap { URL(string: $0) })
            }
            return runs + deploys
        }
        .filter { matches($0.repo, $0.title, $0.branch ?? "") }
        .sorted { $0.at > $1.at }
    }

    var body: some View {
        let glance = CIGlance(board: store.laneBoard, repos: store.repos)
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header(glance)
                if shows(.running) {
                    Kicker(text: "Running", count: jobs.count)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                    if jobs.isEmpty {
                        RailNote(text.isEmpty ? "Nothing running" : "No match")
                    } else {
                        // One tick for every row's elapsed clock.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(jobs) { job in
                                    CIJobPageRow(job: job, now: context.date, selected: selectedID == Self.jobID(job))
                                        .id(Self.jobID(job))
                                }
                            }
                        }
                    }
                }
                if shows(.queued) {
                    Kicker(text: "Queued", count: glance.queued, tone: glance.queued > 0 ? .orange : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                    if let pool = store.laneBoard.pool {
                        PoolRow(pool: pool)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                    }
                    ForEach(waiting) { lane in
                        RailRow(dot: .filled(lane.up ? Color.orange : Color.red),
                                title: lane.name,
                                meta: lane.up ? "\(lane.queued) queued" : "controller down",
                                help: (["\(lane.backend) lane · \(lane.trustGroup)", lane.tier.map { "tier \($0)" }, lane.kind]
                                    .compactMap { $0 }).joined(separator: " · "),
                                selected: selectedID == "lane:\(lane.name)",
                                action: {})
                            .id("lane:\(lane.name)")
                    }
                    if store.laneBoard.elsewhereQueued > 0 && text.isEmpty {
                        RailRow(dot: .hollow, title: "elsewhere",
                                meta: "\(store.laneBoard.elsewhereQueued) queued",
                                help: "GitHub-hosted or unmapped lanes", selected: selectedID == Self.elsewhereID, action: {})
                            .id(Self.elsewhereID)
                    }
                    if waiting.isEmpty && (store.laneBoard.elsewhereQueued == 0 || !text.isEmpty) {
                        RailNote(text.isEmpty ? "Nothing waiting for a runner" : "No match")
                    }
                }
                if shows(.failed) {
                    Kicker(text: "Failed runs", count: failures.count, tone: failures.isEmpty ? .secondary : .red)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                    if glance.githubUnreachable {
                        RailNote("GitHub unreachable")
                    } else if failures.isEmpty {
                        RailNote(text.isEmpty ? "No failed runs" : "No match")
                    }
                    ForEach(failures) { run in
                        RailRow(dot: .filled(.red), title: run.title,
                                subtitle: [run.repo, run.branch].compactMap { $0 }.joined(separator: " · "),
                                meta: run.at.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)),
                                help: run.url?.absoluteString ?? "",
                                selected: selectedID == run.id,
                                action: { if let url = run.url { NSWorkspace.shared.open(url) } })
                            .id(run.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func header(_ glance: CIGlance) -> some View {
        HStack(spacing: 8) {
            Text("CI")
                .font(.system(size: 14, weight: .semibold))
            Text("\(glance.running) running · \(glance.queued) queued · \(glance.failedRuns) failed")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            // The Grafana escape hatch the old CI · lanes rail carried as its
            // accessory; the rail's CI section now opens this page instead.
            Button {
                if let url = URL(string: "https://runners.ops.example.invalid") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("BuildServer JIT lane fleet — Grafana runners dashboard")
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// The CI module's list until its own slice lands (WP6): running jobs,
/// waiting lanes, then failed runs — in the order the page draws them.
extension CIPage: ModulePage {
    static func jobID(_ job: CIJob) -> String { "job:\(job.id)" }
    static let elsewhereID = "lane:elsewhere"

    /// The running-job row's fixed columns plus room for the job name.
    var listWidth: CGFloat { 640 }
    var minListWidth: CGFloat { 640 }

    var objects: [ModuleObject] {
        let now = Date()
        var objects: [ModuleObject] = []
        if shows(.running) {
            objects += jobs.map { job in
                var facts = [ModuleObject.Fact(label: "repo", value: "\(job.org)/\(job.repo)"),
                             .init(label: "workflow", value: job.workflow),
                             .init(label: "job", value: job.jobName),
                             .init(label: "lane", value: job.lane)]
                if let since = job.since { facts.append(.init(label: "running", value: PultikFormat.ago(since, now: now))) }
                if let cpu = job.cpuPercent { facts.append(.init(label: "runner cpu", value: "\(Int(cpu.rounded()))% of a core")) }
                if let memory = job.memoryBytes { facts.append(.init(label: "runner memory", value: PultikFormat.size(memory))) }
                return ModuleObject(id: Self.jobID(job), title: job.workflow, label: job.repo,
                                    status: Chip("running", .ok), meta: job.jobName, symbol: "gearshape.2",
                                    project: job.repo, url: job.runURL,
                                    context: [Chip(job.lane, .neutral, symbol: "rectangle.stack")], facts: facts)
            }
        }
        if shows(.queued) {
            objects += waiting.map { lane in
                var facts = [ModuleObject.Fact(label: "backend", value: lane.backend),
                             .init(label: "trust group", value: lane.trustGroup),
                             .init(label: "queued", value: "\(lane.queued)"),
                             .init(label: "running", value: "\(lane.running)")]
                if let tier = lane.tier { facts.append(.init(label: "tier", value: "\(tier)")) }
                if let kind = lane.kind { facts.append(.init(label: "kind", value: kind)) }
                return ModuleObject(id: "lane:\(lane.name)", title: lane.name,
                                    status: lane.up ? Chip("\(lane.queued) queued", .warn) : Chip("controller down", .danger),
                                    meta: "\(lane.backend) lane", symbol: "rectangle.stack", facts: facts)
            }
            if store.laneBoard.elsewhereQueued > 0, text.isEmpty {
                objects.append(ModuleObject(id: Self.elsewhereID, title: "elsewhere",
                                            status: Chip("\(store.laneBoard.elsewhereQueued) queued", .warn),
                                            meta: "GitHub-hosted or unmapped lanes", symbol: "rectangle.stack"))
            }
        }
        if shows(.failed) {
            objects += failures.map { run in
                var facts = [ModuleObject.Fact(label: "repo", value: run.repo),
                             .init(label: "failed", value: PultikFormat.ago(run.at, now: now))]
                if let branch = run.branch { facts.insert(.init(label: "branch", value: branch), at: 1) }
                if let url = run.url { facts.append(.init(label: "run", value: url.absoluteString)) }
                return ModuleObject(id: run.id, title: run.title, label: run.repo,
                                    status: Chip("failed", .failing), meta: run.branch, symbol: "xmark.octagon",
                                    project: run.repo, url: run.url, verbs: rerunVerb(run.id),
                                    context: run.branch.map { [Chip($0, .neutral, symbol: "arrow.triangle.branch")] } ?? [],
                                    facts: facts)
            }
        }
        return objects
    }

    /// The failed run behind an object id (`run:<id>`) — deploys have none.
    func runRef(for id: String) -> CIRunRef? {
        guard id.hasPrefix("run:"), let runID = Int(id.dropFirst(4)) else { return nil }
        return store.ciRunRef(runID: runID)
    }

    /// Re-run failed (⌘R): the detail's primary verb, the same path the key
    /// takes. Before the detail has read the run, the verb reads it first.
    private func rerunVerb(_ id: String) -> [DetailVerb] {
        guard let ref = runRef(for: id) else { return [] }
        return [DetailVerb(title: "Re-run failed", symbol: "arrow.clockwise", kbd: "⌘R", role: .primary,
                           help: "Re-run the failed jobs once GitHub confirms this attempt still failed") {
            CIRerunCenter.shared.rerun(ref, shown: store.cachedCIRun(ref)?.run, store: store)
        }]
    }

    /// A running job's run, from its run link (stay in Pultík: any run opens).
    static func runRef(url: URL?) -> CIRunRef? {
        guard let url, let runID = CIWatch.runID(in: url) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return CIRunRef(repo: "\(parts[0])/\(parts[1])", runID: runID)
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let ref = runRef(for: object.id) ?? Self.runRef(url: object.url) {
            CIRunDetailContent(store: store, ref: ref).id(ref)
        }
    }
}

/// A failed workflow run or deploy, flattened so both read as one list.
private struct FailedRun: Identifiable {
    let id: String
    let repo: String
    let title: String
    let branch: String?
    let at: Date
    let url: URL?
}

/// One running job across the page's width: repo · workflow · job · lane ·
/// elapsed · runner cost. CPU is the runner container's per-core
/// utilisation — never the cost of sibling build containers or KVM guests.
private struct CIJobPageRow: View {
    let job: CIJob
    let now: Date
    var selected = false
    @State private var hovering = false
    @Environment(\.openRow) private var openRow

    var body: some View {
        Button {
            // Stay in Pultík: the run opens here; its page is ⌘↵.
            openRow?(CIPage.jobID(job))
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color.green.opacity(0.85))
                    .frame(width: RailRowMetrics.dotSize, height: RailRowMetrics.dotSize)
                Text(job.repo)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .frame(width: 110, alignment: .leading)
                Text(job.workflow)
                    .font(RailRowMetrics.titleFont)
                    .frame(width: 140, alignment: .leading)
                Text(job.jobName)
                    .font(RailRowMetrics.titleFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(job.lane)
                    .frame(width: 84, alignment: .leading)
                Text(elapsed)
                    .frame(width: 56, alignment: .trailing)
                Text(cost)
                    .frame(width: 92, alignment: .trailing)
                    .help("Runner container only; 100% is one CPU core")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(job.runURL == nil ? 0 : hovering ? 0.8 : 0.3)
            }
            .font(RailRowMetrics.metaFont)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.vertical, RailRowMetrics.verticalInset)
            .background { RowBackground(selected: selected, hovering: hovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(job.runURL?.absoluteString ?? "No run link reported")
        .accessibilityLabel("\(job.repo), \(job.workflow), \(job.jobName), on \(job.lane), \(elapsed)")
    }

    private var elapsed: String {
        guard let since = job.since else { return "—" }
        return Duration.seconds(max(0, now.timeIntervalSince(since)))
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    /// Empty until the collector has a sample for this runner (samples
    /// expire after 90 s) — never a `— · —` placeholder.
    private var cost: String {
        [job.cpuPercent.map { PultikFormat.percent($0 / 100) }, job.memoryBytes.map(PultikFormat.size)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
