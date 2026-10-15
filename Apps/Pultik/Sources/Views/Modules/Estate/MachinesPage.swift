import SwiftUI

/// Estate's Machines view (vt-7727 D1, D9; spec 2026-09-23 D11 before it):
/// one lean line per machine — This Mac with its fans and sensors, then
/// each host followed by its VM guests — with cpu · ram · disk micro meters
/// and its firing count, never summed across hosts. Below them This Mac's
/// findings (Stop…, bulk Stop…), then the estate's firing alerts and the
/// expiry radar's renewals — the objects Now's estate rows open — then every
/// service probe by the box it runs on. A machine's detail opens on what
/// needs you, then a bento. The filter matches any of them.
struct MachinesPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// Firing rules the prod board does not claim (`firingGlance`'s rule),
    /// heartbeat and pending ones already gone.
    var firing: [FiringAlert] = []
    var renewals: [NowInputs.Expiry] = []
    /// This Mac's provider: its fans, findings, bulk Stop… and details.
    let mac: MacHealthPage
    var view: ModuleView? = .machines
    var onView: (ModuleView) -> Void = { _ in }
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }

    private var text: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ fields: String?...) -> Bool {
        text.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }

    /// This Mac, the hosts and their guests, as drawn; the fans row rides
    /// under This Mac.
    private var lines: [MachineLine] {
        MachineLine.lines(servers: store.serverMetrics, firing: firing, mac: mac.health.status, fans: mac.fanStore,
                          guests: true)
            .filter { line in
                let server = store.serverMetrics.first { Self.objectID($0) == line.id }
                return matches(line.name, server?.instance, server?.vmHost, line.id == PaletteMode.thisMac ? "mac" : nil)
            }
    }

    private var showsFans: Bool {
        mac.fansShown && matches("Fans & sensors", "fans", "mac") && lines.contains { $0.id == PaletteMode.thisMac }
    }

    /// The firing alerts about `server` itself (its instance, or a guest's own).
    private func alerts(on server: ServerMetrics) -> [FiringAlert] {
        firing.filter { $0.serverID(among: store.serverMetrics) == server.id }
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
        let now = Date()
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header
                MachineColumnHeads()
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                if lines.isEmpty {
                    RailNote(store.serverMetrics.isEmpty ? "No server metrics — off the mesh?" : "No match")
                }
                ForEach(lines) { line in
                    MachineRow(line: line, selected: selectedID == line.id) { onOpen(line.id) }
                        .id(line.id)
                        .padding(.horizontal, 8)
                    if line.id == PaletteMode.thisMac, showsFans {
                        fansRow
                    }
                }
                MacFindingsSection(page: mac)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                firingSection(now: now)
                renewalsSection(now: now)
                Kicker(text: "Services", count: services.count,
                       tone: EstateGlance(services: store.serviceStatuses).down.isEmpty ? .secondary : .red)
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

    /// Fans & sensors under This Mac: `.f` opens it.
    private var fansRow: some View {
        let id = PaletteMode.macFans
        let fans = mac.fansObject
        return ListRow(title: fans.title, id: mac.fanStore.isSimulated ? "simulated" : nil,
                       meta: fans.meta.map { Text(verbatim: $0) }, selected: selectedID == id, action: { onOpen(id) }) {
            Image(systemName: "fanblades")
                .font(.system(size: 12))
                .foregroundStyle(mac.fanStore.heldRPM.isEmpty ? Theme.ink2 : Theme.warn)
                .frame(width: 20)
        }
        .id(id)
        .padding(.leading, 22)
        .padding(.horizontal, 8)
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

    /// "Estate [Machines · Backups] ⇥ · 5 machines · 40/67 apps synced ·
    /// 13 firing · backups 3 need a look", and "as of" while a Semafor is silent.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Estate").font(Theme.Typo.title)
            ViewBar(views: PanelModule.estate.views, selected: view, onSelect: onView)
            Text(summary).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 4)
            if let asOf = store.estateAsOf {
                Text("Semafor \(PultikFormat.asOf(asOf))").font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private var summary: String {
        let machines = store.serverMetrics.count + (mac.health.status.fresh == nil ? 0 : 1)
        var parts = ["\(machines) machines"]
        let apps = store.estateBoxes.flatMap(\.box.appList)
        if !apps.isEmpty {
            parts.append("\(store.estateBoxes.reduce(0) { $0 + $1.box.syncedCount })/\(apps.count) apps synced")
        }
        if !firing.isEmpty { parts.append("\(firing.count) firing") }
        let now = Date()
        let look = store.estatePipelines.filter { BackupVerdict.of($0, now: now) != .go }.count
        if look > 0 { parts.append("backups \(look) need a look") }
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

/// The machines (This Mac, its fans, the hosts and their guests), This
/// Mac's findings, the firing alerts, the renewals, then every service
/// probe in `ServiceRail`'s host order, as drawn. A machine is
/// `server:<ServerMetrics.id>` or `this-mac`; a finding `finding:<id>`; an
/// alert its `FiringAlert` id; a renewal its radar item id — the ids Now's
/// rows target.
extension MachinesPage: ModulePage {
    /// By `ServerMetrics.id`: a guest's name repeats across hosts.
    static func objectID(_ server: ServerMetrics) -> String { "server:\(server.id)" }
    static func objectID(_ alert: FiringAlert) -> String { alert.id }

    var listWidth: CGFloat { 440 }

    /// This Mac's Stop… on its marked findings — the only markable rows.
    var bulkVerbs: [BulkVerb] { mac.bulkVerbs }

    var objects: [ModuleObject] {
        let now = Date()
        var machines: [ModuleObject] = []
        for line in lines {
            if line.id == PaletteMode.thisMac {
                machines.append(thisMacObject)
                if showsFans { machines.append(mac.fansObject) }
            } else if let server = store.serverMetrics.first(where: { Self.objectID($0) == line.id }) {
                machines.append(machineObject(server))
            }
        }
        let findings = mac.objects.filter { $0.id.hasPrefix("finding:") }
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
        return machines + findings + fires + renewing + probes
    }

    private var thisMacObject: ModuleObject {
        let report = mac.health.status.fresh
        var facts: [ModuleObject.Fact] = []
        if let machine = report?.machine {
            facts = [.init(label: "ram", value: MacHealthFormat.gigabytes(machine.memUsedGb, of: machine.memTotalGb)),
                     .init(label: "swap", value: MacHealthFormat.gigabytes(machine.swapUsedGb, of: machine.swapTotalGb)),
                     .init(label: "cpu", value: "\(Int(machine.cpuPct.rounded()))%"),
                     .init(label: "load", value: String(format: "%.1f", machine.load1)),
                     .init(label: "processes", value: "\(machine.procs)")]
        }
        let orphans = report?.headline.orphans ?? 0
        return ModuleObject(id: PaletteMode.thisMac, title: "This Mac", label: report.map { "\($0.machine.cores) cores" },
                            status: orphans > 0 ? Chip("\(orphans) likely orphans", .warn) : nil,
                            meta: report.map { $0.headline.text.isEmpty ? "nothing flagged" : $0.headline.text },
                            symbol: "laptopcomputer", project: "mac", facts: facts)
    }

    private func machineObject(_ server: ServerMetrics) -> ModuleObject {
        var facts = [ModuleObject.Fact(label: "instance", value: server.instance)]
        if let vmHost = server.vmHost {
            let host = store.serverMetrics.first { !$0.isGuest && $0.instance == vmHost }?.name ?? vmHost
            facts.append(.init(label: "guest of", value: host))
        }
        if let cores = server.cpuCount { facts.append(.init(label: "cores", value: "\(cores)")) }
        if let used = server.ramUsedBytes, let total = server.ramTotalBytes, total > 0 {
            facts.append(.init(label: "ram", value: PultikFormat.sizeRatio(used: used, total: total)))
        }
        if let used = server.diskUsedBytes, let total = server.diskTotalBytes, total > 0 {
            facts.append(.init(label: "disk", value: PultikFormat.sizeRatio(used: used, total: total)))
        }
        let box = store.estateBoxes.first { $0.box.name.caseInsensitiveCompare(server.name) == .orderedSame }?.box
        if let version = box?.toolkitVersion { facts.append(.init(label: "toolkit", value: version)) }
        let firing = alerts(on: server)
        let status: Chip? = firing.isEmpty ? nil
            : Chip("\(firing.count) firing", firing.contains { $0.severity == "critical" } ? .danger : .warn)
        var context: [Chip] = []
        if let box, box.sync == "pending" {
            context.append(Chip("pending\(box.ahead.map { " · \($0) ahead" } ?? "")", .warn, symbol: "clock"))
        }
        return ModuleObject(id: Self.objectID(server), title: server.name, label: server.instance,
                            status: status, meta: server.cpuCount.map { "\($0) cores" },
                            symbol: server.isGuest ? "shippingbox" : "server.rack",
                            project: server.isGuest ? nil : server.name, context: context, facts: facts)
    }

    /// This Mac's bento, a machine's needs-you band and bento, the fans'
    /// deck, a finding's evidence, a firing alert's description.
    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if object.id == PaletteMode.thisMac {
            ThisMacDetail(page: mac)
        } else if object.id == PaletteMode.macFans || object.id.hasPrefix("finding:") {
            mac.detailContent(for: object)
        } else if let alert = firing.first(where: { Self.objectID($0) == object.id }) {
            if let description = alert.description, !description.isEmpty {
                Tile(kicker: "Description") {
                    Text(description).font(Theme.Typo.body).foregroundStyle(Theme.ink2).textSelection(.enabled)
                }
            }
        } else if let server = store.serverMetrics.first(where: { Self.objectID($0) == object.id }) {
            MachineDetail(store: store, server: server, alerts: alerts(on: server))
        }
    }
}
