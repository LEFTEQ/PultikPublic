import SwiftUI

/// `.ci` (spec 2026-09-23, D10): everything the right rail's CI section summarises —
/// running jobs with their runner cost, queues per lane, and GitHub's failed
/// runs. `running` / `queued` / `failed` as the filter narrow to that group;
/// any other text matches repo, workflow, job or lane.
struct CIPage: View {
    let store: StatusStore
    let filter: String
    let onBack: () -> Void

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
        ScrollView {
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
                                    CIJobPageRow(job: job, now: context.date)
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
                                action: {})
                    }
                    if store.laneBoard.elsewhereQueued > 0 && text.isEmpty {
                        RailRow(dot: .hollow, title: "elsewhere",
                                meta: "\(store.laneBoard.elsewhereQueued) queued",
                                help: "GitHub-hosted or unmapped lanes", action: {})
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
                                action: { if let url = run.url { NSWorkspace.shared.open(url) } })
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func header(_ glance: CIGlance) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
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
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = job.runURL { NSWorkspace.shared.open(url) }
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
            .background(hovering ? RailRowMetrics.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
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

    private var cost: String {
        let cpu = job.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let memory = job.memoryBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max - 1024))), countStyle: .memory)
        } ?? "—"
        return "\(cpu) · \(memory)"
    }
}
