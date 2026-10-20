import SwiftUI

// The Toolkit module (docs/specs/2026-10-20-toolkit-module-decisions.md): the
// installed release's catalog of bundled workflows, skills and guard rules,
// and how they were used Today, over 7 or over 30 days. Read-only
// (vitr:dec/bctezf0): no row launches, toggles or indexes anything. The
// counts are what Toolkit measures (vitr:dec/gqzr90g) — named skill calls,
// guard deny receipts, and one generic total of Workflow-tool launches never
// attributed to a script — and a source that did not answer reads unknown,
// never zero.

/// The four views over `store.toolkit`, in `store.toolkitPeriod`'s window.
struct ToolkitPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    let view: ModuleView
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }

    /// One drawn row: a catalog item with its activity, or a measured name
    /// the catalog does not hold.
    enum Entry: Identifiable {
        case item(ToolkitDashboard.Row)
        case unlisted(ToolkitDashboard.Unlisted)

        var id: String {
            switch self {
            case let .item(row): row.id
            case let .unlisted(name): name.id
            }
        }
    }

    struct ListSection: Identifiable {
        let title: String
        let entries: [Entry]
        /// The one line drawn when it has no rows; nil hides the section.
        var empty: String?
        var id: String { title }
    }

    private var dashboard: ToolkitDashboard? { store.toolkit.dashboard }
    private var period: ToolkitDashboard.Period { store.toolkitPeriod }

    var sections: [ListSection] {
        guard let dashboard else { return [] }
        let period = period
        let window = dashboard.window(period)
        func rows(_ kind: ToolkitDashboard.Item.Kind) -> [Entry] {
            dashboard.rows(kind, period: period, filter: filter).map(Entry.item)
        }
        switch view {
        case .workflows:
            return [ListSection(title: "Workflows", entries: rows(.workflow), empty: noMatch("workflows"))]
        case .skills:
            return [ListSection(title: "Skills", entries: rows(.skill), empty: noMatch("skills"))]
        case .guards:
            return [ListSection(title: "Guard rules", entries: rows(.guard), empty: noMatch("guard rules"))]
        default:
            let quiet = "None in \(period.title.lowercased())"
            return [
                ListSection(title: "Most used skills", entries: dashboard.top(.skill, period: period, filter: filter).map(Entry.item),
                        empty: window?.skillsAvailable == true ? quiet : "Skill calls unavailable"),
                ListSection(title: "Most guard blocks", entries: dashboard.top(.guard, period: period, filter: filter).map(Entry.item),
                        empty: window?.guardsAvailable == true ? quiet : "Guard blocks unavailable"),
                ListSection(title: "Measured, not in the catalog",
                        entries: dashboard.unlisted(period: period, filter: filter).map(Entry.unlisted)),
            ]
        }
    }

    private func noMatch(_ noun: String) -> String {
        filter.trimmingCharacters(in: .whitespaces).isEmpty ? "No \(noun) in this catalog" : "No \(noun) match"
    }

    var body: some View {
        let held = store.toolkit
        let freshness = held.freshness()
        let sections = sections
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header(freshness)
                if let dashboard {
                    VStack(alignment: .leading, spacing: 2) {
                        if view == .overview {
                            ToolkitOverviewTiles(dashboard: dashboard, period: period)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                        } else if let line = coverage(dashboard) {
                            Text(line).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
                                .padding(.horizontal, 8).padding(.bottom, 4)
                        }
                        ForEach(sections) { section in
                            if !section.entries.isEmpty || section.empty != nil {
                                Kicker(text: section.title, count: section.entries.count)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 7)
                                    .padding(.bottom, 2)
                                if section.entries.isEmpty, let empty = section.empty {
                                    Text(empty).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                }
                                ForEach(section.entries) { entry in
                                    row(entry, dashboard: dashboard)
                                }
                            }
                        }
                    }
                    // DESIGN.md §7: a held answer that is not current draws dimmed under its "as of".
                    .opacity(freshness.isCurrent ? 1 : 0.6)
                } else if case .loading = freshness {
                    Text("Reading toolkit catalog dashboard…").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    // MARK: Header

    private func header(_ freshness: ToolkitHeld.Freshness) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text("Toolkit").font(Theme.Typo.title)
                ViewBar(views: PanelModule.toolkit.views, selected: view, onSelect: onView)
                Spacer(minLength: 4)
            }
            HStack(alignment: .center, spacing: 10) {
                Picker("Window", selection: Binding(get: { store.toolkitPeriod }, set: { store.toolkitPeriod = $0 })) {
                    ForEach(ToolkitDashboard.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Local calendar days, through the moment toolkit generated the dashboard")
                if let summary = summary {
                    Text(summary).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            freshnessLine(freshness)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// The view's own count line.
    private var summary: String? {
        guard let dashboard else { return nil }
        switch view {
        case .workflows:
            return "\(dashboard.items(.workflow).count) bundled workflows"
        case .skills:
            return "\(dashboard.items(.skill).count) skills"
        case .guards:
            return "\(dashboard.items(.guard).count) guard rules"
        default:
            return nil
        }
    }

    /// Where the data came from and how old it is: the release's catalog,
    /// the dashboard's generation and the transcript index. Cached and
    /// failed reads say so; neither is drawn as current.
    @ViewBuilder
    private func freshnessLine(_ freshness: ToolkitHeld.Freshness) -> some View {
        let now = Date()
        // Provenance on its own line, whatever the read state: a held dashboard
        // keeps naming its catalog, its index time and when it was generated.
        if let dashboard {
            // nil proves only that the index time is unknown, not that no index ran.
            let index = dashboard.indexedAt.map { "transcripts indexed \(PultikFormat.ago($0, now: now))" }
                ?? "transcript index time unavailable"
            caption(["toolkit \(dashboard.release) catalog", index,
                     "generated \(Self.moment(dashboard.generatedAt, now: now))"], tone: Theme.ink3)
        }
        switch freshness {
        case .loading, .live:
            EmptyView()
        case let .stale(at):
            caption([PultikFormat.asOf(at)], tone: Theme.ink3)
        case let .cached(at):
            caption(["cached", PultikFormat.asOf(at)], tone: Theme.ink3)
        case let .failed(failure, since):
            caption([failure.message, since.map { "showing \(PultikFormat.asOf($0))" }], tone: Theme.warn)
        }
    }

    /// `14:05` today, `Oct 18 14:05` another day: a held dashboard can be old.
    static func moment(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? PultikFormat.clock(date) : "\(PultikFormat.date(date, now: now)) \(PultikFormat.clock(date))"
    }

    private func caption(_ parts: [String?], tone: Color) -> some View {
        Text(parts.compactMap { $0 }.joined(separator: " · "))
            .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(tone).lineLimit(2)
            .textSelection(.enabled)
    }

    /// A list view's coverage in one line: what its counts are, honestly.
    private func coverage(_ dashboard: ToolkitDashboard) -> String? {
        let window = dashboard.window(period)
        let span = period.title.lowercased()
        switch view {
        case .workflows:
            // Launches come from the same transcript index as skill calls: partial with it.
            guard let window, let calls = window.workflowCalls else {
                return "Workflow launches unavailable — launches are not attributed to a bundled workflow"
            }
            let partial = window.skillsPartial ? " · partial, \(Self.pending(window)) not indexed yet" : ""
            return "\(Self.launches(window, calls: calls)) Workflow-tool launches in \(span), every script counted\(partial)"
                + " — launches are not attributed to a bundled workflow"
        case .skills:
            guard let window, window.skillsAvailable else { return "Skill calls unavailable — counts unknown" }
            var line = window.skillCalls.map { "\($0) skill calls in \(span)" } ?? "skill calls in \(span)"
            if let split = Self.split(dashboard, .skill, period: period) {
                line += " · \(split)"
            }
            return window.skillsPartial ? "\(line) · partial, \(Self.pending(window)) not indexed yet" : line
        case .guards:
            guard let window, window.guardsAvailable else { return "Guard blocks unavailable — counts unknown" }
            var line = window.guardBlocks.map { "\($0) deny receipts in \(span)" } ?? "deny receipts in \(span)"
            if let split = Self.split(dashboard, .guard, period: period) {
                line += " · \(split)"
            }
            line += " · a block is no failure"
            return window.guardsPartial ? "\(line) · partial" : line
        default:
            return nil
        }
    }

    /// `29 catalog · 9 other`: a measured total split into this release's
    /// named items and the rest, which stays in the total
    /// (`ToolkitDashboard.otherTotal`); nil while either is unknown.
    static func split(_ dashboard: ToolkitDashboard, _ kind: ToolkitDashboard.Item.Kind,
                      period: ToolkitDashboard.Period) -> String? {
        guard let catalog = dashboard.catalogTotal(kind, period: period),
              let other = dashboard.otherTotal(kind, period: period) else { return nil }
        return "\(catalog) catalog · \(other) other"
    }

    /// `11`, or `11+` while the transcript index is behind: a floor.
    static func launches(_ window: ToolkitDashboard.Window, calls: Int) -> String {
        window.skillsPartial ? "\(calls)+" : "\(calls)"
    }

    static func pending(_ window: ToolkitDashboard.Window) -> String {
        window.pendingBytes > 0 ? PultikFormat.size(Double(window.pendingBytes)) : "some transcripts"
    }

    // MARK: Rows

    private func row(_ entry: Entry, dashboard: ToolkitDashboard) -> some View {
        let id = entry.id
        let shape = Self.shape(entry, release: dashboard.release)
        return ListRow(title: shape.title, id: shape.label, meta: shape.meta.map { Text($0) },
                       selected: selectedID == id, action: { onOpen(id) }) {
            Image(systemName: shape.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 16)
        } trailing: {
            HStack(spacing: 6) {
                if case let .item(row) = entry, let status = row.item.status, status != "stable" {
                    Chip(status)
                }
                ToolkitMeasureFigure(measure: Self.measure(entry))
            }
        }
        .id(id)
    }

    static func measure(_ entry: Entry) -> ToolkitDashboard.Measure {
        switch entry {
        case let .item(row): row.measure
        case let .unlisted(name): name.measure
        }
    }

    struct Shape {
        let title: String
        let label: String?
        let meta: String?
        let symbol: String
    }

    static func symbol(_ kind: ToolkitDashboard.Item.Kind?) -> String {
        switch kind {
        case .skill: "wand.and.stars"
        case .workflow: "flowchart"
        case .guard: "shield.lefthalf.filled"
        case nil: "questionmark.square.dashed"
        }
    }

    /// A row's title, the label leading its meta line (never ellipsized) and the rest.
    static func shape(_ entry: Entry, release: String) -> Shape {
        switch entry {
        case let .item(row):
            let item = row.item
            switch item.itemKind {
            case .workflow:
                return Shape(title: item.name, label: item.owner, meta: item.description, symbol: symbol(.workflow))
            case .guard:
                let meta = [item.family, item.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return Shape(title: item.name, label: item.event, meta: meta.isEmpty ? nil : meta, symbol: symbol(.guard))
            case .skill, nil:
                return Shape(title: item.name, label: item.family, meta: item.description, symbol: symbol(item.itemKind))
            }
        case let .unlisted(name):
            return Shape(title: name.name, label: name.kind?.rawValue,
                         meta: "not in toolkit \(release)'s catalog", symbol: symbol(nil))
        }
    }
}

extension ToolkitPage: ModulePage {
    var listWidth: CGFloat { 520 }

    var objects: [ModuleObject] {
        guard let dashboard else { return [] }
        let period = period
        return sections.flatMap(\.entries).map { entry -> ModuleObject in
            let shape = Self.shape(entry, release: dashboard.release)
            switch entry {
            case let .item(row):
                let item = row.item
                var facts: [ModuleObject.Fact] = [.init(label: "id", value: item.id), .init(label: "kind", value: item.kind)]
                for (label, value) in [("owner", item.owner), ("family", item.family), ("event", item.event),
                                       ("status", item.status), ("source", item.source)] {
                    if let value, !value.isEmpty { facts.append(.init(label: label, value: value)) }
                }
                facts.append(.init(label: "catalog", value: "toolkit \(dashboard.release)"))
                return ModuleObject(id: row.id, title: item.name, label: item.itemKind?.rawValue ?? item.kind,
                                    status: Self.chip(row.measure, period: period), meta: item.description,
                                    symbol: shape.symbol, project: "toolkit", facts: facts)
            case let .unlisted(name):
                return ModuleObject(id: name.id, title: name.name, label: name.kind?.rawValue,
                                    status: Self.chip(name.measure, period: period),
                                    meta: shape.meta, symbol: shape.symbol, project: "toolkit",
                                    facts: [.init(label: "id", value: name.id),
                                            .init(label: "catalog", value: "toolkit \(dashboard.release)")])
            }
        }
    }

    /// The detail header's chip: the count in the window, or why there is none.
    static func chip(_ measure: ToolkitDashboard.Measure, period: ToolkitDashboard.Period) -> Chip? {
        let span = period.title.lowercased()
        switch measure {
        case let .count(count, partial):
            return partial ? Chip("\(count)+ · \(span) · partial", .dashed) : Chip("\(count) · \(span)")
        case .unavailable:
            return Chip("unavailable", .dashed)
        case .notMeasured:
            return nil
        }
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let dashboard {
            ToolkitDetail(dashboard: dashboard, id: object.id, period: period)
        }
    }
}

/// A row's trailing count in a fixed column so digits stack: unknown reads
/// "—", a partial count is a floor (`12+`), an unmeasured item draws none.
struct ToolkitMeasureFigure: View {
    let measure: ToolkitDashboard.Measure

    var body: some View {
        Group {
            switch measure {
            case let .count(count, partial):
                Text(verbatim: partial ? "\(count)+" : "\(count)")
                    .foregroundStyle(count == 0 ? Theme.ink3 : partial ? Theme.ink2 : Theme.ink)
                    .help(partial ? "Partial: its source is incomplete, so this is a floor" : "")
            case .unavailable:
                Text(verbatim: "—").foregroundStyle(Theme.ink3).help("Source unavailable: unknown, not zero")
            case .notMeasured:
                Text(verbatim: "")
            }
        }
        .font(Theme.Typo.figure)
        .frame(width: 52, alignment: .trailing)
    }
}

// MARK: - Overview

/// Overview's head (DESIGN.md §5: every tile leads with data): the window's
/// three measured totals with their coverage, and the catalog's size.
struct ToolkitOverviewTiles: View {
    let dashboard: ToolkitDashboard
    let period: ToolkitDashboard.Period

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                activity.frame(minWidth: 460)
                catalog.frame(minWidth: 300)
            }
            VStack(alignment: .leading, spacing: 10) {
                activity
                catalog
            }
        }
    }

    private var window: ToolkitDashboard.Window? { dashboard.window(period) }

    private var activity: some View {
        Tile(kicker: "Activity · \(period.title)", caption: window.map(Self.span)) {
            if let window {
                StatStrip(cells: Self.cells(dashboard, window: window, period: period))
                let gaps = Self.gaps(window)
                if !gaps.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(gaps, id: \.self) { Chip($0, .dashed) }
                    }
                }
            } else {
                Text("toolkit sent no \(period.title.lowercased()) window").font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
            }
            // The provider's named coverage gaps, verbatim: a shape and a word, not colour alone.
            ForEach(dashboard.issues, id: \.self) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                    Text(issue).foregroundStyle(Theme.ink2).lineLimit(2)
                }
                .font(Theme.Typo.meta)
            }
        }
    }

    private var catalog: some View {
        Tile(kicker: "Catalog", caption: "toolkit \(dashboard.release) · not what is enabled") {
            StatStrip(cells: [
                .init(label: "Workflows", value: "\(dashboard.items(.workflow).count)"),
                .init(label: "Skills", value: "\(dashboard.items(.skill).count)"),
                .init(label: "Guard rules", value: "\(dashboard.items(.guard).count)"),
            ])
        }
    }

    /// `Oct 14 – 14:05`: the window's first day through the generation time.
    static func span(_ window: ToolkitDashboard.Window) -> String {
        "\(PultikFormat.date(window.from, now: window.to)) – \(PultikFormat.clock(window.to))"
    }

    /// Skill calls split into the catalog's share and the rest; launches are
    /// every Workflow-tool call; blocks are deny receipts, never failures.
    static func cells(_ dashboard: ToolkitDashboard, window: ToolkitDashboard.Window,
                      period: ToolkitDashboard.Period) -> [StatStrip.Cell] {
        func value(_ count: Int?, partial: Bool) -> String {
            count.map { partial ? "\($0)+" : "\($0)" } ?? "—"
        }
        func tone(_ count: Int?, partial: Bool) -> Color {
            count == nil ? Theme.ink3 : partial ? Theme.ink2 : Theme.ink
        }
        let skillCaption = window.skillCalls == nil ? "unavailable"
            : ToolkitPage.split(dashboard, .skill, period: period) ?? "catalog share unknown"
        let guardCaption = window.guardBlocks == nil ? "unavailable"
            : ToolkitPage.split(dashboard, .guard, period: period) ?? "deny receipts"
        return [
            .init(label: "Skill calls", value: value(window.skillCalls, partial: window.skillsPartial),
                  tone: tone(window.skillCalls, partial: window.skillsPartial), caption: skillCaption),
            .init(label: "Workflow launches", value: value(window.workflowCalls, partial: window.skillsPartial),
                  tone: tone(window.workflowCalls, partial: window.skillsPartial),
                  caption: window.workflowCalls == nil ? "unavailable" : "every script, not per workflow"),
            .init(label: "Guard blocks", value: value(window.guardBlocks, partial: window.guardsPartial),
                  tone: tone(window.guardBlocks, partial: window.guardsPartial),
                  caption: guardCaption),
        ]
    }

    /// Each named coverage gap, as a dashed chip (DESIGN.md §7, partial).
    static func gaps(_ window: ToolkitDashboard.Window) -> [String] {
        var gaps: [String] = []
        if !window.skillsAvailable {
            gaps.append("transcript index unavailable")
        } else if window.skillsPartial {
            gaps.append("\(ToolkitPage.pending(window)) not indexed")
        }
        if !window.guardsAvailable {
            gaps.append("guard ledger unavailable")
        } else {
            if window.guardMalformed > 0 { gaps.append("\(window.guardMalformed) unreadable receipts") }
            // Retention, a read cut short or an unproven recording start: the issues name which.
            if !window.guardsComplete { gaps.append("guard ledger partial") }
        }
        return gaps
    }
}

// MARK: - Detail

/// An object's detail under its header: what it is, then its activity in
/// every window, each honest about its coverage.
struct ToolkitDetail: View {
    let dashboard: ToolkitDashboard
    let id: String
    let period: ToolkitDashboard.Period

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = dashboard.item(id) {
                if let description = item.description, !description.isEmpty {
                    Tile(kicker: "About") {
                        Text(description).font(Theme.Typo.body).foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                    }
                }
                switch item.itemKind {
                case .workflow:
                    workflowLaunches
                case .skill, .guard:
                    Tile(kicker: item.itemKind == .skill ? "Skill calls" : "Blocks", caption: "by window") {
                        StatStrip(cells: ToolkitDashboard.Period.allCases.map { cell(dashboard.measure(item, in: dashboard.window($0)), $0) })
                        if item.itemKind == .guard {
                            Text("A block is one deny receipt: not a count of the calls this rule evaluated, and not a failure.")
                                .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        }
                    }
                case nil:
                    EmptyView()
                }
            } else if dashboard.windows.contains(where: { window in window.activity.contains { $0.id == id } }) {
                let name = ToolkitDashboard.Unlisted(id: id, measure: .notMeasured)
                Tile(kicker: "Not in the catalog") {
                    Text("Measured under this name, but toolkit \(dashboard.release)'s catalog has no such \(name.kind?.rawValue ?? "item"): a plugin's or a project's own, or one the catalog retired. It counts toward the window's total, never toward the catalog's share.")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                    StatStrip(cells: ToolkitDashboard.Period.allCases.map { period in
                        cell(dashboard.measure(unlisted: id, in: dashboard.window(period)), period)
                    })
                }
            }
        }
    }

    private var workflowLaunches: some View {
        let window = dashboard.window(period)
        let total = window.flatMap { window in
            window.workflowCalls.map { calls in
                ToolkitPage.launches(window, calls: calls) + (window.skillsPartial ? ", partial" : "")
            }
        }
        return Tile(kicker: "Launches", caption: "not measured per workflow") {
            Text(total.map { "Every Workflow-tool call is counted — \($0) in \(period.title.lowercased()) — but none is attributed to a bundled script, so this workflow's own launches are unknown." }
                ?? "Workflow launches are unavailable, and none is ever attributed to a bundled script.")
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
        }
    }

    private func cell(_ measure: ToolkitDashboard.Measure, _ period: ToolkitDashboard.Period) -> StatStrip.Cell {
        switch measure {
        case let .count(count, partial):
            .init(label: period.title, value: partial ? "\(count)+" : "\(count)", tone: partial ? Theme.ink2 : Theme.ink,
                  caption: partial ? "partial" : nil)
        case .unavailable:
            .init(label: period.title, value: "—", tone: Theme.ink3, caption: "unavailable")
        case .notMeasured:
            .init(label: period.title, value: "—", tone: Theme.ink3, caption: "not measured")
        }
    }
}
