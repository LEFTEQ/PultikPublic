import SwiftUI

/// The Mac module's list (spec 2026-10-04, WP8): the machine line, the
/// fans and sensors as the first object (`.f` opens it), then what on this
/// Mac is probably not needed — the whole Mac's memory as a square treemap
/// beside the findings, worst first, each with its evidence and, where
/// toolkit allows it, a Stop… that asks before it runs — and the last
/// minute's network. Never Sleep and the display-preset cycle are the
/// header's verbs. The report is toolkit's as published; the page computes
/// nothing but layout. The filter matches a finding, a family, a talker,
/// and the fans detail's sensors.
struct MacHealthPage: View {
    let health: MacHealthStore
    var fanStore: FanStore = .shared
    /// `/hide fans` takes the fans object away (the section's old gate).
    var fansShown = true
    let filter: String
    var selectedID: String?
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }
    var now: () -> Date = Date.init

    @State private var stops: [String: MacHealthStopState] = [:]

    private static let treemapSide: CGFloat = 272

    private var text: String {
        filter.trimmingCharacters(in: .whitespaces)
    }

    private func matches(_ fields: String?...) -> Bool {
        text.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(text) == true }
    }

    var body: some View {
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header
                switch health.status {
                case .hidden:
                    RailNote("No Mac health report — toolkit watch serve publishes one every minute")
                        .padding(.top, 6)
                case let .stale(report):
                    RailNote("toolkit watch is not publishing — last report \(report.generatedAt.shortAge(relativeTo: now())) ago")
                        .padding(.top, 6)
                case let .fresh(report):
                    machineStrip(report.machine)
                }
                if fansShown {
                    let id = PaletteMode.macFans
                    ListRow(title: "Fans & sensors", id: fanStore.isSimulated ? "simulated" : nil,
                            meta: Text(verbatim: fansMeta), selected: selectedID == id, action: { onOpen(id) }) {
                        Image(systemName: "fanblades")
                            .font(.system(size: 12))
                            .foregroundStyle(fanStore.heldRPM.isEmpty ? Theme.ink2 : Theme.warn)
                            .frame(width: 20)
                    }
                    .id(id)
                    .padding(.bottom, 8)
                }
                if let report = health.status.fresh {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            memory(report)
                            network(report)
                        }
                        .frame(width: Self.treemapSide)
                        findings(report)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    diagnostics(report)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        #if DEBUG
        // Hands-off QA opens a row's confirm; only a click ever confirms it.
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            guard note.userInfo?["cmd"] as? String == "mac-stop", let id = note.userInfo?["text"] as? String,
                  health.status.fresh?.findings.contains(where: { $0.id == id && $0.stop.supported }) == true
            else { return }
            stops[id] = .confirming
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("This Mac")
                .font(Theme.Typo.title)
            if let report = health.status.fresh {
                Text(report.headline.text.isEmpty ? "nothing flagged" : report.headline.text)
                    .font(Theme.Typo.figure)
                    .foregroundStyle(report.headline.text.isEmpty ? Theme.ink2 : tone(report.headline.severity))
                    .lineLimit(1)
            }
            Spacer()
            if let report = health.status.fresh {
                Text("as of \(PultikFormat.clock(report.generatedAt))")
                    .font(Theme.Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink3)
                    .help("When toolkit published this report — CPU and network average the \(report.windowSeconds) s before it")
            }
            MacAwakeVerb(awake: AwakeStore.shared)
            if BrightnessStore.shared.isAvailable {
                MacPresetVerb(brightness: BrightnessStore.shared)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// `2 fans · 2400 rpm · auto · 62 °C hottest`.
    private var fansMeta: String {
        var parts: [String] = []
        if let fastest = fanStore.fans.max(by: { $0.currentRPM < $1.currentRPM }) {
            parts.append("\(fanStore.fans.count) fan\(fanStore.fans.count == 1 ? "" : "s") · \(fastest.currentRPM) rpm")
            parts.append(fanStore.activeCurveID.map { (FanCurve.preset($0)?.name ?? $0).lowercased() }
                ?? (fanStore.heldRPM.isEmpty ? "auto" : "held"))
        }
        if let hottest = fanStore.hottest { parts.append("\(Int(hottest.celsius.rounded())) °C hottest") }
        if fanStore.thermalState != .nominal { parts.append("thermal pressure") }
        return parts.isEmpty ? "sensors · vitals" : parts.joined(separator: " · ")
    }

    /// The Devbox page's metric strip, for this Mac.
    private func machineStrip(_ machine: MacHealth.Machine) -> some View {
        let ramPercent = machine.memTotalGb > 0 ? machine.memUsedGb / machine.memTotalGb * 100 : nil
        let swapPercent = machine.swapTotalGb > 0 ? machine.swapUsedGb / machine.swapTotalGb * 100 : nil
        return HStack(spacing: 22) {
            stripCell("ram", MacHealthFormat.gigabytes(machine.memUsedGb, of: machine.memTotalGb),
                      tone: ramPercent.map(percentTone))
            stripCell("compressed", MacHealthFormat.gigabytes(machine.compressorGb), tone: nil,
                      help: "Memory macOS is holding compressed")
            stripCell("swap", machine.swapTotalGb > 0
                          ? MacHealthFormat.gigabytes(machine.swapUsedGb, of: machine.swapTotalGb)
                          : "0",
                      tone: swapPercent.map(percentTone))
            stripCell("cpu · \(machine.cores) cores", "\(Int(machine.cpuPct.rounded()))%",
                      tone: percentTone(machine.cpuPct))
            stripCell("load", String(format: "%.1f", machine.load1),
                      tone: machine.cores > 0 ? percentTone(machine.load1 / Double(machine.cores) * 100) : nil,
                      help: String(format: "load1 %.2f over %d cores", machine.load1, machine.cores))
            stripCell("processes", "\(machine.procs)", tone: nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .padding(.bottom, 8)
    }

    private func stripCell(_ label: String, _ value: String, tone: Color?, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func memory(_ report: MacHealth) -> some View {
        let families = report.families.filter { matches($0.name) }
        let shown = families.reduce(0) { $0 + $1.memMb } / 1024
        return VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Memory", count: families.count)
            if families.isEmpty {
                RailNote(report.families.isEmpty ? "No families reported" : "No match")
            } else {
                MacHealthTreemap(families: families, side: Self.treemapSide)
                Text("\(MacHealthFormat.gigabytes(shown)) in these families · \(MacHealthFormat.gigabytes(report.machine.memUsedGb)) used")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .help("Tiles are sized by each family's footprint and colored by its worst finding")
            }
        }
    }

    private func network(_ report: MacHealth) -> some View {
        let talkers = report.network.top.filter { matches($0.name) }
        return VStack(alignment: .leading, spacing: 3) {
            Kicker(text: "Network · last minute")
                .padding(.top, 10)
            if talkers.isEmpty {
                RailNote(report.network.top.isEmpty ? "No traffic worth listing" : "No match")
            }
            ForEach(Array(talkers.enumerated()), id: \.offset) { _, talker in
                HStack(spacing: 6) {
                    Text(talker.name)
                        .font(.system(size: 9.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: talker.tunnel ? "VPN tunnel" : String(talker.pid))
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("↑ \(MacHealthFormat.rate(talker.outBps))")
                        .frame(width: 66, alignment: .trailing)
                    Text("↓ \(MacHealthFormat.rate(talker.inBps))")
                        .frame(width: 66, alignment: .trailing)
                }
                .font(RailRowMetrics.metaFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.vertical, 1)
                .help(talker.tunnel
                      ? "\(talker.name) (\(talker.pid)) carries other processes' traffic through the VPN"
                      : "\(talker.name) (\(talker.pid))")
            }
        }
    }

    private func findings(_ report: MacHealth) -> some View {
        let rows = findingRows(report)
        return VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Findings", count: rows.count,
                   tone: rows.first.map { tone($0.severity) } ?? .secondary)
            if rows.isEmpty {
                RailNote(report.findings.isEmpty ? "Nothing flagged — every process has an owner" : "No match")
            }
            ForEach(rows) { finding in
                let id = Self.objectID(finding)
                MacHealthFindingRow(finding: finding, markID: id, now: now(),
                                    state: stops[finding.id],
                                    selected: selectedID == id,
                                    onOpen: { onOpen(id) },
                                    onAsk: { stops[finding.id] = .confirming },
                                    onCancel: { stops[finding.id] = nil },
                                    onConfirm: { stop(finding) })
                    .id(id)
            }
        }
    }

    @ViewBuilder
    private func diagnostics(_ report: MacHealth) -> some View {
        if !report.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text("partial · \(diagnostic.code) — \(diagnostic.detail)")
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func stop(_ finding: MacHealth.Finding) {
        guard let argv = finding.stop.argv, stops[finding.id] == .confirming else { return }
        stops[finding.id] = .running
        Task {
            let names = Dictionary(finding.processes.map { ($0.pid, $0.name) }) { first, _ in first }
            let outcome = await MacHealthStop.run(argv, names: names)
            stops[finding.id] = .done(outcome)
            health.reread()
        }
    }

    private func tone(_ severity: MacHealth.Severity) -> Color {
        MacHealthTone.color(severity)
    }
}

/// The fans (`PaletteMode.macFans`), then the findings worst first, as
/// drawn. Stop… stays on the row behind its confirmation; a finding's
/// detail is read-only, the fans' detail is the fan deck.
extension MacHealthPage: ModulePage {
    static func objectID(_ finding: MacHealth.Finding) -> String { "finding:\(finding.id)" }

    /// The 272 pt treemap column beside findings that still read.
    var listWidth: CGFloat { 580 }
    var minListWidth: CGFloat { 580 }

    /// Stop on every marked finding toolkit allows it for (bulk D4): one
    /// `macwatch stop` call for all their processes, each finding told its
    /// own answer. Only a fresh report's findings are ever offered.
    var bulkVerbs: [BulkVerb] {
        let findings = health.status.fresh?.findings ?? []
        func finding(_ id: String) -> MacHealth.Finding? { findings.first { Self.objectID($0) == id } }
        return [BulkVerb(
            id: "stop", title: "Stop", symbol: "stop.circle", noun: "finding", destructive: true,
            help: "Asks first — names every process before anything is stopped",
            caution: "toolkit re-checks each process is the same one, still flagged, before it signals it.",
            skip: { id in
                guard let finding = finding(id) else { return "no longer in the report" }
                return finding.stop.supported && finding.stop.argv != nil ? nil : finding.stop.reason ?? "not stoppable here"
            },
            describe: { id in finding(id).map { MacHealthFormat.processes($0.processes) } },
            run: { ids, report in
                let targets = ids.compactMap { id in
                    finding(id).flatMap { finding in
                        finding.stop.argv.map { argv in
                            MacHealthStop.Target(id: id, argv: argv,
                                                 names: Dictionary(finding.processes.map { ($0.pid, $0.name) }) { first, _ in first })
                        }
                    }
                }
                for target in targets { report(target.id, .running) }
                for (id, outcome) in await MacHealthStop.run(targets) {
                    switch outcome {
                    case let .stopped(said): report(id, .done(said))
                    case let .refused(why): report(id, .failed("refused — \(why)"))
                    }
                }
                health.reread()
            }
        )]
    }

    func findingRows(_ report: MacHealth) -> [MacHealth.Finding] {
        report.findingsWorstFirst.filter { matches($0.title, $0.family, $0.project, $0.detail) }
    }

    var objects: [ModuleObject] {
        let fans = fansShown ? [fansObject] : []
        guard let report = health.status.fresh else { return fans }
        let date = self.now()
        return fans + findingRows(report).map { finding in
            var facts = [ModuleObject.Fact(label: "family", value: finding.family),
                         .init(label: "kind", value: finding.kind),
                         .init(label: "since", value: PultikFormat.ago(finding.since, now: date)),
                         .init(label: "cost", value: MacHealthFormat.cost(finding))]
            if let project = finding.project { facts.append(.init(label: "project", value: project)) }
            let status = switch finding.severity {
            case .red: Chip("likely orphan", .danger)
            case .amber: Chip("worth a look", .warn)
            case .info: Chip("info", .neutral)
            case .ok: Chip("ok", .ok)
            }
            return ModuleObject(id: Self.objectID(finding), title: finding.title, status: status,
                                meta: finding.family, symbol: MacHealthTone.symbol(finding.severity),
                                project: finding.project, facts: facts, markable: finding.stop.supported)
        }
    }

    private var fansObject: ModuleObject {
        let status = if fanStore.isSimulated {
            Chip("simulated", .dashed)
        } else {
            switch fanStore.helperHealth {
            case .healthy: Chip("helper ok", .ok)
            case .outdated: Chip("helper outdated", .warn)
            case .down: Chip("read-only", .neutral)
            }
        }
        var facts = fanStore.fans.map { fan in
            ModuleObject.Fact(label: fan.name, value: "\(fan.currentRPM) rpm · \(fan.minRPM)–\(fan.maxRPM)")
        }
        if let hottest = fanStore.hottest {
            facts.append(.init(label: "hottest", value: "\(hottest.name) \(Int(hottest.celsius.rounded())) °C"))
        }
        return ModuleObject(id: PaletteMode.macFans, title: "Fans & sensors", status: status, meta: fansMeta,
                            symbol: "fanblades", project: "mac", facts: facts)
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if object.id == PaletteMode.macFans {
            FanDeckView(fanStore: fanStore, filter: filter)
        } else if let finding = health.status.fresh?.findings.first(where: { Self.objectID($0) == object.id }) {
            MacFindingDetail(finding: finding)
        }
    }
}

/// Never Sleep (docs/specs/2026-09-10-never-sleep-decisions.md, decisions 4
/// and 6) as a header verb: the cup says this Mac is being held awake and
/// toggles it. Same `AwakeStore` the `awake` quick command flips.
private struct MacAwakeVerb: View {
    let awake: AwakeStore

    var body: some View {
        Button {
            awake.toggle()
        } label: {
            Label(awake.isAwake ? "Never Sleep" : "Sleep allowed",
                  systemImage: awake.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(Theme.Typo.meta)
                .foregroundStyle(awake.isAwake ? Theme.warn : Theme.ink2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(awake.isAwake ? "Turn Never Sleep off" : "Turn Never Sleep on")
    }

    private var help: String {
        if let since = awake.since {
            return "Never Sleep on since \(PultikFormat.clock(since)) — "
                + "the Mac stays running and unlocked (lid close still sleeps); click to allow sleep"
        }
        return "Never Sleep off — click to keep this Mac running and unlocked; also “awake” in the palette"
    }
}

/// The display-preset cycle (docs/specs/2026-09-06-display-presets-decisions.md)
/// as a header verb: each click applies the next preset in Settings ▸
/// Displays order; the glyph names what the click does next (moon for a dark
/// preset, sun for a bright one), the tint whether a preset is applied.
private struct MacPresetVerb: View {
    let brightness: BrightnessStore

    var body: some View {
        Button {
            brightness.cycle()
        } label: {
            Label(brightness.next?.name ?? "Displays",
                  systemImage: (brightness.next?.brightness ?? 100) <= 30 ? "moon.fill" : "sun.max")
                .font(Theme.Typo.meta)
                .foregroundStyle(brightness.active != nil ? Theme.warn : Theme.ink2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(brightness.next == nil)
        .help(help)
        .accessibilityLabel(brightness.next.map { "Apply display preset \($0.name)" } ?? "Display presets")
    }

    private var help: String {
        guard let next = brightness.next else { return "No display presets — add one in Settings ▸ Displays" }
        let now = brightness.active.map { "Displays at “\($0.name)” — " } ?? ""
        return "\(now)click for “\(next.name)” (\(next.brightness)%) — also “\(next.name.lowercased())” in the palette"
    }
}

/// A finding's evidence in the detail: what it is, the proof in a well,
/// and every process it names.
private struct MacFindingDetail: View {
    let finding: MacHealth.Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(finding.detail)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.evidence)
                .font(Theme.Typo.code)
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            if !finding.stop.supported, let reason = finding.stop.reason {
                Text("not stoppable here — \(reason)")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
            }
            if !finding.processes.isEmpty {
                Text("Processes").microLabel()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(finding.processes.enumerated()), id: \.offset) { _, process in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: String(process.pid))
                                .font(Theme.Typo.figure)
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 64, alignment: .trailing)
                            Text(process.command)
                                .font(Theme.Typo.figure)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .kitTile()
    }
}

private enum MacHealthStopState: Equatable {
    case confirming
    case running
    case done(MacHealthStop.Outcome)
}

/// red · amber in the panel's semantic colors; info and ok stay quiet.
enum MacHealthTone {
    static func color(_ severity: MacHealth.Severity) -> Color {
        switch severity {
        case .red: .red
        case .amber: .orange
        case .info: Theme.ink3
        case .ok: .secondary
        }
    }

    static func symbol(_ severity: MacHealth.Severity) -> String {
        switch severity {
        case .red: "xmark.octagon.fill"
        case .amber: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .ok: "checkmark.circle"
        }
    }
}

/// One finding: glyph, title and age, what it is, the proof in mono, what it
/// costs — and Stop…, which first names exactly the processes it will stop
/// and runs only on a second, explicit click.
private struct MacHealthFindingRow: View {
    let finding: MacHealth.Finding
    /// Its object id: the mark's check takes the severity glyph's place.
    let markID: String
    let now: Date
    let state: MacHealthStopState?
    var selected = false
    /// The row's click: select it and open its detail. Stop… keeps its own.
    let onOpen: () -> Void
    let onAsk: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            MarkSlot(id: markID, hovering: hovering, size: 9.5) {
                Image(systemName: MacHealthTone.symbol(finding.severity))
                    .font(.system(size: 9.5))
                    .foregroundStyle(MacHealthTone.color(finding.severity))
            }
            .frame(width: 11)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(finding.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("since \(finding.since.shortAge(relativeTo: now))")
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(finding.since.formatted(date: .abbreviated, time: .shortened))
                }
                Text(finding.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.evidence)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(costLine)
                        .font(RailRowMetrics.metaFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    trailing
                }
                if !finding.stop.supported, let reason = finding.stop.reason {
                    Text("not stoppable here — \(reason)")
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .confirming { confirm }
                if case let .done(outcome) = state { result(outcome) }
            }
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, 6)
        .background { RowBackground(selected: selected, hovering: hovering || state != nil, mark: markID) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help(finding.processes.map { "\($0.pid)  \($0.command)" }.joined(separator: "\n"))
    }

    private var costLine: String {
        let cost = MacHealthFormat.cost(finding)
        return finding.project.map { "\(cost) · \($0)" } ?? cost
    }

    @ViewBuilder
    private var trailing: some View {
        if finding.stop.supported, state == nil {
            Button("Stop…", action: onAsk)
                .controlSize(.mini)
                .help("Asks first — names the processes before anything is stopped")
        } else if state == .running {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("stopping")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stop \(MacHealthFormat.processes(finding.processes))?")
                .font(.system(size: 10, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("toolkit re-checks each process is the same one, still flagged, before it signals it.")
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                Button("Stop", role: .destructive, action: onConfirm)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .padding(.top, 3)
    }

    private func result(_ outcome: MacHealthStop.Outcome) -> some View {
        let (symbol, text, tone): (String, String, Color) = switch outcome {
        case let .stopped(said): ("checkmark.circle", said, .green)
        case let .refused(why): ("exclamationmark.circle", "refused — \(why)", .orange)
        }
        return Label(text, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.top, 2)
    }
}
