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
            GlanceGrid.tile {
                VStack(alignment: .leading, spacing: 4) {
                    TileHeader(title: "Estate", caption: caption(glance),
                               captionTone: glance.down.isEmpty ? .secondary : .red,
                               action: { onOpen("") },
                               actionHelp: "Open every server and probe — .estate")
                        .padding(.horizontal, RailRowMetrics.inset)
                        .padding(.bottom, 2)
                    if showServers {
                        GlanceHeads(titles: ["cpu", "ram", "disk"])
                        ForEach(store.serverMetrics) { server in
                            MachineVitals(name: server.name, cpuCount: server.cpuCount, cpuPercent: server.cpu,
                                          memoryUsed: server.ramUsedBytes, memoryTotal: server.ramTotalBytes,
                                          diskUsed: server.diskUsedBytes, diskTotal: server.diskTotalBytes)
                        }
                    }
                    if showServices {
                        servicesRow(glance)
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
    }

    private func caption(_ glance: EstateGlance) -> String {
        var parts: [String] = []
        if showServers { parts.append("\(store.serverMetrics.count) servers") }
        if showServices {
            parts.append(glance.down.isEmpty ? "\(glance.up)/\(glance.total) up" : "\(glance.down.count) down")
        }
        return parts.joined(separator: " · ")
    }

    /// The probes rolled up on the grid: up / total under cpu, the median
    /// latency under ram, the unknowns under disk.
    private func servicesRow(_ glance: EstateGlance) -> some View {
        var cells = [GlanceCell("\(glance.up)/\(glance.total)",
                                tone: glance.down.isEmpty ? .green : .red)]
        if let median = glance.medianLatencySeconds {
            cells.append(GlanceCell("p50 \(latencyText(median))", tone: .secondary,
                                    help: "Median probe latency over the services that are up"))
        }
        if glance.unknown > 0 {
            cells.append(GlanceCell("\(glance.unknown) ?", tone: .secondary,
                                    help: "No answer from \(glance.unknown) probe\(glance.unknown == 1 ? "" : "s") — unknown, not down"))
        }
        return Button { onOpen("") } label: {
            GlanceRow(name: "services", cells: cells)
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
