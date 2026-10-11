import SwiftUI

/// The Estate module's list (spec 2026-09-23 D11, WP8): the servers at full
/// width — cpu, ram and disk as meters with their absolute numbers — then
/// the estate's firing alerts and the expiry radar's renewals, the objects
/// Now's estate rows open, then every service probe grouped by the box it
/// runs on through `ServiceRail`. A click selects and opens the detail. The
/// filter matches a server, an alert, a renewal, a service or its host.
struct EstatePage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// Firing rules the prod board does not claim (`firingGlance`'s rule),
    /// heartbeat and pending ones already gone.
    var firing: [FiringAlert] = []
    var renewals: [NowInputs.Expiry] = []
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }

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

    /// Critical first, then warning, then the rest; newest first within each.
    private var alerts: [FiringAlert] {
        firing.filter { matches($0.name, $0.summary, $0.context) }
            .sorted { a, b in
                let (ra, rb) = (Self.rank(a), Self.rank(b))
                if ra != rb { return ra < rb }
                return (a.activeAt ?? .distantPast, b.id) > (b.activeAt ?? .distantPast, a.id)
            }
    }

    private static func rank(_ alert: FiringAlert) -> Int {
        alert.severity == "critical" ? 0 : alert.severity == "warning" ? 1 : 2
    }

    private var watched: [NowInputs.Expiry] {
        renewals.filter { matches($0.label) }
    }

    var body: some View {
        let glance = EstateGlance(services: store.serviceStatuses)
        let now = Date()
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header(glance)
                Kicker(text: "Servers", count: servers.count)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                if servers.isEmpty {
                    RailNote(store.serverMetrics.isEmpty ? "No server metrics — off the mesh?" : "No match")
                }
                ForEach(servers) { server in
                    let id = Self.objectID(server)
                    EstateServerRow(server: server, selected: selectedID == id, onOpen: { onOpen(id) })
                        .id(id)
                }
                firingSection(now: now)
                renewalsSection(now: now)
                Kicker(text: "Services", count: services.count,
                       tone: glance.down.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                if services.isEmpty {
                    RailNote(store.serviceStatuses.isEmpty ? "No probes reported" : "No match")
                } else {
                    ServiceRail(statuses: services, hostOrder: store.serverNames, selectedID: selectedID,
                                onOpen: onOpen)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func firingSection(now: Date) -> some View {
        let alerts = alerts
        if !alerts.isEmpty {
            Kicker(text: "Firing", count: alerts.count,
                   tone: alerts.contains { $0.severity == "critical" } ? .red : .orange)
                .padding(.horizontal, 8)
                .padding(.top, 12)
            ForEach(alerts) { alert in
                let id = Self.objectID(alert)
                ListRow(title: alert.summary ?? alert.name, id: alert.name,
                        meta: Text(verbatim: Self.alertMeta(alert, now: now)),
                        selected: selectedID == id, action: { onOpen(id) }) {
                    StatusDot(tone: Self.tone(alert))
                }
                .id(id)
            }
        }
    }

    @ViewBuilder
    private func renewalsSection(now: Date) -> some View {
        let watched = watched
        if !watched.isEmpty {
            Kicker(text: "Renewals", count: watched.count)
                .padding(.horizontal, 8)
                .padding(.top, 12)
            ForEach(watched, id: \.id) { item in
                let tone: Color = Self.renewalState(item, now: now).tone
                let style: StatusDot.Style = item.expiry == nil ? .ring : .solid
                ListRow(title: item.label, id: item.id.hasPrefix("tls:") ? "TLS" : nil,
                        meta: Text(verbatim: Self.renewalMeta(item, now: now)),
                        selected: selectedID == item.id, action: { onOpen(item.id) }) {
                    StatusDot(tone: tone, style: style)
                }
                .id(item.id)
            }
        }
    }

    private func header(_ glance: EstateGlance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Estate")
                .font(Theme.Typo.title)
            Text(summary(glance))
                .font(Theme.Typo.figure)
                .foregroundStyle(glance.down.isEmpty ? Theme.ink2 : Theme.danger)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func summary(_ glance: EstateGlance) -> String {
        var parts = ["\(store.serverMetrics.count) servers", "services \(glance.up)/\(glance.total)"]
        if !glance.down.isEmpty { parts.append("\(glance.down.count) down") }
        if let median = glance.medianLatencySeconds { parts.append("p50 \(Self.latencyText(median))") }
        return parts.joined(separator: " · ")
    }

    /// Same scale as `ServiceStatus.latencyLabel`, which reads one probe.
    static func latencyText(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }

    static func tone(_ alert: FiringAlert) -> Color {
        alert.severity == "critical" ? Theme.danger : alert.severity == "warning" ? Theme.warn : Theme.ink3
    }

    /// `app · environment · 3h` — how long the rule has been firing.
    static func alertMeta(_ alert: FiringAlert, now: Date) -> String {
        [alert.context, alert.activeAt.map { PultikFormat.age(now.timeIntervalSince($0)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Now's expiry rule: critical once past, a warning inside three days,
    /// due once the lead window opens; quiet before it.
    static func renewalState(_ item: NowInputs.Expiry, now: Date) -> (text: String, variant: Chip.Variant, tone: Color) {
        guard let expiry = item.expiry else { return ("no date yet", .dashed, Theme.ink3) }
        let left = expiry.timeIntervalSince(now)
        if left <= 0 { return ("expired", .danger, Theme.danger) }
        if left <= 3 * 86400 { return ("expires in \(PultikFormat.duration(left))", .warn, Theme.warn) }
        if left <= item.lead { return ("renew", .warn, Theme.warn) }
        return ("in \(PultikFormat.duration(left))", .ok, Theme.ok)
    }

    /// `Oct 21 · in 10d`, `expired`, or `no date yet`.
    static func renewalMeta(_ item: NowInputs.Expiry, now: Date) -> String {
        guard let expiry = item.expiry else { return "no date yet — the probe has not answered" }
        let state = renewalState(item, now: now).text
        return "\(PultikFormat.date(expiry, now: now)) · \(state)"
    }
}

/// The servers, the firing alerts, the renewals, then every service probe in
/// `ServiceRail`'s host order, as drawn. A firing alert is its `FiringAlert`
/// id and a renewal its radar item id: the ids Now's estate rows target.
extension EstatePage: ModulePage {
    static func objectID(_ server: ServerMetrics) -> String { "server:\(server.name)" }
    static func objectID(_ alert: FiringAlert) -> String { alert.id }

    var objects: [ModuleObject] {
        let now = Date()
        let boxes = servers.map { server in
            var facts = [ModuleObject.Fact(label: "instance", value: server.instance)]
            if let cores = server.cpuCount { facts.append(.init(label: "cores", value: "\(cores)")) }
            if let cpu = server.cpu { facts.append(.init(label: "cpu", value: "\(Int(cpu.rounded()))%")) }
            if let used = server.ramUsedBytes, let total = server.ramTotalBytes, total > 0 {
                facts.append(.init(label: "ram", value: PultikFormat.sizeRatio(used: used, total: total)))
            }
            if let used = server.diskUsedBytes, let total = server.diskTotalBytes, total > 0 {
                facts.append(.init(label: "disk", value: PultikFormat.sizeRatio(used: used, total: total)))
            }
            return ModuleObject(id: Self.objectID(server), title: server.name, label: server.instance,
                                meta: server.cpuCount.map { "\($0) cores" }, symbol: "server.rack",
                                project: server.name, facts: facts)
        }
        let probes = ServiceRail.ordered(services, hostOrder: store.serverNames).map { service in
            var facts = [ModuleObject.Fact(label: "probe", value: service.probe)]
            if let host = service.host { facts.append(.init(label: "host", value: host)) }
            facts.append(.init(label: "latency", value: service.latencyLabel))
            let status = switch service.up {
            case true?: Chip("up", .ok)
            case false?: Chip("down", .danger)
            case nil: Chip("unknown", .neutral)
            }
            return ModuleObject(id: ServiceRail.objectID(service), title: service.name, status: status,
                                meta: service.host, symbol: "dot.radiowaves.up.forward",
                                url: service.probe.hasPrefix("https") ? URL(string: service.probe) : nil,
                                facts: facts)
        }
        let fires = alerts.map { alert in
            let status = switch alert.severity {
            case "critical": Chip("critical", .danger)
            case "warning": Chip("warning", .warn)
            default: Chip(alert.severity ?? "firing", .neutral)
            }
            var facts = [ModuleObject.Fact(label: "rule", value: alert.name),
                         .init(label: "source", value: alert.source.rawValue)]
            if let since = alert.activeAt { facts.append(.init(label: "firing", value: PultikFormat.ago(since, now: now))) }
            facts += alert.labels.filter { !["alertname", "severity"].contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { ModuleObject.Fact(label: $0.key, value: $0.value) }
            // Prometheus rules open their alerts page narrowed to the rule;
            // the Loki ruler has no UI of its own.
            let url = alert.source == .prometheus ? MetricsClient.shared.alertsPage(for: alert.name) : nil
            return ModuleObject(id: Self.objectID(alert), title: alert.summary ?? alert.name, label: alert.name,
                                status: status, meta: Self.alertMeta(alert, now: now), symbol: "flame",
                                url: url, facts: facts)
        }
        let renewing = watched.map { item in
            let state = Self.renewalState(item, now: now)
            var facts = [ModuleObject.Fact(label: "kind", value: item.id.hasPrefix("tls:") ? "TLS certificate" : "manual")]
            if let expiry = item.expiry {
                facts.append(.init(label: "expires", value: expiry.formatted(date: .abbreviated, time: .shortened)))
            }
            facts.append(.init(label: "lead", value: PultikFormat.duration(item.lead)))
            return ModuleObject(id: item.id, title: item.label, status: Chip(state.text, state.variant),
                                meta: Self.renewalMeta(item, now: now), symbol: "calendar.badge.clock",
                                facts: facts)
        }
        return boxes + fires + renewing + probes
    }

    /// A firing alert's description; a server's three meters.
    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let alert = firing.first(where: { Self.objectID($0) == object.id }) {
            if let description = alert.description, !description.isEmpty {
                Tile(kicker: "Description") {
                    Text(description).font(Theme.Typo.body).foregroundStyle(Theme.ink2).textSelection(.enabled)
                }
            }
        } else if let server = store.serverMetrics.first(where: { Self.objectID($0) == object.id }) {
            Tile(kicker: "Load") {
                EstateMeters(server: server)
            }
        }
    }
}

/// One box across the page: name and cores, then cpu, ram and disk as
/// meters with their absolute numbers. A click selects it.
private struct EstateServerRow: View {
    let server: ServerMetrics
    var selected = false
    let onOpen: () -> Void
    @State private var hovering = false

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
            EstateMeters(server: server)
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background { RowBackground(selected: selected, hovering: hovering) }
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityAction(named: "Open", onOpen)
    }
}

/// A box's cpu, ram and disk as Kit meters, sizes in `PultikFormat`.
private struct EstateMeters: View {
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
            meter("CPU", percent: server.cpu, text: server.cpu.map { PultikFormat.percent($0 / 100) } ?? "—")
            meter("RAM", percent: memoryPercent,
                  text: size(server.ramUsedBytes, server.ramTotalBytes) ?? percentText(memoryPercent))
            meter("Disk", percent: diskPercent,
                  text: size(server.diskUsedBytes, server.diskTotalBytes) ?? percentText(diskPercent))
        }
    }

    private func meter(_ label: String, percent: Double?, text: String) -> some View {
        MeterBar(label: label, value: text, fraction: (percent ?? 0) / 100)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func size(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return PultikFormat.sizeRatio(used: max(0, used), total: total)
    }

    private func percentText(_ value: Double?) -> String {
        value.map { PultikFormat.percent($0 / 100) } ?? "—"
    }
}
