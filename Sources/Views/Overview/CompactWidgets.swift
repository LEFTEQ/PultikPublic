import SwiftUI

/// Decision D2 C (the operator, 2026-10-03, mockup card 52073): while the prod
/// board holds the right rail, the five overview widgets draw one line each
/// so reminders, estate firing and eve alerts fit beneath them without
/// scrolling. Each line is its full widget's glance spelled short
/// (`OverviewGlance` compact lines) — nothing here polls, and a click opens
/// the same page the full widget does.
struct CompactOverview: View {
    let store: StatusStore
    let fanStore: FanStore
    let showVitrinka: Bool
    let showDevbox: Bool
    let showCI: Bool
    let showEstate: Bool
    let showMac: Bool
    let onWork: () -> Void
    let onDevbox: () -> Void
    let onCI: () -> Void
    let onEstate: () -> Void
    let onFans: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showVitrinka { vitrinka }
            if showDevbox, let summary = store.devboxSummary {
                devbox(DevboxGlance(summary: summary, workspaces: store.devboxWorkspaces))
            }
            if showCI { ci(CIGlance(board: store.laneBoard, repos: store.repos)) }
            if showEstate { estate(EstateGlance(services: store.serviceStatuses)) }
            if showMac { mac }
        }
    }

    private var vitrinka: some View {
        // The same glance the full widget builds — `today` rebuilds per read.
        let selected = store.selectedVitrinkaWorkspace
        let glance = VitrinkaGlance(today: selected?.today ?? [], reason: \.reason, liveQuestions: [],
                                    elsewhere: store.vitrinkaWorkspaces
                                        .filter { $0.id != selected?.id && !$0.unavailable }
                                        .map(\.today))
        let waiting = glance.needsYou + glance.dueNow > 0 || glance.elsewhere != nil
        return CompactWidgetRow(title: "Vitrinka", help: "Open today’s work (.w)", onOpen: onWork) {
            CompactLine(glance.compactLine, tone: glance.overdue > 0 ? .red : waiting ? .orange : nil)
        }
    }

    private func devbox(_ glance: DevboxGlance) -> some View {
        CompactWidgetRow(title: "Devbox", help: "Open devbox workspaces (.d)", onOpen: onDevbox) {
            HStack(spacing: 6) {
                MiniGauge(label: "cpu", fraction: glance.cpuFraction)
                MiniGauge(label: "ram", fraction: glance.memoryFraction)
                CompactLine(glance.compactLine, tone: glance.alerts.isEmpty ? nil : .orange)
            }
        }
    }

    private func ci(_ glance: CIGlance) -> some View {
        CompactWidgetRow(title: "CI", help: "Open CI jobs (.c)", onOpen: onCI) {
            CompactLine(glance.compactLine,
                        tone: !glance.githubUnreachable && glance.failedRuns > 0 ? .red : nil)
        }
    }

    private func estate(_ glance: EstateGlance) -> some View {
        CompactWidgetRow(title: "Estate", help: "Open the estate (.e)", onOpen: onEstate) {
            CompactLine("services " + glance.compactLine, tone: glance.down.isEmpty ? nil : .red)
        }
    }

    private var mac: some View {
        CompactWidgetRow(title: "This Mac", help: "Open the fan deck (.f)", onOpen: onFans) {
            CompactLine(MacGlance.compactLine(cpuPercent: fanStore.cpuLoad.map { $0 * 100 },
                                              memoryPercent: fanStore.memUsedFraction.map { $0 * 100 },
                                              celsius: fanStore.hottest?.celsius),
                        tone: nil)
        }
    }
}

/// One compact widget: the widget's kicker and chevron, its one line at the
/// trailing edge; the whole row opens the widget's page.
struct CompactWidgetRow<Line: View>: View {
    let title: String
    let help: String
    let onOpen: () -> Void
    @ViewBuilder let line: () -> Line
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Kicker(text: title)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 0.8 : 0.28)
            Spacer(minLength: 6)
            line()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? RailRowMetrics.hoverFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct CompactLine: View {
    let text: String
    let tone: Color?

    init(_ text: String, tone: Color?) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(RailRowMetrics.metaFont)
            .monospacedDigit()
            .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

/// A 22pt gauge with its label, tinted like the full widget's (LoadTier).
private struct MiniGauge: View {
    let label: String
    let fraction: Double?

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let fraction {
                    Capsule()
                        .fill(percentTone(fraction * 100).opacity(0.8))
                        .frame(width: 22 * fraction)
                }
            }
            .frame(width: 22, height: 4)
        }
        .help(fraction.map { "\(label) \(Int(($0 * 100).rounded()))%" } ?? "\(label) —")
    }
}
