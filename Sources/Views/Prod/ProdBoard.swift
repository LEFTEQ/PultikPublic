import SwiftUI

/// The right rail's prod board (decision D2 C, mockup card 52073): one card
/// per deployment in board order, over Hlídač's digest. Cards only format
/// `ProdGlance` — verdicts are Hlídač's (D14). A card opens `.h <key>`.
struct ProdBoardSection: View {
    let glance: ProdGlance
    let now: Date
    let onOpen: (String) -> Void

    var body: some View {
        RailSection(key: "prod", title: "Prod", count: glance.attention, tone: glance.headingTone,
                    accessory: AnyView(
                        Text(glance.cards.isEmpty ? "Hlídač" : "\(glance.cards.count) deployments · 24h")
                            .font(RailRowMetrics.metaFont)
                            .foregroundStyle(.tertiary)
                    ))
        {
            VStack(alignment: .leading, spacing: 6) {
                if glance.cards.isEmpty, let waiting = glance.waiting {
                    // F10: nothing configured and nothing heard yet still
                    // reads as one blind row, never as an empty all-clear.
                    HStack(spacing: RailRowMetrics.dotGap) {
                        ProdToneDot(tone: .blind)
                        Text(waiting)
                            .font(RailRowMetrics.titleFont)
                            .foregroundStyle(.orange)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, RailRowMetrics.inset)
                    .padding(.vertical, RailRowMetrics.verticalInset)
                    .help("The prod board reads Hlídač's digest; nothing has answered yet.")
                }
                ForEach(glance.cards) { card in
                    ProdCardView(card: card, now: now) { onOpen(card.key) }
                }
            }
        }
    }
}

/// settings.json problems — a malformed entry, a doubled prod key — as
/// orange rows of their own above the board (F4): they stay visible however
/// the board is folded or hidden, at most three plus "+N more".
struct ProdConfigIssues: View {
    let issues: [String]
    static let limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: "Settings", count: issues.count, tone: .orange)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(issues.prefix(Self.limit).enumerated()), id: \.offset) { _, issue in
                    RailRow(dot: .filled(.orange), title: "settings.json", subtitle: issue,
                            subtitleTone: .orange, help: issue) {}
                }
                if issues.count > Self.limit {
                    RailNote("+\(issues.count - Self.limit) more")
                }
            }
        }
        .padding(10)
    }
}

/// One deployment: dot · title · tier chip, the check chips, the day's
/// error/warning bars, and the most urgent issue.
struct ProdCardView: View {
    let card: ProdGlance.Card
    let now: Date
    let action: () -> Void
    /// Home's Production tile draws the 24 h bars taller than the rail did.
    var barHeight: CGFloat = 10
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if !card.chips.isEmpty {
                FlowRow(hSpacing: 3, vSpacing: 3) {
                    ForEach(card.chips) { chip in ProdChipView(chip: chip) }
                }
            }
            if let pool = card.deployment?.pool {
                Text(pool.summary(now: now))
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            barsRow
            if let issue = card.topIssue { issueRow(issue) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(hovering ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Open \(card.title) in the prod matrix (.h \(card.key))")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProdToneDot(tone: card.tone, size: RailRowMetrics.dotSize)
            Text(card.title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
            Text(card.tier.uppercased())
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 4)
            if let status = card.status {
                Text(status)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(card.tone == .blind ? Color.orange : Color.secondary)
                    .lineLimit(1)
            } else if let project = card.deployment?.project {
                Text(project)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Bars · the day's counts · `· 5xx N` on one line when it fits; when it
    /// does not, the 5xx tail takes a line of its own — no part of the
    /// glance is ever ellipsized (F5).
    private var barsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                barsAndLogs
                if let edge = edgeText { edge }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    barsAndLogs
                    Spacer(minLength: 0)
                }
                if let edge = edgeText { edge }
            }
        }
        .help(card.edgeLine ?? "")
    }

    @ViewBuilder
    private var barsAndLogs: some View {
        if let hours = card.hours, !hours.isEmpty {
            HourBars(stacks: hours.map(HourBars.Stack.init), height: barHeight)
        } else {
            Text(card.tone == .hollow ? "logs not shipped" : "no logs")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 81, height: barHeight)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        }
        if let logs = card.logsLine {
            logsText(logs)
        } else if card.tone == .hollow {
            Text("sentry only")
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    /// F5: edge 5xx belongs in the glance; 429s stay in the tooltip.
    private var edgeText: Text? {
        guard card.edgeLine != nil, let edge = card.deployment?.edge?.today else { return nil }
        return Text("· 5xx \(edge.serverErrors)")
            .font(RailRowMetrics.metaFont)
            .foregroundColor(edge.serverErrors > 0 && !card.stale ? .red : .secondary)
    }

    /// "890 err · 382 warn": the error count reads red once it is not zero.
    private func logsText(_ line: String) -> some View {
        let errors = card.deployment?.logs.today?.error ?? 0
        let parts = line.split(separator: " · ", maxSplits: 1).map(String.init)
        return HStack(spacing: 0) {
            Text(parts.first ?? line)
                .foregroundStyle(errors > 0 && !card.stale ? Color.red : Color.secondary)
            if parts.count > 1 {
                Text(" · " + parts[1]).foregroundStyle(.secondary)
            }
        }
        .font(RailRowMetrics.metaFont)
        .lineLimit(1)
        .fixedSize()
    }

    /// Up to two lines: an exception's distinguishing tail ("…reading
    /// 'jobId'") is the part worth reading.
    private func issueRow(_ issue: ProdGlance.TopIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if issue.isNew {
                Text("NEW")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .kerning(0.6)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            } else {
                ProdToneDot(tone: issue.tone, size: 5)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            }
            Text(issue.title)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(ProdCardView.age(issue.meta))
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .help([issue.title, issue.meta].joined(separator: "\n"))
    }

    /// A Sentry meta is "14× · 3 users · 12m"; the card keeps only the age —
    /// the matrix row carries the counts.
    static func age(_ meta: String) -> String {
        meta.components(separatedBy: " · ").last ?? meta
    }
}

/// A check chip: neutral when healthy, tinted when not, outlined when the
/// series is absent (blind).
struct ProdChipView: View {
    let chip: ProdGlance.Chip

    var body: some View {
        Text(chip.label)
            .font(.system(size: 8.5, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if chip.tone == .blind {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch chip.tone {
        case .red: .red
        case .orange: .orange
        case .blind, .hollow: Color.white.opacity(0.32)
        case .green: Color.white.opacity(0.55)
        }
    }

    private var background: Color {
        switch chip.tone {
        case .red: Color.red.opacity(0.13)
        case .orange: Color.orange.opacity(0.13)
        case .blind, .hollow: .clear
        case .green: Color.white.opacity(0.06)
        }
    }
}

/// The deployment dot: filled by verdict, striped grey while blind, a
/// hollow green ring when the deployment is not monitored.
struct ProdToneDot: View {
    let tone: ProdGlance.Tone
    var size: CGFloat = 6

    var body: some View {
        Group {
            switch tone {
            case .green: Circle().fill(Color.green)
            case .orange: Circle().fill(Color.orange)
            case .red: Circle().fill(Color.red)
            case .hollow: Circle().strokeBorder(Color.green, lineWidth: 1.2)
            case .blind:
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.7),
                                                   style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5])))
            }
        }
        .frame(width: size, height: size)
    }
}

extension ProdGlance.Tone {
    /// The SwiftUI colour of a verdict, for text and gauges.
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .blind, .hollow: .secondary
        }
    }
}

extension ProdGlance {
    /// Deployments asking for attention — what the heading's pill counts. A
    /// board with nothing to draw but its waiting row counts that row.
    var attention: Int {
        cards.isEmpty ? (waiting == nil ? 0 : 1)
            : cards.filter { $0.tone == .red || $0.tone == .orange || $0.tone == .blind }.count
    }

    /// The heading's tone, shared by the rail section and Home's tile.
    var headingTone: Color {
        if cards.contains(where: { $0.tone == .red }) { return .red }
        if waiting != nil || cards.contains(where: { $0.tone == .orange || $0.tone == .blind }) {
            return .orange
        }
        return .secondary
    }
}
