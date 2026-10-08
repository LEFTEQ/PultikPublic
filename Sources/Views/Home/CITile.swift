import SwiftUI

/// Home's CI/CD tile (panel Home D7, 2026-10-07): today's jobs, the queue's
/// p95 wait and GitHub's failed runs as heroes over today's hour bars, then
/// what is running and which repos failed. The pools and refusals stay on the
/// CI glance and `.ci`. It formats `ciThroughput`, `laneBoard` and the repos'
/// workflow runs — never a poll of its own — and hides when neither Semafor
/// nor GitHub has anything true to say.
struct CITile: View {
    let store: StatusStore
    /// `.ci` narrowed by the filter ("" for all, "failed").
    let onOpen: (String) -> Void

    static func isShown(store: StatusStore) -> Bool {
        let lanes = store.isSectionVisible("runners") && (!store.laneBoard.isEmpty || store.ciThroughput != nil)
        let runs = store.isSectionVisible("ci") && !store.repos.isEmpty
            && !store.repos.allSatisfy { $0.error != nil }
        return lanes || runs
    }

    private static let sky = Color(red: 0.37, green: 0.78, blue: 0.98)

    var body: some View {
        let glance = CIGlance(board: store.laneBoard, repos: store.repos)
        VStack(alignment: .leading, spacing: 12) {
            TileHeader(title: "CI/CD", caption: caption(glance),
                       action: { onOpen("") }, actionHelp: "Every CI job and run — .ci")
            heroes(glance)
            if let throughput = store.ciThroughput {
                let day = CIThroughputGlance(throughput)
                VStack(alignment: .leading, spacing: 3) {
                    HourBars(values: day.hours, height: 36, barWidth: 8, tint: Self.sky.opacity(0.85))
                    Text("00 → now · \(day.jobs)")
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                }
            }
            if !runningRuns.isEmpty {
                section("Running") {
                    ForEach(runningRuns.prefix(4), id: \.run.id) { item in
                        runRow(item.repo, item.run, tone: .blue)
                    }
                }
            }
            if !failedRepos.isEmpty {
                section("Failed by repo") {
                    ForEach(failedRepos, id: \.repo) { item in
                        failedRow(item.repo, count: item.count, latest: item.latest)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }

    private func caption(_ glance: CIGlance) -> String {
        var parts = ["\(glance.running + glance.runningRuns) running"]
        if glance.queued > 0 { parts.append("\(glance.queued) queued") }
        parts.append(glance.failedRuns > 0 ? "\(glance.failedRuns) failed" : "✓")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func heroes(_ glance: CIGlance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if let throughput = store.ciThroughput {
                let day = CIThroughputGlance(throughput)
                hero("\(throughput.jobs)", unit: "jobs today", detail: day.delta,
                     detailTone: (day.delta?.hasPrefix("+") ?? false) ? .green : .secondary)
                if let queue = throughput.queue {
                    hero(CIThroughputGlance.duration(queue.p95), unit: "wait p95",
                         tone: day.waitSlow ? .orange : .primary)
                }
            } else {
                hero("\(glance.running + glance.runningRuns)", unit: "running")
            }
            hero("\(glance.failedRuns)", unit: "failed", tone: glance.failedRuns > 0 ? .red : .secondary)
        }
    }

    private func hero(_ value: String, unit: String, tone: Color = .primary,
                      detail: String? = nil, detailTone: Color = .secondary) -> some View
    {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(TileMetrics.heroFont)
                .foregroundStyle(tone)
            HStack(spacing: 4) {
                Text(unit)
                if let detail {
                    Text(detail).foregroundStyle(detailTone)
                }
            }
            .font(TileMetrics.heroUnitFont)
            .foregroundStyle(.secondary)
        }
        // A hero never wraps: on a narrow tile it shrinks instead.
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            content()
        }
    }

    // MARK: - Runs

    private struct RepoRun {
        let repo: String
        let run: WorkflowRun
    }

    private var runningRuns: [RepoRun] {
        guard store.isSectionVisible("ci") else { return [] }
        return store.repos
            .flatMap { repo in repo.runs.filter(\.isRunning).map { RepoRun(repo: repo.slug, run: $0) } }
            .sorted { $0.run.createdAt < $1.run.createdAt }
    }

    /// Repos with failed runs in the shown window, most failures first.
    private var failedRepos: [(repo: String, count: Int, latest: WorkflowRun)] {
        guard store.isSectionVisible("ci") else { return [] }
        return store.repos
            .compactMap { repo -> (String, Int, WorkflowRun)? in
                let failed = repo.runs.filter(\.failed).sorted { $0.createdAt > $1.createdAt }
                guard let latest = failed.first else { return nil }
                return (repo.slug, failed.count, latest)
            }
            .sorted { $0.1 > $1.1 }
            .map { (repo: $0.0, count: $0.1, latest: $0.2) }
    }

    private static func name(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    private func runRow(_ repo: String, _ run: WorkflowRun, tone: Color) -> some View {
        RailRow(dot: .filled(tone),
                title: "\(Self.name(repo)) · \(run.name ?? "run")",
                meta: [run.headBranch, run.createdAt.shortAge].compactMap { $0 }.joined(separator: " · "),
                help: run.htmlUrl,
                action: { if let url = URL(string: run.htmlUrl) { NSWorkspace.shared.open(url) } })
    }

    private func failedRow(_ repo: String, count: Int, latest: WorkflowRun) -> some View {
        RailRow(dot: .filled(.red),
                title: "\(Self.name(repo)) · \(latest.name ?? "run")",
                meta: "\(count) failed · \(latest.createdAt.shortAge)",
                help: "Open the failed runs — .ci failed",
                action: { onOpen("failed") })
    }
}
