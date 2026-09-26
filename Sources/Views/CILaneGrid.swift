import SwiftUI

/// One busy lane on one line (2026-09-23, bounded for the right rail): the
/// name, the running jobs as squares — hover one for its runner and run
/// link — `cellLimit` cells at most, then the queue or a dead controller and
/// the running count. Lanes have no capacity of their own since 2026-09-26:
/// free room is the shared pool's, shown once above the lanes (`PoolRow`).
/// A lane with more jobs than cells ends in "+N", which opens `.ci <lane>`
/// where every job is listed.
struct CILaneGrid: View {
    let lane: CILane
    let onOpen: (String) -> Void

    /// Sized to the rail: 88pt name + six 12pt cells + the trailing numbers
    /// fill the 244pt a `RailSection` row gets.
    static let cellLimit = 6

    private var laneHelp: String {
        let rank = [lane.tier.map { "tier \($0)" }, lane.kind].compactMap { $0 }.joined(separator: " · ")
        return "\(lane.running) running on \(lane.name)" + (rank.isEmpty ? "" : " · \(rank)") + "; capacity is the shared pool"
    }

    var body: some View {
        let overflow = lane.jobs.count > Self.cellLimit
        let jobs = overflow ? Array(lane.jobs.prefix(Self.cellLimit - 1)) : lane.jobs
        HStack(spacing: 6) {
            Text(lane.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 88, alignment: .leading)
                .help(lane.name)
            HStack(spacing: 2) {
                ForEach(jobs) { job in
                    CIJobCell(job: job, controllerUp: lane.up)
                }
                if overflow {
                    Button { onOpen(lane.name) } label: {
                        Text("+\(lane.jobs.count - jobs.count)")
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(lane.jobs.count - jobs.count) more jobs on \(lane.name)")
                    .help("Every job on \(lane.name) — .ci \(lane.name)")
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if !lane.up {
                    Text("down")
                        .foregroundStyle(.red)
                        .help("Controller down · \(lane.name)")
                        .accessibilityLabel("Controller down")
                } else if lane.queued > 0 {
                    Text("q\(lane.queued)")
                        .foregroundStyle(.orange)
                        .help("\(lane.queued) queued on \(lane.name)")
                        .accessibilityLabel("\(lane.queued) queued")
                }
                Text("\(lane.running)")
                    .foregroundStyle(.secondary)
                    .help(laneHelp)
            }
            // The counts are what the row is for — the name gives way first.
            .fixedSize()
        }
        .font(.system(size: 9.5, design: .monospaced))
        .padding(.vertical, 1)
    }
}

/// The shared Docker pool above the lanes (Semafor's admission board): slots
/// and reserved memory against the budget, then the queue's head — the lane
/// that places next — with its repo tier and kind. Hidden when Semafor did
/// not answer; dimmed when its numbers are older than `CIPoolGlance.staleAfter`.
struct PoolRow: View {
    let pool: CIPool

    var body: some View {
        let glance = CIPoolGlance(pool: pool)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("pool").foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                Text("\(glance.slots) · \(glance.memory)")
                    .foregroundStyle(glance.full ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if glance.stale {
                    Text("stale").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .help(glance.stale
                ? "Shared CI pool — Semafor's newest controller reading is over \(Int(CIPoolGlance.staleAfter / 60)) min old"
                : "Shared CI pool: live jobs / \(pool.slotsMax) slots and reserved / budgeted memory; no lane has a ceiling of its own")
            if let head = glance.head {
                HStack(spacing: 6) {
                    Text("next").foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)
                    Text(head)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .help("Head of the priority queue (repo tier, then kind ci · build · e2e, then age): the waiter that places next")
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .opacity(glance.stale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct CIJobCell: View {
    let job: CIJob
    let controllerUp: Bool
    @State private var hovering = false
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(controllerUp ? Color.green.opacity(0.85) : Color.orange)
                .frame(width: 10, height: 10)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else { return }
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            if hovering { presented = true }
        }
        .popover(isPresented: $presented, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.repo).font(.system(size: 12, weight: .semibold))
                Text(job.workflow).font(.system(size: 11))
                Text(job.jobName).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Divider()
                if let since = job.since {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Elapsed \(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.time(pattern: .hourMinuteSecond)))")
                    }
                } else { Text("Elapsed unavailable") }
                Text(job.cpuPercent.map { String(format: "Runner CPU %.0f%%", $0) } ?? "Runner CPU unavailable")
                    .help("100% is one CPU core; runner container only")
                Text(job.memoryBytes.map { "Runner RAM \(ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max - 1024))), countStyle: .memory))" } ?? "Runner RAM unavailable")
                if let url = job.runURL {
                    Link(destination: url) {
                        Label("Open GitHub Action", systemImage: "arrow.up.right.square")
                    }
                    Text(url.absoluteString)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .textSelection(.enabled).lineLimit(3)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(12)
            .frame(width: 310, alignment: .leading)
        }
        .accessibilityLabel("\(job.repo), \(job.workflow), \(job.jobName), running")
        .accessibilityHint("Show job details")
    }
}
