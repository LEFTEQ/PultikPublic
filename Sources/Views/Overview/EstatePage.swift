import SwiftUI

/// `.estate` (spec 2026-09-23, D11): the servers at full width — cpu, ram and
/// disk as gauges with their absolute numbers — and every service probe,
/// grouped by the box it runs on through the right rail's `ServiceRail`.
/// The filter matches a server, a service or a service's host.
struct EstatePage: View {
    let store: StatusStore
    let filter: String
    let onBack: () -> Void

    private var text: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ fields: String?...) -> Bool {
        text.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }

    private var servers: [ServerMetrics] {
        store.serverMetrics.filter { matches($0.name, $0.instance) }
    }

    private var services: [ServiceStatus] {
        store.serviceStatuses.filter { matches($0.name, $0.host, $0.probe) }
    }

    var body: some View {
        let glance = EstateGlance(services: store.serviceStatuses)
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header(glance)
                Kicker(text: "Servers", count: servers.count)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                if servers.isEmpty {
                    RailNote(store.serverMetrics.isEmpty ? "No server metrics — off the mesh?" : "No match")
                }
                ForEach(servers) { server in
                    EstateServerRow(server: server)
                }
                Kicker(text: "Services", count: services.count,
                       tone: glance.down.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                if services.isEmpty {
                    RailNote(store.serviceStatuses.isEmpty ? "No probes reported" : "No match")
                } else {
                    ServiceRail(statuses: services, hostOrder: store.serverNames)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func header(_ glance: EstateGlance) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Estate")
                .font(.system(size: 14, weight: .semibold))
            Text(summary(glance))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(glance.down.isEmpty ? Color.secondary : .red)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func summary(_ glance: EstateGlance) -> String {
        var parts = ["\(store.serverMetrics.count) servers", "services \(glance.up)/\(glance.total)"]
        if !glance.down.isEmpty { parts.append("\(glance.down.count) down") }
        if let median = glance.medianLatencySeconds { parts.append("p50 \(latencyText(median))") }
        return parts.joined(separator: " · ")
    }
}

/// One box across the page: name and cores, then cpu, ram and disk as
/// gauges tinted by the shared `LoadTier` scale, absolute numbers beside.
private struct EstateServerRow: View {
    let server: ServerMetrics

    private var memoryPercent: Double? {
        if let used = server.ramUsedBytes, let total = server.ramTotalBytes, total > 0 {
            return used / total * 100
        }
        return server.ram
    }

    private var diskPercent: Double? {
        if let used = server.diskUsedBytes, let total = server.diskTotalBytes, total > 0 {
            return used / total * 100
        }
        return server.disk
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                Text(server.cpuCount.map { "\($0) cores" } ?? server.instance)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 110, alignment: .leading)
            EstateGauge(label: "CPU", percent: server.cpu,
                        text: server.cpu.map { "\(Int($0.rounded()))%" } ?? "—")
            EstateGauge(label: "RAM", percent: memoryPercent,
                        text: size(server.ramUsedBytes, server.ramTotalBytes) ?? percentText(memoryPercent))
            EstateGauge(label: "Disk", percent: diskPercent,
                        text: size(server.diskUsedBytes, server.diskTotalBytes) ?? percentText(diskPercent))
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, 6)
    }

    private func size(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return formatSize(used: max(0, used), total: total)
    }

    private func percentText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}

private struct EstateGauge: View {
    let label: String
    let percent: Double?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
            Capsule()
                .fill(.white.opacity(0.09))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(percent.map(percentTone) ?? .secondary)
                            .frame(width: proxy.size.width * min(1, max(0, (percent ?? 0) / 100)))
                    }
                }
            Text(text)
                .font(RailRowMetrics.metaFont)
                .monospacedDigit()
                .foregroundStyle(percent.map(percentTone) ?? .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
