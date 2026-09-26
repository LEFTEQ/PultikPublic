import SwiftUI

/// The body of the right rail's CI section (spec 2026-09-23, D10 — first an
/// overview-column widget, back in the rail on user direction the same day):
/// a counts line first — lane occupancy from Prometheus, red runs from
/// GitHub, the totals the footer's CI summary used to carry — then one line
/// per busy lane, hover popovers and all. Each count opens `.ci` narrowed to
/// it. The `RailSection` around it owns the heading, the hide rule and the
/// accessory that opens the whole page.
struct CIWidget: View {
    let store: StatusStore
    let onOpen: (String) -> Void

    private var showLanes: Bool {
        store.isSectionVisible("runners") && !store.laneBoard.isEmpty
    }

    private var showRuns: Bool {
        store.isSectionVisible("ci") && !store.repos.isEmpty
    }

    var body: some View {
        let glance = CIGlance(board: store.laneBoard, repos: store.repos)
        VStack(alignment: .leading, spacing: 5) {
            counts(glance)
            if showLanes {
                LaneRail(board: store.laneBoard, onOpen: onOpen)
            }
        }
        .padding(.horizontal, RailRowMetrics.inset)
    }

    /// The section header's count: lane jobs when the fleet reports; GitHub's
    /// running runs otherwise — the one number that still means "something
    /// is building".
    var running: Int {
        let glance = CIGlance(board: store.laneBoard, repos: store.repos)
        return showLanes ? glance.running : glance.runningRuns
    }

    private func counts(_ glance: CIGlance) -> some View {
        HStack(spacing: 5) {
            // Running and queued are lane numbers — the same jobs `.ci running`
            // and `.ci queued` list — so they only show when the lanes report.
            if showLanes {
                count("\(glance.running) running", tone: .primary, filter: "running",
                      help: "Jobs on the lanes, plus the ones seen elsewhere")
                dot
                count("\(glance.queued) queued", tone: glance.queued > 0 ? .orange : .secondary,
                      filter: "queued", help: "Jobs waiting for a runner")
            }
            // No GitHub answer yet is not a green ✓: the failed cell waits for repos.
            if showRuns {
                if showLanes { dot }
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
            Spacer(minLength: 0)
        }
        .font(RailRowMetrics.metaFont)
        .lineLimit(1)
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
