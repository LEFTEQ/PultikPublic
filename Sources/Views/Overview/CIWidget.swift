import SwiftUI

/// The CI widget of the overview column (spec 2026-09-27, superseding the
/// right-rail section of 2026-09-23 D10): the heading carries running (the
/// kicker count), queued and failed — each opens `.ci` narrowed to it — and
/// a link to Semafor's web app. Under it the pools as gauges (Docker slots,
/// its memory budget, the KVM bastions), then Semafor's day: queue wait and
/// jobs against yesterday with the hours so far. One orange line appears
/// only while waiting lanes are being refused. Per-lane rows live on `.ci`.
struct CIWidget: View {
    let store: StatusStore
    let onOpen: (String) -> Void

    private var showLanes: Bool {
        Self.lanesReport(store)
    }

    /// The fleet reports: its lane jobs are the "running" count here and on
    /// Home's CI/CD tile (`CIGlance.runningCount`).
    static func lanesReport(_ store: StatusStore) -> Bool {
        store.isSectionVisible("runners") && !store.laneBoard.isEmpty
    }

    private var showRuns: Bool {
        store.isSectionVisible("ci") && !store.repos.isEmpty
    }

    var body: some View {
        let glance = CIGlance(board: store.laneBoard, repos: store.repos)
        GlanceGrid.tile {
            VStack(alignment: .leading, spacing: 4) {
                header(glance)
                    .padding(.bottom, 2)
                if showLanes, let pool = store.laneBoard.pool {
                    gauges(pool)
                    if let throughput = store.ciThroughput {
                        dayRows(throughput)
                    }
                    if glance.queued > 0, !pool.refusals.isEmpty {
                        refusalLine(pool.refusals)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen("") }
    }

    /// The kicker's count: lane jobs when the fleet reports; GitHub's
    /// running runs otherwise — the one number that still means "something
    /// is building".
    private func running(_ glance: CIGlance) -> Int {
        glance.runningCount(lanesReport: showLanes)
    }

    private func header(_ glance: CIGlance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Kicker(text: "CI", count: running(glance),
                   action: { onOpen("") },
                   actionHelp: "Open every CI job — .ci")
            counts(glance)
            Button {
                NSWorkspace.shared.open(SemaforClient.base)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Semafor — \(SemaforClient.base.host() ?? "semafor")")
            .accessibilityLabel("Open Semafor on the web")
        }
        .padding(.horizontal, RailRowMetrics.inset)
    }

    /// Docker slots and memory are the pool every CI lane shares; the
    /// bastions are the deploy lanes' KVM guests. Dimmed when Semafor's
    /// newest controller reading is stale.
    private func gauges(_ pool: CIPool) -> some View {
        let poolGlance = CIPoolGlance(pool: pool)
        var cells = [
            GlanceCell("\(pool.slotsUsed)/\(pool.slotsMax)", fraction: Self.fraction(pool.slotsUsed, pool.slotsMax)),
            GlanceCell("\(Self.gib(pool.reservedMiB))/\(Self.gib(pool.budgetMiB))G",
                       fraction: Self.fraction(pool.reservedMiB, pool.budgetMiB),
                       tone: poolGlance.full ? .orange : nil),
        ]
        if let bastion = pool.bastion {
            cells.append(GlanceCell("\(Self.gib(bastion.reservedMiB))/\(Self.gib(bastion.budgetMiB))G",
                                    fraction: Self.fraction(bastion.reservedMiB, bastion.budgetMiB)))
        }
        return VStack(alignment: .leading, spacing: 2) {
            GlanceHeads(titles: pool.bastion == nil ? ["slots", "pool"] : ["slots", "pool", "bastions"])
            GlanceRow(name: "pools", cells: cells)
        }
        .opacity(poolGlance.stale ? 0.5 : 1)
        .help(poolHelp(pool, glance: poolGlance))
    }

    private func poolHelp(_ pool: CIPool, glance: CIPoolGlance) -> String {
        var lines = ["Docker pool: \(glance.slots), \(glance.memory) reserved"]
        if let head = glance.head { lines.append("next: \(head)") }
        if let bastion = pool.bastion {
            lines.append("Bastions: \(bastion.slotsUsed)/\(bastion.slotsMax) guests, "
                + "\(Self.gib(bastion.reservedMiB))/\(Self.gib(bastion.budgetMiB)) GiB")
        }
        if glance.stale { lines.append("stale — Semafor's newest reading is over 3 minutes old") }
        return lines.joined(separator: "\n")
    }

    /// Semafor's day on the grid: the queue wait (p50 · p95 · share over
    /// 5 m) and today's jobs against yesterday, the hours so far beneath.
    private func dayRows(_ throughput: CIThroughput) -> some View {
        let day = CIThroughputGlance(throughput)
        var wait: [GlanceCell] = []
        if let queue = throughput.queue {
            wait = [GlanceCell("p50 \(CIThroughputGlance.duration(queue.p50))", tone: .secondary),
                    GlanceCell("p95 \(CIThroughputGlance.duration(queue.p95))",
                               tone: day.waitSlow ? .orange : .secondary)]
            if let share = throughput.over300sShare {
                wait.append(GlanceCell("\(CIThroughputGlance.percent(share)) > 5m", tone: .secondary))
            }
        } else {
            wait = [GlanceCell("none finished yet", tone: .secondary)]
        }
        var today = [GlanceCell("\(throughput.jobs) jobs")]
        if let delta = day.delta {
            today.append(GlanceCell(delta, tone: .secondary, help: "Against yesterday up to the same time"))
        }
        return VStack(alignment: .leading, spacing: 2) {
            GlanceRow(name: "wait", cells: wait,
                      help: "Today's queue wait — p50, p95 and the share over 5 minutes (Semafor); orange past a 2 min p95")
            GlanceRow(name: "today", cells: today)
            HourBars(values: day.hours, height: 14, barWidth: 4)
                .padding(.leading, RailRowMetrics.inset + GlanceGrid.name + GlanceGrid.spacing)
                .help("Jobs per hour since midnight")
        }
    }

    /// Present only while jobs wait and lanes were refused: the two most
    /// frequent reasons, in Semafor's own words.
    private func refusalLine(_ refusals: [CIRefusal]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text("blocked · " + refusals.prefix(2)
                .map { "\(CIRefusalReason.label($0.reason)) ×\($0.count)" }
                .joined(separator: " · "))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .padding(.horizontal, RailRowMetrics.inset - 2)
        .help("Why waiting lanes were refused a slot over the last 15 minutes (Semafor admission)")
    }

    private static func fraction(_ used: Int, _ total: Int) -> Double? {
        total > 0 ? Double(used) / Double(total) : nil
    }

    private static func gib(_ mib: Int) -> Int {
        Int((Double(mib) / 1024).rounded())
    }

    private func counts(_ glance: CIGlance) -> some View {
        HStack(spacing: 5) {
            // Queued is a lane number — the same jobs `.ci queued` lists — so
            // it only shows when the lanes report, and only when non-zero.
            if showLanes, glance.queued > 0 {
                count("\(glance.queued) queued", tone: .orange,
                      filter: "queued", help: "Jobs waiting for a runner")
            }
            // No GitHub answer yet is not a green ✓: the failed cell waits for repos.
            if showRuns {
                if showLanes, glance.queued > 0 { dot }
                if glance.githubUnreachable {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("GitHub unreachable — failed runs unknown")
                } else if glance.failedRuns > 0 {
                    count("✕ \(glance.failedRuns) failed", tone: .red, filter: "failed", help: breakdown)
                } else {
                    count("✓", tone: .green, filter: "failed", help: breakdown)
                }
            }
        }
        .font(RailRowMetrics.metaFont)
        .lineLimit(1)
        .fixedSize()
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func count(_ text: String, tone: Color, filter: String, help: String) -> some View {
        Button { onOpen(filter) } label: {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(tone)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One line per repo — the per-repo detail the footer's hover carried.
    private var breakdown: String {
        store.repos.map { repo in
            let name = repo.slug.split(separator: "/").last.map(String.init) ?? repo.slug
            if let error = repo.error { return "\(name) — \(error)" }
            let failed = repo.runs.filter(\.failed).count + repo.deploys.filter(\.failed).count
            let running = repo.runs.filter(\.isRunning).count + repo.deploys.filter(\.isRunning).count
            let state = failed > 0 ? "✕\(failed)" : running > 0 ? "●\(running)" : "✓"
            return "\(name) \(state)"
        }.joined(separator: "\n")
    }
}
