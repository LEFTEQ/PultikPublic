import SwiftUI

/// `.ci` (spec 2026-09-23, D10): everything the right rail's CI section summarises —
/// one section per host (2026-10-14: its own pool from its own Semafor, its
/// running jobs with their runner cost, its waiting lanes — never a merged
/// fleet), jobs on lanes that are not ours, and GitHub's failed runs.
/// `running` / `queued` / `failed` as the filter narrow to that group; any
/// other text matches repo, workflow, job or lane.
struct CIPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// CI's Live view (vt-7727 D1) until the timeline lands as its first.
    var view: ModuleView? = .live
    var onView: (ModuleView) -> Void = { _ in }
    @Environment(\.openRow) private var openRow

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

    /// The host chip's host — one at a time, never a merged fleet (vt-7727
    /// D6, 2026-10-14) — and lanes no host claims.
    private var hosts: [String] {
        let all = store.laneBoard.hosts(in: store.servers.map(\.ref))
        guard let chip = store.ciSemaforHost else { return all }
        return [chip] + all.filter(\.isEmpty)
    }

    /// GitHub-hosted jobs running or waiting, once whatever host is picked
    /// (D14): from the Semafor that lists more hosted lanes.
    private var hostedLive: [SemaforJob] {
        SemaforCI.hostedJobs(store.semaforStates)
            .filter { $0.isLive && matches($0.repo, $0.workflow ?? "", $0.name, $0.lane) }
    }

    static func hostedID(_ job: SemaforJob) -> String { "hosted:\(job.id)" }

    private func hostName(_ host: String) -> String {
        store.servers.first { $0.ref == host }?.name ?? (host.isEmpty ? "Unplaced lanes" : host)
    }

    private func lanes(on host: String) -> [CILane] {
        store.laneBoard.lanes.filter { ($0.host ?? "") == host }
    }

    private func sorted(_ jobs: [CIJob]) -> [CIJob] {
        jobs.filter { matches($0.repo, $0.workflow, $0.jobName, $0.lane) }
            .sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    private func jobs(on host: String) -> [CIJob] {
        sorted(lanes(on: host).flatMap(\.jobs))
    }

    /// Jobs on lanes that are not ours (GitHub-hosted, unmapped).
    private var elsewhere: [CIJob] {
        sorted(store.laneBoard.elsewhere)
    }

    /// Lanes with a queue or a dead controller — the two things worth a row.
    private func waiting(on host: String) -> [CILane] {
        lanes(on: host).filter { ($0.queued > 0 || !$0.up) && matches($0.name) }
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
                if shows(.running) || shows(.queued) {
                    if hosts.isEmpty {
                        RailNote("No CI lanes reported — off the mesh?")
                    }
                    ForEach(hosts, id: \.self) { host in
                        hostSection(host)
                    }
                    elsewhereSection
                    hostedSection
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
                                mark: run.id,
                                // Stay in Pultík: the run's detail; its page is ⌘↵.
                                action: { openRow?(run.id) })
                            .id(run.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    /// One host's Firefly: its own pool (its own Semafor), its running jobs,
    /// then its lanes with a queue or a dead controller.
    @ViewBuilder
    private func hostSection(_ host: String) -> some View {
        let running = jobs(on: host)
        let waiting = waiting(on: host)
        let queued = lanes(on: host).reduce(0) { $0 + $1.queued }
        let down = lanes(on: host).contains { !$0.up }
        Kicker(text: hostName(host), count: running.count,
               tone: down ? .red : queued > 0 ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
        if shows(.queued), let pool = store.laneBoard.pools[host] {
            PoolRow(pool: pool)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }
        if shows(.running), !running.isEmpty {
            jobRows(running)
        }
        if shows(.queued) {
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
        }
        if (shows(.running) ? running.isEmpty : true), (shows(.queued) ? waiting.isEmpty : true) {
            RailNote(text.isEmpty ? (slice == .queued ? "Nothing waiting for a runner" : "Idle") : "No match")
        }
    }

    /// Jobs on lanes that are not ours, and their backlog — no host's pool.
    @ViewBuilder
    private var elsewhereSection: some View {
        let jobs = shows(.running) ? elsewhere : []
        let queued = shows(.queued) && text.isEmpty ? store.laneBoard.elsewhereQueued : 0
        if !jobs.isEmpty || queued > 0 {
            Kicker(text: "Elsewhere", count: jobs.count)
                .padding(.horizontal, 8)
                .padding(.top, 10)
            if !jobs.isEmpty { jobRows(jobs) }
            if queued > 0 {
                RailRow(dot: .hollow, title: "elsewhere", meta: "\(queued) queued",
                        help: "GitHub-hosted or unmapped lanes", selected: selectedID == Self.elsewhereID, action: {})
                    .id(Self.elsewhereID)
            }
        }
    }

    /// GitHub-hosted jobs live now, drawn once (D14), with the hour's count.
    @ViewBuilder
    private var hostedSection: some View {
        let jobs = shows(.running) ? hostedLive : []
        let hour = SemaforCI.hostedJobs(store.semaforStates).count
        if !jobs.isEmpty || hour > 0 {
            HStack(alignment: .firstTextBaseline) {
                Kicker(text: "GitHub-hosted", count: jobs.count)
                Text("\(hour) in the last hour").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            ForEach(jobs) { job in
                let id = Self.hostedID(job)
                RailRow(dot: .filled(SemaforResult.tone(job.result)),
                        title: "\(job.repo.split(separator: "/").last.map(String.init) ?? job.repo) · \(job.workflow ?? job.name)",
                        meta: [job.name, job.result].joined(separator: " · "),
                        help: job.lane, selected: selectedID == id, action: { openRow?(id) })
                    .id(id)
            }
        }
    }

    /// One tick for every row's elapsed clock.
    private func jobRows(_ jobs: [CIJob]) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 1) {
                ForEach(jobs) { job in
                    CIJobPageRow(job: job, now: context.date, selected: selectedID == Self.jobID(job))
                        .id(Self.jobID(job))
                }
            }
        }
    }

    private func header(_ glance: CIGlance) -> some View {
        CIViewHeader(store: store, view: view, onView: onView,
                     summary: "\(glance.running) running · \(glance.queued) queued · \(glance.failedRuns) failed")
    }
}

/// The CI module's list until its own slice lands (WP6): each host's
/// running jobs and waiting lanes, then elsewhere, then failed runs — in the
/// order the page draws them.
extension CIPage: ModulePage {
    static func jobID(_ job: CIJob) -> String { "job:\(job.id)" }
    static let elsewhereID = "lane:elsewhere"

    /// The running-job row's fixed columns plus room for the job name.
    var listWidth: CGFloat { 640 }
    var minListWidth: CGFloat { 640 }

    var objects: [ModuleObject] {
        let now = Date()
        var objects: [ModuleObject] = []
        for host in hosts {
            if shows(.running) { objects += jobObjects(jobs(on: host), now: now) }
            if shows(.queued) { objects += waiting(on: host).map { laneObject($0) } }
        }
        if shows(.running) { objects += jobObjects(elsewhere, now: now) }
        if shows(.queued), store.laneBoard.elsewhereQueued > 0, text.isEmpty {
            objects.append(ModuleObject(id: Self.elsewhereID, title: "elsewhere",
                                        status: Chip("\(store.laneBoard.elsewhereQueued) queued", .warn),
                                        meta: "GitHub-hosted or unmapped lanes", symbol: "rectangle.stack"))
        }
        if shows(.running) {
            objects += hostedLive.map { job in
                ModuleObject(id: Self.hostedID(job), title: job.workflow ?? job.name, label: job.repo,
                             status: Chip(job.result, job.result == "running" ? .ok : .warn), meta: job.name,
                             symbol: "cloud", project: job.repo,
                             facts: [.init(label: "lane", value: job.lane), .init(label: "job", value: job.name)])
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
                                    facts: facts, markable: runRef(for: run.id) != nil)
            }
        }
        return objects
    }

    private func jobObjects(_ jobs: [CIJob], now: Date) -> [ModuleObject] {
        let hostOfLane = Dictionary(store.laneBoard.lanes.map { ($0.name, $0.host ?? "") },
                                    uniquingKeysWith: { first, _ in first })
        return jobs.map { job in
            var facts = [ModuleObject.Fact(label: "repo", value: "\(job.org)/\(job.repo)"),
                         .init(label: "workflow", value: job.workflow),
                         .init(label: "job", value: job.jobName),
                         .init(label: "lane", value: job.lane)]
            if let host = hostOfLane[job.lane] { facts.append(.init(label: "host", value: hostName(host))) }
            if let since = job.since { facts.append(.init(label: "running", value: PultikFormat.ago(since, now: now))) }
            if let cpu = job.cpuPercent { facts.append(.init(label: "runner cpu", value: "\(Int(cpu.rounded()))% of a core")) }
            if let memory = job.memoryBytes { facts.append(.init(label: "runner memory", value: PultikFormat.size(memory))) }
            return ModuleObject(id: Self.jobID(job), title: job.workflow, label: job.repo,
                                status: Chip("running", .ok), meta: job.jobName, symbol: "gearshape.2",
                                project: job.repo, url: job.runURL,
                                context: [Chip(job.lane, .neutral, symbol: "rectangle.stack")], facts: facts)
        }
    }

    private func laneObject(_ lane: CILane) -> ModuleObject {
        var facts = [ModuleObject.Fact(label: "backend", value: lane.backend),
                     .init(label: "trust group", value: lane.trustGroup),
                     .init(label: "host", value: hostName(lane.host ?? "")),
                     .init(label: "queued", value: "\(lane.queued)"),
                     .init(label: "running", value: "\(lane.running)")]
        if let tier = lane.tier { facts.append(.init(label: "tier", value: "\(tier)")) }
        if let kind = lane.kind { facts.append(.init(label: "kind", value: kind)) }
        return ModuleObject(id: "lane:\(lane.name)", title: lane.name,
                            status: lane.up ? Chip("\(lane.queued) queued", .warn) : Chip("controller down", .danger),
                            meta: "\(lane.backend) lane", symbol: "rectangle.stack", facts: facts)
    }

    /// The failed run behind an object id (`run:<id>`) — deploys have none.
    func runRef(for id: String) -> CIRunRef? {
        guard id.hasPrefix("run:"), let runID = Int(id.dropFirst(4)) else { return nil }
        return store.ciRunRef(runID: runID)
    }

    /// Re-run failed on every marked failed run (bulk D6): one at a time,
    /// each read fresh and re-run only while it is still the failed attempt
    /// — never a whole-run re-run, and no other CI verb.
    var bulkVerbs: [BulkVerb] {
        let store = store
        return [BulkVerb(
            id: "rerun", title: "Re-run failed", symbol: "arrow.clockwise", noun: "run",
            help: "Re-run each run's failed jobs once GitHub confirms that attempt still failed",
            skip: { id in runRef(for: id) == nil ? "not a workflow run" : nil },
            run: { ids, report in
                for id in ids {
                    guard let ref = runRef(for: id) else { continue }
                    report(id, .running)
                    switch await CIRerunCenter.shared.rerunNow(ref, shown: store.cachedCIRun(ref)?.run, store: store) {
                    case .requested: report(id, .done("re-run of its failed jobs requested"))
                    case .checking: report(id, .skipped("already being re-run"))
                    case let .skipped(why): report(id, .skipped(why))
                    case let .failed(why): report(id, .failed(why))
                    }
                }
            }
        )]
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
            // Semafor keys a run by GitHub's run id: its needs graph and
            // critical path from the chip host's Semafor (vt-7727 S10).
            if let host = store.ciSemaforHost, object.id.hasPrefix("run:"), let runID = Int64(object.id.dropFirst(4)) {
                RunGraphView(store: store, host: host, runID: runID)
            }
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
