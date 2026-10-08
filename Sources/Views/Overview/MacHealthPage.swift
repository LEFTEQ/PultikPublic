import SwiftUI

/// `.mac` (spec 2026-10-04): what on this Mac is probably not needed. The
/// machine line, then the whole Mac's memory as a square treemap beside the
/// findings — worst first, each with its evidence and, where toolkit allows
/// it, a Stop… that asks before it runs — and the last minute's network.
/// Everything is toolkit's report as published; the page computes nothing
/// but layout. The filter matches a finding, a family or a talker.
struct MacHealthPage: View {
    let health: MacHealthStore
    let filter: String
    let onBack: () -> Void
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
        ScrollView {
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
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Mac health")
                .font(.system(size: 14, weight: .semibold))
            if let report = health.status.fresh {
                Text(report.headline.text.isEmpty ? "nothing flagged" : report.headline.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(report.headline.text.isEmpty ? Color.secondary : tone(report.headline.severity))
                    .lineLimit(1)
            }
            Spacer()
            if let report = health.status.fresh {
                Text(report.generatedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("When toolkit published this report — CPU and network average the \(report.windowSeconds) s before it")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
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
        let rows = report.findingsWorstFirst.filter { matches($0.title, $0.family, $0.project, $0.detail) }
        return VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Findings", count: rows.count,
                   tone: rows.first.map { tone($0.severity) } ?? .secondary)
            if rows.isEmpty {
                RailNote(report.findings.isEmpty ? "Nothing flagged — every process has an owner" : "No match")
            }
            ForEach(rows) { finding in
                MacHealthFindingRow(finding: finding, now: now(),
                                    state: stops[finding.id],
                                    onAsk: { stops[finding.id] = .confirming },
                                    onCancel: { stops[finding.id] = nil },
                                    onConfirm: { stop(finding) })
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
        case .info: .blue
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
    let now: Date
    let state: MacHealthStopState?
    let onAsk: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: MacHealthTone.symbol(finding.severity))
                .font(.system(size: 9.5))
                .foregroundStyle(MacHealthTone.color(finding.severity))
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
        .background(hovering || state != nil ? RailRowMetrics.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .onHover { hovering = $0 }
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
