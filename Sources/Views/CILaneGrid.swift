import SwiftUI

struct CILaneGrid: View {
    let lane: CILane

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(lane.name).lineLimit(1)
                Spacer(minLength: 2)
                Text(lane.maxRunners.map { "\(lane.running)/\($0)" } ?? "\(lane.running) · cap —")
                    .foregroundStyle(.secondary)
                    .help(lane.maxRunners == nil ? "Capacity telemetry unavailable" : "Running / configured capacity; shared admission may limit starts")
            }
            .font(.system(size: 9.5, design: .monospaced))
            if lane.maxRunners != nil || !lane.jobs.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 5), count: 12), alignment: .leading, spacing: 5) {
                ForEach(lane.jobs) { job in
                    CIJobCell(job: job, controllerUp: lane.up)
                }
                ForEach(0..<min(96, max(0, (lane.maxRunners ?? lane.running) - lane.running)), id: \.self) { _ in
                    Circle()
                        .fill(lane.up ? Color.secondary.opacity(0.3) : Color.red.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .frame(width: 12, height: 12)
                        .help(lane.up ? "Unoccupied capacity · \(lane.name); shared admission may limit starts" : "Controller unavailable · \(lane.name)")
                        .accessibilityLabel(lane.up ? "Available slot" : "Unavailable slot")
                }
                }
            }
            if !lane.up || lane.queued > 0 {
                Text(!lane.up ? "controller down" : "\(lane.queued) queued")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(lane.up ? Color.secondary : .red)
            }
        }
        .padding(.vertical, 4)
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
