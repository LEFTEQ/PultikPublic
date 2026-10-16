import SwiftUI

// CI's Semafor views (vt-7727 D1, D6, S10): Runs, Workflows, Failures and
// Fleet as Kit tables over one host's Semafor at a time — the host chip —
// and a run's needs graph with its critical path. The Timeline is
// `CITimelinePage` over the shared canvas (vt-7781 WP6).

/// Every CI view's header: the title, the views, the host chip and the
/// view's own summary; one line "Semafor unreachable · as of HH:MM" while
/// the chip host's Semafor does not answer.
struct CIViewHeader: View {
    let store: StatusStore
    let view: ModuleView?
    var onView: (ModuleView) -> Void = { _ in }
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("CI").font(Theme.Typo.title)
                ViewBar(views: PanelModule.ci.views, selected: view, onSelect: onView)
                Text(summary).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer(minLength: 4)
                HostChips(store: store)
                Button {
                    if let url = URL(string: "https://runners.ops.example.invalid") { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 10)).foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.borderless)
                .help("BuildServer JIT lane fleet — Grafana runners dashboard")
            }
            if let host = store.ciSemaforHost, let since = store.semaforHosts[host]?.unreachableSince {
                let asOf = store.semaforHosts[host]?.fetchedAt.values.max() ?? since
                Text("Semafor unreachable · \(PultikFormat.asOf(asOf))")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// D6: CI shows one host's Semafor at a time; the busier host by default.
struct HostChips: View {
    let store: StatusStore

    var body: some View {
        let hosts = store.semaforServers
        if hosts.count > 1 {
            HStack(spacing: 4) {
                ForEach(hosts, id: \.host) { host in
                    let name = store.servers.first { $0.ref == host.host }?.name ?? host.host
                    Button { store.setCIHost(host.host) } label: {
                        Chip(name, store.ciSemaforHost == host.host ? .selected : .neutral)
                    }
                    .buttonStyle(.plain)
                    .help("Show \(name)'s Semafor")
                }
            }
        }
    }
}

/// A Semafor result as a tone: failures stand out, running is `ok` (D4).
enum SemaforResult {
    static func tone(_ result: String?) -> Color {
        switch result {
        case "failed", "failure": Theme.danger
        case "running", "succeeded", "success": Theme.ok
        case "waiting", "queued": Theme.warn
        default: Theme.ink3
        }
    }

    static func style(_ result: String?) -> StatusDot.Style {
        switch result {
        case "running": .pulse
        case "cancelled", "skipped": .ring
        default: .solid
        }
    }
}

/// A table row's shared chrome: selection, hover, the id it is scrolled to.
private struct TableRow<Content: View>: View {
    let id: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .id(id)
    }
}

private func repoName(_ slug: String) -> String {
    slug.split(separator: "/").last.map(String.init) ?? slug
}

private func matches(_ filter: String, _ fields: String?...) -> Bool {
    let text = filter.trimmingCharacters(in: .whitespaces)
    return text.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(text) == true }
}

// MARK: - Runs

/// The chip host's latest workflow runs (`/ci/runs`, 50): result, repo ·
/// workflow, title and branch, run number, duration, age. `failed` as the
/// filter (`.c failed`, vt-7727 D20) lists GitHub's failed runs instead —
/// every pinned repo's, not one host's — each a `run:` object whose detail
/// carries Re-run failed (⌘R, the one CI mutation; bulk on the marked rows).
struct CIRunsPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    let view: ModuleView?
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    static func objectID(host: String, _ run: SemaforRun) -> String { "srun:\(host)/\(run.runId)" }
    /// A GitHub failed run: the `run:` id ⌘R routes (`KeyboardCoordinator`).
    static func objectID(_ run: FailedRun) -> String { "run:\(run.run.id)" }

    private var host: String? { store.ciSemaforHost }

    /// The filter is the failed slice; its text after `failed` still filters.
    private var failedFilter: String? { ModuleView.failedRuns(filter) }

    var runs: [SemaforRun] {
        guard let host else { return [] }
        return (store.semaforHosts[host]?.runs ?? []).filter {
            matches(filter, $0.repo, $0.workflow, $0.title, $0.branch, $0.result, $0.prs?.first.map { "#\($0.number)" })
        }
    }

    /// GitHub's failed runs of every pinned repo, newest first (the retired
    /// Live page's list, D20).
    var failedRuns: [FailedRun] {
        guard let text = failedFilter else { return [] }
        return store.repos.flatMap { repo in repo.runs.filter(\.failed).map { FailedRun(repo: repo.slug, run: $0) } }
            .filter { matches(text, $0.repo, $0.run.name, $0.run.headBranch) }
            .sorted { $0.run.updatedAt > $1.run.updatedAt }
    }

    var body: some View {
        if failedFilter != nil {
            failedBody
        } else {
            semaforBody
        }
    }

    private var failedBody: some View {
        let now = Date()
        let runs = failedRuns
        let unreachable = !store.repos.isEmpty && store.repos.allSatisfy { $0.error != nil }
        return SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                CIViewHeader(store: store, view: view, onView: onView,
                             summary: "\(runs.count) failed · GitHub")
                if unreachable {
                    RailNote("GitHub unreachable")
                } else if runs.isEmpty {
                    RailNote("No failed runs")
                }
                ForEach(runs) { failed in
                    let id = Self.objectID(failed)
                    TableRow(id: id, selected: selectedID == id, action: { onOpen(id) }) {
                        StatusDot(tone: Theme.danger)
                        Text(repoName(failed.repo)).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            .frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(failed.run.name ?? "workflow").font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        Text(failed.run.headBranch ?? "").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: "#\(failed.run.id)").font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                        Text(PultikFormat.age(now.timeIntervalSince(failed.run.updatedAt)))
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink3).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var semaforBody: some View {
        let now = Date()
        let runs = runs
        return SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                CIViewHeader(store: store, view: view, onView: onView,
                             summary: "\(runs.count) runs · \(runs.filter { $0.result == "failed" }.count) failed")
                if runs.isEmpty { RailNote(host == nil ? "No Semafor configured" : "No runs read yet") }
                ForEach(runs) { run in
                    let id = host.map { Self.objectID(host: $0, run) } ?? ""
                    TableRow(id: id, selected: selectedID == id, action: { onOpen(id) }) {
                        StatusDot(tone: SemaforResult.tone(run.result), style: SemaforResult.style(run.result))
                        Text(repoName(run.repo)).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            .frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(run.workflow).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        Text([run.title, run.branch].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: run.runNumber.map { "#\($0)" } ?? "").font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                        Text(run.durationS.map { PultikFormat.duration($0) } ?? "—").font(Theme.Typo.figure)
                            .foregroundStyle(Theme.ink2).frame(width: 60, alignment: .trailing)
                        Text(SemaforTime.date(run.createdAt).map { PultikFormat.age(now.timeIntervalSince($0)) } ?? "")
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink3).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

extension CIRunsPage: ModulePage {
    var listWidth: CGFloat { 640 }
    var minListWidth: CGFloat { 640 }

    var objects: [ModuleObject] {
        if failedFilter != nil { return failedObjects }
        guard let host else { return [] }
        return runs.map { run in
            var facts = [ModuleObject.Fact(label: "repo", value: run.repo), .init(label: "workflow", value: run.workflow)]
            if let branch = run.branch { facts.append(.init(label: "branch", value: branch)) }
            if let event = run.event { facts.append(.init(label: "event", value: event)) }
            if let actor = run.actor?.login { facts.append(.init(label: "actor", value: actor)) }
            if let wait = run.waitS { facts.append(.init(label: "waited", value: PultikFormat.duration(wait))) }
            if let jobs = run.jobs?.total { facts.append(.init(label: "jobs", value: "\(jobs)")) }
            return ModuleObject(id: Self.objectID(host: host, run), title: run.title ?? run.workflow,
                                label: run.runNumber.map { "#\($0)" }, status: Chip(run.result, Self.variant(run.result)),
                                meta: "\(repoName(run.repo)) · \(run.workflow)", symbol: "play.rectangle",
                                project: repoName(run.repo), url: run.htmlUrl.flatMap(URL.init(string:)), facts: facts)
        }
    }

    static func variant(_ result: String) -> Chip.Variant {
        switch result {
        case "failed": .failing
        case "succeeded": .passing
        case "running": .ok
        case "waiting": .warn
        default: .neutral
        }
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let ref = runRef(for: object.id) {
            // A failed run reads GitHub's jobs (`RunCard`'s data); Semafor keys the same run by
            // GitHub's id, so its needs graph and critical path come from the chip host's.
            CIRunDetailContent(store: store, ref: ref).id(ref)
            if let host { RunGraphView(store: store, host: host, runID: Int64(ref.runID)) }
        } else if let host, let run = runs.first(where: { Self.objectID(host: host, $0) == object.id }) {
            RunGraphView(store: store, host: host, runID: run.runId)
        }
    }

    // MARK: Failed runs (D20)

    private var failedObjects: [ModuleObject] {
        let now = Date()
        return failedRuns.map { failed in
            let run = failed.run
            var facts = [ModuleObject.Fact(label: "repo", value: failed.repo),
                         .init(label: "failed", value: PultikFormat.ago(run.updatedAt, now: now)),
                         .init(label: "run", value: run.htmlUrl)]
            if let branch = run.headBranch { facts.insert(.init(label: "branch", value: branch), at: 1) }
            return ModuleObject(id: Self.objectID(failed), title: run.name ?? "workflow", label: repoName(failed.repo),
                                status: Chip("failed", .failing), meta: run.headBranch, symbol: "xmark.octagon",
                                project: repoName(failed.repo), url: URL(string: run.htmlUrl),
                                verbs: rerunVerb(failed.id),
                                context: run.headBranch.map { [Chip($0, .neutral, symbol: "arrow.triangle.branch")] } ?? [],
                                facts: facts, markable: true)
        }
    }

    /// The failed run behind an object id (`run:<id>`), in a pinned repo.
    func runRef(for id: String) -> CIRunRef? {
        guard id.hasPrefix("run:"), let runID = Int(id.dropFirst(4)) else { return nil }
        return store.ciRunRef(runID: runID)
    }

    /// Re-run failed (⌘R): the detail's primary verb, the path the key takes
    /// (`perform(.rerunFailed)`). Before the detail has read the run, the
    /// verb reads it first; never `rerun()`, whose 4xx fallback re-runs the whole run.
    private func rerunVerb(_ id: String) -> [DetailVerb] {
        guard let ref = runRef(for: id) else { return [] }
        let store = store
        return [DetailVerb(title: "Re-run failed", symbol: "arrow.clockwise", kbd: "⌘R", role: .primary,
                           help: "Re-run the failed jobs once GitHub confirms this attempt still failed") {
            CIRerunCenter.shared.rerun(ref, shown: store.cachedCIRun(ref)?.run, store: store)
        }]
    }

    /// Re-run failed on every marked failed run (bulk D6): one at a time,
    /// each read fresh and re-run only while it is still the failed attempt.
    var bulkVerbs: [BulkVerb] {
        guard failedFilter != nil else { return [] }
        let store = store
        let page = self
        return [BulkVerb(
            id: "rerun", title: "Re-run failed", symbol: "arrow.clockwise", noun: "run",
            help: "Re-run each run's failed jobs once GitHub confirms that attempt still failed",
            skip: { id in page.runRef(for: id) == nil ? "not a workflow run" : nil },
            run: { ids, report in
                for id in ids {
                    guard let ref = page.runRef(for: id) else { continue }
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
}

/// A GitHub failed run with its repository, so the list reads across repos.
struct FailedRun: Identifiable {
    let repo: String
    let run: WorkflowRun

    var id: String { CIRunsPage.objectID(self) }
}

/// A run's needs graph as Semafor derives it — the workflow's `needs:`
/// (`yaml`) or its timings (`inferred`) — in waves left to right, and its
/// critical path (attempt start to last completion, not a sum). Read on
/// selection (`loadRunDetail`), never polled.
struct RunGraphView: View {
    let store: StatusStore
    let host: String
    let runID: Int64

    var body: some View {
        let detail = store.semaforRunDetails[StatusStore.runDetailKey(host: host, runID: runID)]
        Tile(kicker: "Needs graph", caption: detail?.graph?.source.map { $0 == "yaml" ? "from the workflow" : "inferred from timings" }) {
            if let detail, let nodes = detail.graph?.nodes, !nodes.isEmpty {
                let critical = Set(detail.criticalPath?.nodes ?? [])
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(Self.waves(nodes).enumerated()), id: \.offset) { _, wave in
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(wave, id: \.id) { node in
                                        Chip(node.name, critical.contains(node.id) ? .selected : CIRunsPage.variant(node.result ?? ""),
                                             symbol: node.kind == "group" ? "square.stack" : nil)
                                    }
                                }
                            }
                        }
                    }
                    if let path = detail.criticalPath, let ids = path.nodes, !ids.isEmpty {
                        let names = ids.compactMap { id in nodes.first { $0.id == id }?.name }
                        Text("Critical path · \(names.joined(separator: " → "))\(path.seconds.map { " · \(PultikFormat.duration($0))" } ?? "")")
                            .font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                    } else {
                        Text("Critical path once every job has finished").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    }
                }
            } else {
                Text(detail == nil ? "reading the run…" : detail?.graph?.error ?? "no graph for this run")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
        }
        .task(id: runID) { await store.loadRunDetail(host: host, runID: runID) }
    }

    /// Top-level nodes by depth: a node runs in the wave after the latest
    /// of its needs.
    static func waves(_ nodes: [SemaforRunDetail.Node]) -> [[SemaforRunDetail.Node]] {
        let top = nodes.filter { $0.parent == nil }
        let byID = Dictionary(top.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var depth: [String: Int] = [:]
        func level(_ id: String, _ seen: Set<String>) -> Int {
            if let known = depth[id] { return known }
            guard let node = byID[id], !seen.contains(id) else { return 0 }
            let value = (node.needs ?? []).filter { byID[$0] != nil }.map { level($0, seen.union([id])) + 1 }.max() ?? 0
            depth[id] = value
            return value
        }
        for node in top { _ = level(node.id, []) }
        let count = (depth.values.max() ?? 0) + 1
        return (0..<count).map { wave in top.filter { depth[$0.id] == wave } }
    }
}

// MARK: - Workflows

/// The chip host's workflows over 7 days: runs, success rate, p50 · p95,
/// the queue's p95 wait and each day's runs.
struct CIWorkflowsPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    let view: ModuleView?
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    static func objectID(_ workflow: SemaforWorkflows.Workflow) -> String { "workflow:\(workflow.id)" }

    var workflows: [SemaforWorkflows.Workflow] {
        let all = store.ciSemaforHost.flatMap { store.semaforHosts[$0]?.workflows?.workflowList } ?? []
        return all.filter { matches(filter, $0.repo, $0.workflow, $0.path) }.sorted { $0.runs > $1.runs }
    }

    var body: some View {
        let workflows = workflows
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                CIViewHeader(store: store, view: view, onView: onView, summary: "\(workflows.count) workflows · 7 d")
                HStack(spacing: 10) {
                    Text("Workflow").microLabel()
                    Spacer()
                    Text("Runs").microLabel().frame(width: 48, alignment: .trailing)
                    Text("Success").microLabel().frame(width: 60, alignment: .trailing)
                    Text("p50 · p95").microLabel().frame(width: 110, alignment: .trailing)
                    Text("Wait p95").microLabel().frame(width: 64, alignment: .trailing)
                    Text("7 d").microLabel().frame(width: 70, alignment: .trailing)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                if workflows.isEmpty { RailNote("No workflows read yet") }
                ForEach(workflows, id: \.id) { workflow in
                    let id = Self.objectID(workflow)
                    let rate = workflow.successRate ?? 0
                    TableRow(id: id, selected: selectedID == id, action: { onOpen(id) }) {
                        Text(repoName(workflow.repo)).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            .frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(workflow.workflow).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: "\(workflow.runs)").font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                            .frame(width: 48, alignment: .trailing)
                        Text(PultikFormat.percent(rate)).font(Theme.Typo.figure)
                            .foregroundStyle(rate < 0.8 ? Theme.danger : rate < 0.95 ? Theme.warn : Theme.ink2)
                            .frame(width: 60, alignment: .trailing)
                        Text("\(workflow.p50S.map { PultikFormat.duration($0) } ?? "—") · \(workflow.p95S.map { PultikFormat.duration($0) } ?? "—")")
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink2).frame(width: 110, alignment: .trailing)
                        Text(workflow.waitP95S.map { PultikFormat.duration($0) } ?? "—").font(Theme.Typo.figure)
                            .foregroundStyle(Theme.ink3).frame(width: 64, alignment: .trailing)
                        Sparkline(values: (workflow.trend ?? []).map { Double($0.runs) },
                                  ceiling: Double((workflow.trend ?? []).map(\.runs).max() ?? 1), height: 16)
                            .frame(width: 70)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

extension CIWorkflowsPage: ModulePage {
    var listWidth: CGFloat { 700 }
    var minListWidth: CGFloat { 700 }

    var objects: [ModuleObject] {
        workflows.map { workflow in
            var facts = [ModuleObject.Fact(label: "repo", value: workflow.repo), .init(label: "runs", value: "\(workflow.runs)")]
            if let path = workflow.path { facts.append(.init(label: "path", value: path)) }
            if let failed = workflow.failed { facts.append(.init(label: "failed", value: "\(failed)")) }
            if let cancelled = workflow.cancelled { facts.append(.init(label: "cancelled", value: "\(cancelled)")) }
            return ModuleObject(id: Self.objectID(workflow), title: workflow.workflow, label: repoName(workflow.repo),
                                status: workflow.successRate.map { Chip(PultikFormat.percent($0), $0 < 0.8 ? .danger : .neutral) },
                                meta: workflow.path, symbol: "flowchart", project: repoName(workflow.repo), facts: facts)
        }
    }
}

// MARK: - Failures

/// The chip host's failed jobs over 7 days, clustered by their first error.
struct CIFailuresPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    let view: ModuleView?
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    static func objectID(_ cluster: SemaforFailures.Cluster) -> String { "failure:\(cluster.key)" }

    var clusters: [SemaforFailures.Cluster] {
        let all = store.ciSemaforHost.flatMap { store.semaforHosts[$0]?.failures?.clusterList } ?? []
        return all.filter { cluster in
            matches(filter, cluster.firstError, cluster.latest?.job, (cluster.repos ?? []).joined(separator: " "),
                    (cluster.workflows ?? []).joined(separator: " "))
        }
    }

    var body: some View {
        let now = Date()
        let clusters = clusters
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                CIViewHeader(store: store, view: view, onView: onView,
                             summary: "\(clusters.count) clusters · \(clusters.reduce(0) { $0 + $1.count }) failed jobs · 7 d")
                if clusters.isEmpty { RailNote("No failures clustered in 7 days") }
                ForEach(clusters, id: \.key) { cluster in
                    let id = Self.objectID(cluster)
                    TableRow(id: id, selected: selectedID == id, action: { onOpen(id) }) {
                        Text(verbatim: "×\(cluster.count)").font(Theme.Typo.figure).foregroundStyle(Theme.danger)
                            .frame(width: 44, alignment: .trailing)
                        Text(cluster.firstError ?? cluster.key).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text((cluster.repos ?? []).map(repoName).joined(separator: ", ")).font(Theme.Typo.meta)
                            .foregroundStyle(Theme.ink3).lineLimit(1).frame(width: 140, alignment: .trailing)
                        Text(SemaforTime.date(cluster.lastAt).map { PultikFormat.age(now.timeIntervalSince($0)) } ?? "")
                            .font(Theme.Typo.figure).foregroundStyle(Theme.ink3).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }
}

extension CIFailuresPage: ModulePage {
    var listWidth: CGFloat { 620 }

    var objects: [ModuleObject] {
        clusters.map { cluster in
            var facts = [ModuleObject.Fact(label: "failed jobs", value: "\(cluster.count)")]
            if let repos = cluster.repos, !repos.isEmpty { facts.append(.init(label: "repos", value: repos.joined(separator: ", "))) }
            if let workflows = cluster.workflows, !workflows.isEmpty {
                facts.append(.init(label: "workflows", value: workflows.joined(separator: ", ")))
            }
            if let step = cluster.latest?.stepName { facts.append(.init(label: "latest step", value: step)) }
            return ModuleObject(id: Self.objectID(cluster), title: cluster.firstError ?? cluster.key,
                                label: cluster.latest?.job, status: Chip("×\(cluster.count)", .danger),
                                meta: (cluster.repos ?? []).map(repoName).joined(separator: ", "), symbol: "ladybug",
                                url: cluster.latest?.htmlUrl.flatMap(URL.init(string:)), facts: facts)
        }
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let cluster = clusters.first(where: { Self.objectID($0) == object.id }) {
            Tile(kicker: "First error") {
                Text(cluster.firstError ?? "—").font(Theme.Typo.code).foregroundStyle(Theme.ink2).textSelection(.enabled)
            }
            if let jobs = cluster.jobs, !jobs.isEmpty {
                Tile(kicker: "Jobs", caption: "\(jobs.count)") {
                    Text(jobs.joined(separator: " · ")).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                }
            }
        }
    }
}

// MARK: - Fleet

/// The chip host's lanes keyed host + lane (D14) — what admission holds
/// now and what 30 days attributed — then the GitHub-hosted lanes once,
/// from the Semafor that lists more of them.
struct CIFleetPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    let view: ModuleView?
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    struct Row: Identifiable {
        let id: String
        let lane: SemaforCILane
        var running = 0
        var queued = 0
    }

    var fleet: [Row] {
        guard let host = store.ciSemaforHost else { return [] }
        let live = Dictionary(store.laneBoard.lanes.filter { $0.host == host }.map { ($0.name, $0) },
                              uniquingKeysWith: { first, _ in first })
        return (store.semaforHosts[host]?.lanes ?? []).filter { !$0.isHosted && matches(filter, $0.lane, $0.repo, $0.backend) }
            .map { lane in
                Row(id: "fleet:\(SemaforCI.fleetKey(host: host, lane: lane.lane))", lane: lane,
                    running: live[lane.lane]?.running ?? 0, queued: live[lane.lane]?.queued ?? 0)
            }
            .sorted { ($0.lane.jobs30d ?? 0) > ($1.lane.jobs30d ?? 0) }
    }

    var hosted: [Row] {
        guard let source = SemaforCI.hostedSource(store.semaforStates) else { return [] }
        return (store.semaforHosts[source]?.lanes ?? []).filter { $0.isHosted && matches(filter, $0.lane, $0.repo) }
            .map { Row(id: "fleet:hosted/\($0.lane)", lane: $0) }
            .sorted { ($0.lane.jobs30d ?? 0) > ($1.lane.jobs30d ?? 0) }
    }

    var body: some View {
        let fleet = fleet
        let hosted = hosted
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                CIViewHeader(store: store, view: view, onView: onView,
                             summary: "\(fleet.count) lanes · \(hosted.count) GitHub-hosted")
                columnHeads
                ForEach(fleet) { row($0) }
                if !hosted.isEmpty {
                    Kicker(text: "GitHub-hosted", count: hosted.count)
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                    ForEach(hosted) { row($0) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var columnHeads: some View {
        HStack(spacing: 10) {
            Text("Lane").microLabel()
            Spacer()
            Text("Backend").microLabel().frame(width: 64, alignment: .leading)
            Text("Reserved").microLabel().frame(width: 72, alignment: .trailing)
            Text("Now").microLabel().frame(width: 80, alignment: .trailing)
            Text("30 d").microLabel().frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
    }

    private func row(_ row: Row) -> some View {
        TableRow(id: row.id, selected: selectedID == row.id, action: { onOpen(row.id) }) {
            StatusDot(tone: row.running > 0 ? Theme.ok : row.queued > 0 ? Theme.warn : Theme.idle)
            Text(row.lane.lane).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
            if let repo = row.lane.repo { Text(repoName(repo)).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1) }
            Spacer(minLength: 6)
            Text(row.lane.backend ?? "—").font(Theme.Typo.meta).foregroundStyle(Theme.ink2).frame(width: 64, alignment: .leading)
            Text(row.lane.reservedMib.map { $0 > 0 ? "\($0 / 1024) GiB" : "—" } ?? "—").font(Theme.Typo.figure)
                .foregroundStyle(Theme.ink2).frame(width: 72, alignment: .trailing)
            Text(row.running + row.queued > 0 ? "\(row.running) run · \(row.queued) q" : "—").font(Theme.Typo.figure)
                .foregroundStyle(row.queued > 0 ? Theme.warn : Theme.ink2).frame(width: 80, alignment: .trailing)
            Text(verbatim: row.lane.jobs30d.map { "\($0)" } ?? "—").font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

extension CIFleetPage: ModulePage {
    var listWidth: CGFloat { 620 }
    var minListWidth: CGFloat { 560 }

    var objects: [ModuleObject] {
        (fleet + hosted).map { row in
            var facts = [ModuleObject.Fact(label: "lane", value: row.lane.lane)]
            if let backend = row.lane.backend { facts.append(.init(label: "backend", value: backend)) }
            if let partition = row.lane.partition, !partition.isEmpty { facts.append(.init(label: "partition", value: partition)) }
            if let cap = row.lane.hardCapMib, cap > 0 { facts.append(.init(label: "hard cap", value: "\(cap) MiB")) }
            if let jobs = row.lane.jobs30d { facts.append(.init(label: "jobs · 30 d", value: "\(jobs)")) }
            return ModuleObject(id: row.id, title: row.lane.lane, label: row.lane.repo.map(repoName),
                                status: row.queued > 0 ? Chip("\(row.queued) queued", .warn)
                                    : row.running > 0 ? Chip("\(row.running) running", .ok) : nil,
                                meta: row.lane.backend, symbol: "rectangle.stack", facts: facts)
        }
    }
}
