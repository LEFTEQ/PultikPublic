import SwiftUI

/// The Estate widget of the overview column (spec 2026-09-23, D11): one
/// `MachineVitals` line per server — the lines the vitals dock's estate tier
/// drew — then the services the right rail listed, rolled up to one line.
/// A down service never hides inside that count: it gets its own red row.
/// Off-mesh there are no metrics and no probes, and the widget hides.
struct EstateWidget: View {
    let store: StatusStore
    let onOpen: (String) -> Void

    private var showServers: Bool {
        store.isSectionVisible("servers") && !store.serverMetrics.isEmpty
    }

    private var showServices: Bool {
        store.isSectionVisible("services") && !store.serviceStatuses.isEmpty
    }

    var body: some View {
        if showServers || showServices {
            let glance = EstateGlance(services: store.serviceStatuses)
            VStack(alignment: .leading, spacing: 3) {
                Kicker(text: "Estate", action: { onOpen("") },
                       actionHelp: "Open every server and probe — .estate")
                    .padding(.horizontal, RailRowMetrics.inset)
                    .padding(.bottom, 1)
                if showServers {
                    ForEach(store.serverMetrics) { server in
                        MachineVitals(name: server.name, cpuCount: server.cpuCount, cpuPercent: server.cpu,
                                      memoryUsed: server.ramUsedBytes, memoryTotal: server.ramTotalBytes,
                                      diskUsed: server.diskUsedBytes, diskTotal: server.diskTotalBytes)
                            .padding(.horizontal, RailRowMetrics.inset)
                            .padding(.vertical, 3)
                    }
                }
                if showServices {
                    servicesLine(glance)
                    ForEach(glance.down) { service in
                        RailRow(dot: .filled(.red), title: service.name,
                                meta: service.host.map { "down · \($0)" } ?? "down",
                                help: service.probe,
                                action: { onOpen(service.name) })
                    }
                }
            }
        }
    }

    private func servicesLine(_ glance: EstateGlance) -> some View {
        Button { onOpen("") } label: {
            HStack(spacing: RailRowMetrics.dotGap) {
                Circle()
                    .fill(glance.down.isEmpty ? (glance.unknown == 0 ? Color.green : Color.secondary.opacity(0.5)) : .red)
                    .frame(width: RailRowMetrics.dotSize, height: RailRowMetrics.dotSize)
                Text("services \(glance.up)/\(glance.total)")
                    .foregroundStyle(.secondary)
                if glance.unknown > 0 {
                    Text("· \(glance.unknown) ?")
                        .foregroundStyle(.tertiary)
                        .help("No answer from \(glance.unknown) probe\(glance.unknown == 1 ? "" : "s") — unknown, not down")
                }
                Spacer(minLength: 4)
                if let median = glance.medianLatencySeconds {
                    Text("p50 \(latencyText(median))")
                        .foregroundStyle(.tertiary)
                        .help("Median probe latency over the services that are up")
                }
            }
            .font(RailRowMetrics.metaFont)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Every service probe — .estate")
    }
}

/// Same scale as `ServiceStatus.latencyLabel`, which reads one probe.
func latencyText(_ seconds: Double) -> String {
    seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
}
