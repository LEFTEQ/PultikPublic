import AppKit
import SwiftUI

/// The Prod module's list (copilot shell WP7; decision D4 B, mockup card
/// 52046): one matrix row per deployment, columns derived from check ids
/// (`ProdMatrix`), then the estate's unclaimed firing rules and the apps
/// shelf's latest releases (Shipping inside Prod, D9). A row opens its
/// deployment's detail beside the list; the filter narrows the matrix
/// (`.h sk` → Booking SK).
struct ProdMatrixPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }

    /// Fixed grid inside the page's 648pt. Every column is at least as wide
    /// as its full heading at 8.5pt mono (≈5.7pt a character with the
    /// kicker kerning), and the values are formatted compact to fit
    /// (`ProdMatrix.compact`): a heading or value is never ellipsized.
    static let nameWidth: CGFloat = 150
    static let widths: [ProdMatrix.Column: CGFloat] = [
        .probe: 66, .app: 60, .pool: 70, .logs: 66, .sentry: 52, .firing: 50, .backup: 46,
    ]
    static let columnSpacing: CGFloat = 6

    private var glance: ProdGlance { store.prodGlance }

    /// The rows the filter matches by title, key or project; all of them
    /// when it is empty.
    private func rows(_ glance: ProdGlance) -> [ProdMatrix.Row] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        let rows = ProdMatrix.rows(glance)
        guard !text.isEmpty else { return rows }
        let projects = Dictionary(glance.cards.map { ($0.key, $0.deployment?.project ?? "") }, uniquingKeysWith: { a, _ in a })
        return rows.filter { row in
            [row.title, row.key, projects[row.key] ?? ""].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    /// The shelf's releases the filter matches; all of them when it is empty.
    private var releases: [ShelfRelease] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return store.shelfReleases }
        return store.shelfReleases.filter { release in
            ([release.name, release.version] + release.builds.map(\.platform))
                .contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    var body: some View {
        let glance = glance
        let rows = rows(glance)
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 0) {
                header
                deploymentsHeading(glance, count: rows.count)
                columnHeader
                if rows.isEmpty {
                    RailNote(store.prodDigest == nil ? "Waiting for Hlídač — no digest yet"
                        : filter.isEmpty ? "No deployments configured" : "No deployment matches “\(filter)”")
                }
                ForEach(rows) { row in
                    let id = Self.objectID(row.key)
                    Button { onOpen(id) } label: { rowView(row) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.spoken)
                        .accessibilityHint("Opens the deployment's checks, issues, alerts and release")
                        .background { RowBackground(selected: selectedID == id).padding(.horizontal, -6) }
                        .id(id)
                }
                estateFiring
                releasesSection
                legend
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .task { await store.refreshShelf() }
    }

    /// The apps shelf's latest releases, one row per version; hidden while
    /// the shelf has never answered.
    @ViewBuilder
    private var releasesSection: some View {
        let releases = releases
        if !releases.isEmpty {
            let now = Date()
            let stale = store.shelfFetchedAt.map { now.timeIntervalSince($0) > ShelfRelease.staleAfter } ?? false
            HStack(spacing: 6) {
                Kicker(text: "Releases", count: releases.count)
                Spacer()
                Text(stale ? "apps shelf · as of \(store.shelfFetchedAt.map { PultikFormat.clock($0) } ?? "")" : "apps shelf")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            ForEach(releases) { release in
                let id = Self.objectID(release)
                ListRow(title: "\(release.name) \(release.version)", id: Self.platforms(release),
                        meta: Text(verbatim: Self.releaseMeta(release, now: now)), selected: selectedID == id,
                        action: { onOpen(id) }) {
                    ProjectGlyph(project: release.name.lowercased(), symbol: "shippingbox.fill", size: 18)
                }
                .padding(.horizontal, -6)
                .opacity(stale ? 0.6 : 1)
                .id(id)
            }
        }
    }

    static func objectID(_ release: ShelfRelease) -> String { "release:\(release.id)" }

    /// `macos`, or `6 platforms` when a version shipped several builds.
    static func platforms(_ release: ShelfRelease) -> String {
        release.builds.count == 1 ? release.builds[0].platform : "\(release.builds.count) platforms"
    }

    static func releaseMeta(_ release: ShelfRelease, now: Date) -> String {
        [release.channel, PultikFormat.ago(release.publishedAt, now: now), release.commit.map { String($0.prefix(7)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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

    private func rowView(_ row: ProdMatrix.Row) -> some View {
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
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .contentShape(Rectangle())
        .help("Open \(row.title)")
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
            Text("↵ opens a deployment · .h <name> narrows")
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

/// One object per deployment row, in matrix order, then one per release.
/// A deployment's detail is `ProdDeploymentDetail` (checks, issues, alerts,
/// logs, its release line, eve's accounts); a release's is its builds and
/// notes. Prod is never green from a stale digest: a stale card reads
/// `stale`, never `ok`.
extension ProdMatrixPage: ModulePage {
    static func objectID(_ key: String) -> String { "deployment:\(key)" }

    var listWidth: CGFloat { 640 }
    /// The fixed grid (`nameWidth` + `widths` + spacing) and its padding.
    var minListWidth: CGFloat { 636 }

    var objects: [ModuleObject] {
        let glance = glance
        return rows(glance).map { row in
            let card = glance.cards.first { $0.key == row.key }
            var facts: [ModuleObject.Fact] = []
            if let deployment = card?.deployment {
                facts.append(.init(label: "project", value: deployment.project))
                facts.append(.init(label: "tier", value: deployment.tier))
                if deployment.emergency { facts.append(.init(label: "pages", value: "emergency checks page the phone")) }
            }
            if let status = card?.status { facts.append(.init(label: "status", value: status)) }
            if let logs = card?.logsLine { facts.append(.init(label: "logs 24h", value: logs)) }
            if let edge = card?.edgeLine { facts.append(.init(label: "edge", value: edge)) }
            let failing = card?.chips.filter { $0.tone != .green }.map { ProdDeploymentDetail.chip($0) } ?? []
            return ModuleObject(id: Self.objectID(row.key), title: row.title, label: row.key,
                                status: Self.status(row.tone, stale: card?.stale ?? false),
                                meta: row.subtitle, symbol: "waveform.path.ecg",
                                project: card?.deployment?.project,
                                url: card?.deployment?.links.first.flatMap { URL(string: $0.url) },
                                context: failing, facts: facts)
        } + releaseObjects
    }

    private var releaseObjects: [ModuleObject] {
        let now = Date()
        return releases.map { release in
            var facts = [ModuleObject.Fact(label: "version", value: release.version),
                         .init(label: "channel", value: release.channel),
                         .init(label: "published", value: PultikFormat.ago(release.publishedAt, now: now))]
            if let commit = release.commit { facts.append(.init(label: "commit", value: commit)) }
            facts.append(.init(label: "releases", value: "\(release.history) on the shelf"))
            return ModuleObject(id: Self.objectID(release), title: "\(release.name) \(release.version)",
                                label: Self.platforms(release), status: Chip(release.channel, .neutral),
                                meta: Self.releaseMeta(release, now: now), symbol: "shippingbox.fill",
                                project: release.name.lowercased(), url: release.pageURL, facts: facts)
        }
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let card = glance.cards.first(where: { Self.objectID($0.key) == object.id }) {
            ProdDeploymentDetail(store: store, card: card)
        } else if let release = store.shelfReleases.first(where: { Self.objectID($0) == object.id }) {
            ShelfReleaseDetail(release: release)
        }
    }

    private static func status(_ tone: ProdGlance.Tone, stale: Bool) -> Chip {
        if stale { return Chip("stale", .warn) }
        return switch tone {
        case .green: Chip("ok", .ok)
        case .orange: Chip("degraded", .warn)
        case .red: Chip("down", .danger)
        case .blind: Chip("blind", .warn)
        case .hollow: Chip("not monitored", .dashed)
        }
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
