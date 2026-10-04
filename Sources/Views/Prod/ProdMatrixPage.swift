import AppKit
import SwiftUI

/// `.h` — the prod overview matrix (decision D4 B, mockup card 52046): one
/// row per deployment, columns derived from check ids (`ProdMatrix`). The
/// filter names a deployment and expands its row inline; the eve row's
/// expansion carries the accounts table (mockup card 52075).
struct ProdMatrixPage: View {
    let store: StatusStore
    let filter: String
    let onBack: () -> Void
    @State private var expanded: String?
    @State private var lastFilter: String?

    /// Fixed grid inside the page's 648pt. Every column is at least as wide
    /// as its full heading at 8.5pt mono (≈5.7pt a character with the
    /// kicker kerning), and the values are formatted compact to fit
    /// (`ProdMatrix.compact`): a heading or value is never ellipsized.
    static let nameWidth: CGFloat = 150
    static let widths: [ProdMatrix.Column: CGFloat] = [
        .probe: 66, .app: 60, .pool: 70, .logs: 66, .sentry: 52, .firing: 50, .backup: 46,
    ]
    static let columnSpacing: CGFloat = 6
    static let chevronWidth: CGFloat = 16

    private var now: Date { Date() }

    private var glance: ProdGlance { store.prodGlance }

    /// The row the filter names — `ProdMatrix.expandedKey`, the same
    /// resolution the panel driver reports as `prodExpanded`.
    private func target(in rows: [ProdMatrix.Row]) -> String? {
        ProdMatrix.expandedKey(filter: filter, rows: rows.map { (key: $0.key, title: $0.title) })
    }

    var body: some View {
        let glance = glance
        let rows = ProdMatrix.rows(glance)
        let open = lastFilter == filter ? expanded : target(in: rows)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                deploymentsHeading(glance, count: rows.count)
                columnHeader
                if rows.isEmpty {
                    RailNote(store.prodDigest == nil ? "Waiting for Hlídač — no digest yet" : "No deployments configured")
                }
                ForEach(rows) { row in
                    // A Button, so VoiceOver and keyboard users reach the
                    // expansion as a native control with its state.
                    Button {
                        lastFilter = filter
                        expanded = open == row.key ? nil : row.key
                    } label: {
                        rowView(row, isOpen: open == row.key)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.spoken)
                    .accessibilityValue(open == row.key ? "expanded" : "collapsed")
                    .accessibilityHint("Shows the deployment's checks, issues and accounts")
                    if open == row.key, let card = glance.cards.first(where: { $0.key == row.key }) {
                        ProdMatrixDetail(card: card, now: now)
                    }
                }
                estateFiring
                legend
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Prod")
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(store.prodUnreachableSince == nil ? Color.secondary : .orange)
            Spacer()
            if let generated = store.prodDigest?.generatedAt {
                Text(Self.stamp(generated))
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var subtitle: String {
        if let since = store.prodUnreachableSince {
            return "· Hlídač unreachable since \(Self.stamp(since, seconds: false))"
        }
        return "· all deployments"
    }

    private func deploymentsHeading(_ glance: ProdGlance, count: Int) -> some View {
        let severity = ProdMatrix.severityCounts(glance)
        return HStack(spacing: 6) {
            Kicker(text: "Deployments", count: count)
            if severity.critical > 0 { pill("\(severity.critical) crit", .red) }
            if severity.warning > 0 { pill("\(severity.warning) warn", .orange) }
            Spacer()
            Text(Set(glance.cards.compactMap { $0.deployment?.project }).sorted().joined(separator: " · "))
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func pill(_ text: String, _ tone: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(tone)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tone.opacity(0.15), in: Capsule())
    }

    private var columnHeader: some View {
        HStack(spacing: Self.columnSpacing) {
            headerText("Deployment").frame(width: Self.nameWidth, alignment: .leading)
            ForEach(ProdMatrix.Column.allCases) { column in
                headerText(column.title).frame(width: Self.widths[column] ?? 60, alignment: .leading)
            }
            Color.clear.frame(width: Self.chevronWidth)
        }
        .frame(height: 15)
    }

    /// A heading keeps its full text: `fixedSize` lets it run into the
    /// column gap rather than ever drawing an ellipsis.
    private func headerText(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .kerning(0.6)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private func rowView(_ row: ProdMatrix.Row, isOpen: Bool) -> some View {
        HStack(alignment: .center, spacing: Self.columnSpacing) {
            HStack(alignment: .top, spacing: 6) {
                ProdToneDot(tone: row.tone).padding(.top, 3.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(RailRowMetrics.titleFont).lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(RailRowMetrics.metaFont)
                            .foregroundStyle(row.tone == .blind ? Color.orange : Color.white.opacity(0.32))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.trailing, 8)
            .frame(width: Self.nameWidth, alignment: .leading)
            ForEach(ProdMatrix.Column.allCases) { column in
                cell(row.cells[column] ?? .empty)
                    .frame(width: Self.widths[column] ?? 60, alignment: .leading)
            }
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isOpen ? .secondary : .tertiary)
                .frame(width: Self.chevronWidth)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .help(isOpen ? "Collapse" : "Expand \(row.title)")
    }

    @ViewBuilder
    private func cell(_ cell: ProdMatrix.Cell) -> some View {
        if cell.tone == nil, cell.text == nil {
            Text("—").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.white.opacity(0.18))
        } else {
            HStack(spacing: 4) {
                if let tone = cell.tone { ProdToneDot(tone: tone) }
                // Shrinks before it would ever truncate; the compact format
                // keeps that rare.
                Text(cell.text ?? "?")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(cell.dimmed ? Color.white.opacity(0.32)
                        : cell.textTone?.color ?? Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
            }
            .help(cell.text ?? "")
        }
    }

    /// Firing alerts no deployment claims — the estate's own weather.
    @ViewBuilder
    private var estateFiring: some View {
        let glance = AlertGlance(store.firingAlerts.filter { !store.prodClaims($0) })
        if !glance.rows.isEmpty {
            HStack(spacing: 6) {
                Kicker(text: "Estate firing", count: glance.rows.count,
                       tone: glance.critical > 0 ? .red : .orange)
                Spacer()
                Text("not owned by a deployment")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            FiringAlertsRail(glance: glance)
                .padding(.horizontal, -8)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(.green, "ok")
            legendItem(.orange, "warning")
            legendItem(.red, "critical")
            legendItem(.blind, "unknown")
            Text("· logs = err · warn")
            Spacer()
            Text("click a row to expand · .h <name> opens it")
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.tertiary)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).padding(.top, 4)
        }
    }

    private func legendItem(_ tone: ProdGlance.Tone, _ text: String) -> some View {
        HStack(spacing: 4) {
            ProdToneDot(tone: tone)
            Text(text)
        }
    }

    static func stamp(_ date: Date, seconds: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }
}

/// A deployment's expanded matrix row: every check with its value, the
/// issues that need you, the day's bars and the deployment's links; eve's
/// also carries the pool lane and the accounts table.
struct ProdMatrixDetail: View {
    let card: ProdGlance.Card
    let now: Date

    /// Checks first, then the issues and alerts as a full-width block under
    /// them: a side column squeezed real Sentry titles to "<unkn…" in the
    /// 2026-10-03 live test.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            checks.frame(maxWidth: 300, alignment: .topLeading)
            issues
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, -8)
            if let pool = card.deployment?.pool {
                ProdAccountsTable(pool: pool, now: now, blind: card.stale)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 12)
        .padding(.bottom, 6)
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = card.status {
                Text(status).font(RailRowMetrics.metaFont).foregroundStyle(.orange).frame(height: 15)
            }
            ForEach(card.chips) { chip in
                let check = card.deployment?.checks.first { $0.id == chip.id }
                HStack {
                    Text(check?.title ?? chip.id).foregroundStyle(.tertiary)
                    if check?.page == true {
                        Image(systemName: "bell.fill").font(.system(size: 7)).foregroundStyle(.tertiary)
                            .help("pages the phone when it fails (page=\"emergency\")")
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        ProdToneDot(tone: chip.tone)
                        Text(check?.value ?? (chip.tone == .blind ? "no data" : "—"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(RailRowMetrics.metaFont)
                .lineLimit(1)
                .frame(height: 15)
            }
            if card.chips.isEmpty, card.status == nil {
                Text("no checks reported").font(RailRowMetrics.metaFont).foregroundStyle(.tertiary)
            }
        }
    }

    /// A stale card's cached alerts and issues read blind, never red: they
    /// may have resolved since Hlídač last answered.
    private var issues: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((card.deployment?.alerts ?? []).enumerated()), id: \.offset) { _, alert in
                issueLine(tone: card.stale ? .blind : alert.isCritical ? .red : .orange,
                          title: alert.summary.isEmpty ? alert.name : alert.summary,
                          sub: "firing · \(alert.severity)\(alert.emergency ? " · emergency" : "")",
                          meta: alert.activeAt.map { $0.shortAge(relativeTo: now) } ?? "",
                          url: alert.url)
            }
            ForEach(card.deployment?.sentry ?? []) { issue in
                issueLine(tone: card.stale ? .blind : issue.isNew ? .red : .orange,
                          title: issue.title,
                          sub: "sentry · \(issue.project) · env \(issue.environment) · \(issue.count)× · \(issue.users) users"
                              + (issue.isNew ? " · new" : ""),
                          meta: issue.lastSeen.shortAge(relativeTo: now),
                          url: issue.permalink)
            }
            logsLine
            if let links = card.deployment?.links, !links.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                        Button {
                            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(link.title, systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .help(link.url)
                    }
                    Spacer()
                }
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var logsLine: some View {
        HStack(spacing: 8) {
            Text("logs 24h").foregroundStyle(.tertiary)
            if let hours = card.hours, !hours.isEmpty {
                HourBars(stacks: hours.map(HourBars.Stack.init), height: 12)
            }
            Text(card.logsLine ?? (card.tone == .hollow ? "not shipped" : "—"))
                .foregroundStyle(.secondary)
            if let edge = card.edgeLine {
                Text("· \(edge)").foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(RailRowMetrics.metaFont)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func issueLine(tone: ProdGlance.Tone, title: String, sub: String, meta: String,
                           url: String?) -> some View
    {
        HStack(alignment: .top, spacing: 6) {
            ProdToneDot(tone: tone).padding(.top, 3.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(RailRowMetrics.titleFont).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub).font(RailRowMetrics.metaFont).foregroundStyle(.tertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(meta).font(RailRowMetrics.metaFont).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url, let target = URL(string: url) { NSWorkspace.shared.open(target) }
        }
        .help(url ?? title)
    }
}

/// eve's pool: the failover lane and one row per subscription account —
/// state, the 5h / 7d windows with the 90 % tick, what is left of Fable,
/// the cooldown countdown, the binding reset, turns and freshness.
struct ProdAccountsTable: View {
    let pool: HlidacDigest.Pool
    let now: Date
    /// The card is stale: rows and lane read blind (`ProdAccountRow.rows`).
    var blind = false

    /// Headings, two lines where a label is long. The columns themselves are
    /// sized by their content (`Grid`): real accounts carry longer ids and
    /// states than the fixture, and fixed widths truncated them live.
    private static let headings: [[String]] = [
        ["Account"], ["Pool"], ["State"], ["5h"], ["7d"], ["Fable", "left"], ["Cooldown"], ["Resets"],
        ["Turns", "24h"], ["As of"],
    ]
    private static let barWidth: CGFloat = 26
    /// An account id longer than this wraps onto a second line.
    private static let accountMaxWidth: CGFloat = 110

    var body: some View {
        let rows = ProdAccountRow.rows(pool, now: now, blind: blind)
        VStack(alignment: .leading, spacing: 0) {
            lane
            HStack(spacing: 6) {
                Kicker(text: "Accounts", count: rows.count)
                Spacer()
                Text("orange | = 90 % of a window")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 10)
            .padding(.bottom, 5)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                GridRow(alignment: .bottom) {
                    ForEach(Array(Self.headings.enumerated()), id: \.offset) { index, lines in
                        heading(lines, trailing: index >= 8)
                            .gridColumnAlignment(index >= 8 ? .trailing : .leading)
                    }
                }
                .padding(.bottom, 4)
                ForEach(rows) { row in
                    // A view outside a GridRow spans every column.
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                    accountRow(row)
                }
            }
        }
    }

    private func heading(_ lines: [String], trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            ForEach(lines, id: \.self) { line in
                Text(line.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// "Claude sub 1/2 → Codex sub 2/4 → OpenRouter $ · failovers 3 · paid 0".
    private var lane: some View {
        HStack(spacing: 7) {
            Text("LANE")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(.secondary)
            ForEach(Array(pool.pools.enumerated()), id: \.offset) { index, gateway in
                if index > 0 { Text("→").foregroundStyle(.tertiary) }
                HStack(spacing: 5) {
                    ProdToneDot(tone: ProdAccountRow.laneTone(usable: gateway.usable, total: gateway.total,
                                                              blind: blind))
                    Text("\(ProdAccountRow.poolName(gateway.gateway)) \(gateway.usable)/\(gateway.total)")
                }
            }
            Text("→").foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                ProdToneDot(tone: blind ? .blind : (pool.backupTurnsToday ?? 0) > 0 ? .orange : .hollow)
                Text("OpenRouter $")
            }
            .foregroundStyle(.tertiary)
            Spacer()
            Text([pool.failoversToday.map { "failovers \($0)" },
                  pool.backupTurnsToday.map { "paid turns \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }

    /// One account. Every cell keeps its whole text (`mono` is fixed-size);
    /// only the id may wrap, onto a second line. Stale rows dim cell by cell
    /// — a GridRow passes no modifier down to its cells.
    private func accountRow(_ row: ProdAccountRow) -> some View {
        let dim = row.stale ? 0.42 : 1
        return GridRow(alignment: .center) {
            HStack(alignment: .top, spacing: 5) {
                ProdToneDot(tone: row.tone).padding(.top, 3)
                Text(row.account).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Self.accountMaxWidth, alignment: .leading)
            .padding(.vertical, 5)
            .opacity(dim)
            .help([row.id, row.stale ? "numbers are stale or the account is logged out" : nil]
                .compactMap { $0 }.joined(separator: " — "))
            Text(row.pool).font(RailRowMetrics.titleFont).foregroundStyle(.secondary).lineLimit(1)
                .fixedSize().opacity(dim)
            mono(row.state, row.tone == .green ? .green : row.tone.color).opacity(dim)
            usedBar(row.fiveHour).opacity(dim)
            usedBar(row.sevenDay).opacity(dim)
            leftBar(row.fableLeftRatio).opacity(dim)
            cooldown(row).opacity(dim)
            mono(row.resets ?? "—", row.resets == nil ? .gray : .secondary).opacity(dim)
                .help(row.resetsAt.map { "resets \($0)" } ?? "")
            mono("\(row.turns24h)", .primary).opacity(dim)
            mono(row.asOf ?? "—", .gray).opacity(dim)
        }
    }

    /// "back 21:14" over "33m": both halves always whole.
    @ViewBuilder
    private func cooldown(_ row: ProdAccountRow) -> some View {
        if let at = row.cooldownAt {
            VStack(alignment: .leading, spacing: 1) {
                mono(at, .orange)
                if let left = row.cooldownIn { mono(left, .orange).opacity(0.75) }
            }
        } else {
            mono("—", .gray)
        }
    }

    /// Mono cell text, always whole: the grid column grows to fit it.
    private func mono(_ text: String, _ tone: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(tone)
            .lineLimit(1)
            .fixedSize()
    }

    /// A used window: the bar fills to `ratio`, turns orange past the 90 %
    /// tick, and carries its percentage beside it.
    @ViewBuilder
    private func usedBar(_ ratio: Double?) -> some View {
        if let ratio {
            bar(fill: ratio, label: ratio, alarming: ratio >= ProdAccountRow.tick, tick: ProdAccountRow.tick)
        } else {
            mono("—", .gray)
        }
    }

    /// What is LEFT of the Fable week: alarming once less than 10 % remains.
    @ViewBuilder
    private func leftBar(_ ratio: Double?) -> some View {
        if let ratio {
            bar(fill: ratio, label: ratio, alarming: ratio <= 1 - ProdAccountRow.tick, tick: 1 - ProdAccountRow.tick)
        } else {
            mono("—", .gray)
        }
    }

    private func bar(fill: Double, label: Double, alarming: Bool, tick: Double) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(alarming ? Color.orange.opacity(0.8) : Color.white.opacity(0.45))
                    .frame(width: Self.barWidth * min(max(fill, 0), 1))
                Rectangle().fill(Color.orange).frame(width: 1, height: 8)
                    .offset(x: Self.barWidth * tick)
            }
            .frame(width: Self.barWidth, height: 4)
            mono("\(Int((label * 100).rounded()))%", alarming ? .orange : .secondary)
        }
    }
}
