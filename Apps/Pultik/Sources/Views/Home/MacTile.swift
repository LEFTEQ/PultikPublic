import SwiftUI

/// Home's Mac widget (vt-7727 D8): this Mac's vitals as three figures —
/// memory with swap, load over its cores, the hottest sensor with the
/// fastest fan — then toolkit's worst findings. It formats `MacHealthStore`'s
/// report and `FanStore` as published, never a poll of its own; a line
/// opens its object on This Mac.
struct MacTile: View {
    var health: MacHealthStore = .shared
    var fans: FanStore = .shared
    /// A finding's object id; nil opens This Mac.
    let onOpen: (String?) -> Void
    @Environment(\.tileCompact) private var compact

    static func isShown(store: StatusStore) -> Bool {
        MacHealthStore.shared.status != .hidden
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch health.status {
            case .hidden:
                EmptyView()
            case let .stale(report):
                Text("toolkit watch is not publishing — last report \(report.generatedAt.shortAge) ago")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            case let .fresh(report):
                vitals(report.machine)
                findings(report)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }

    private var header: some View {
        let orphans = health.status.fresh?.headline.orphans ?? 0
        return TileHeader(title: "This Mac", count: orphans, tone: orphans > 0 ? .orange : .secondary,
                          caption: health.status.fresh.map { "as of \(PultikFormat.clock($0.generatedAt))" },
                          action: { onOpen(nil) }, actionHelp: "Fans, memory, findings and network — .m")
    }

    private func vitals(_ machine: MacHealth.Machine) -> some View {
        let ram = machine.memTotalGb > 0 ? machine.memUsedGb / machine.memTotalGb : 0
        return HStack(alignment: .firstTextBaseline, spacing: 18) {
            figure(String(format: "%.0f", machine.memUsedGb), unit: String(format: "/%.0f GB", machine.memTotalGb),
                   caption: machine.swapTotalGb > 0
                       ? "ram · swap \(MacHealthFormat.gigabytes(machine.swapUsedGb, of: machine.swapTotalGb))" : "ram",
                   tone: MeterBar.tone(ram))
            figure(String(format: "%.1f", machine.load1), unit: nil, caption: "load · \(machine.cores) cores",
                   tone: machine.load1 > Double(machine.cores) ? Theme.warn : Theme.ink)
            if !compact, let hottest = fans.hottestCelsius {
                let fastest = fans.fans.map(\.currentRPM).max()
                figure("\(Int(hottest.rounded()))", unit: "°C",
                       caption: fastest.map { "hottest · \($0) rpm" } ?? "hottest",
                       tone: hottest >= 95 ? Theme.danger : hottest >= 85 ? Theme.warn : Theme.ink)
            }
        }
    }

    private func figure(_ value: String, unit: String?, caption: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(TileMetrics.heroFont).foregroundStyle(tone)
                if let unit { Text(unit).font(TileMetrics.heroUnitFont).foregroundStyle(Theme.ink2) }
            }
            Text(caption).font(TileMetrics.heroUnitFont).foregroundStyle(Theme.ink2)
        }
        // A figure never wraps: on a narrow tile it shrinks instead.
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func findings(_ report: MacHealth) -> some View {
        let worst = report.findings.filter { $0.severity != .ok }.prefix(3)
        if !worst.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(worst)) { finding in
                    MacTileFinding(finding: finding, compact: compact) {
                        onOpen(MacHealthPage.objectID(finding))
                    }
                }
            }
        }
    }
}

/// One finding: severity glyph · title · memory · age.
private struct MacTileFinding: View {
    let finding: MacHealth.Finding
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tone).frame(width: 14)
                Text(finding.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                if !compact {
                    Text(MacHealthFormat.memory(mb: finding.memMb))
                        .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).fixedSize()
                }
                Text(finding.since.shortAge).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background { RowBackground(selected: false, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(finding.detail)
    }

    private var symbol: String {
        switch finding.severity {
        case .red: "xmark.circle.fill"
        case .amber: "exclamationmark.circle.fill"
        case .info, .ok: "circle"
        }
    }

    private var tone: Color {
        switch finding.severity {
        case .red: Theme.danger
        case .amber: Theme.warn
        case .info, .ok: Theme.ink3
        }
    }
}
