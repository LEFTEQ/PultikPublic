import SwiftUI

/// The Devbox module's list (spec 2026-09-23 D8 B, WP8): every metric of D4
/// on one strip with the stale clear beside the title, then one row per
/// workspace grouped running · parked, held ones pinned in place. Verbs
/// appear on the hovered or selected row, floating over its trailing
/// columns; a click selects the row and opens its per-app detail beside the
/// list. `filter` matches name, project or branch.
struct DevboxPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }

    @State private var clearing: DevboxWorkspace?

    private var workspaces: [DevboxWorkspace] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.devboxWorkspaces }
        return store.devboxWorkspaces.filter { workspace in
            [workspace.name, workspace.project ?? "", workspace.branch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                header
                if let summary = store.devboxSummary {
                    metricStrip(DevboxGlance(summary: summary, workspaces: store.devboxWorkspaces))
                }
                let rows = workspaces
                if store.devboxSummary == nil, store.devboxWorkspaces.isEmpty {
                    note("devbox unreachable")
                } else if rows.isEmpty {
                    note(filter.trimmingCharacters(in: .whitespaces).isEmpty ? "no workspaces" : "no workspace matches")
                } else {
                    columnHeader
                    // Held is a pin on the row, never a group of its own:
                    // Hold / Unhold must not move the row out from under the
                    // pointer (.claude/memory/notes/in-place-undo-row-stability.md).
                    group("Running", Self.running(rows))
                    group("Parked", Self.parked(rows))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .popover(item: $clearing) { workspace in
            DevboxClearPopover(workspace: workspace, store: store) { clearing = nil }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            guard note.userInfo?["cmd"] as? String == "clear-preview", let name = note.userInfo?["text"] as? String else { return }
            clearing = store.devboxWorkspaces.first { $0.name == name }
            // An explicitly supplied disposable source exercises the same
            // native flow without inventing a runtime on a live guest.
            if name == "clear-fixture", let path = ProcessInfo.processInfo.environment["PULTIK_CLEAR_FIXTURE_PATH"] {
                clearing = DevboxWorkspace(name: name, project: "pultik", branch: "qa-clear", portBase: nil,
                                           created: nil, apps: [], stats: [], memoryBytes: 0, cpuPercent: 0,
                                           declaredSources: [], state: "parked", macPath: path)
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Devbox")
                .font(Theme.Typo.title)
            Text("workspaces on the box — running first")
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.ink3)
            Spacer()
            if let fetchedAt = store.devboxFetchedAt {
                Text("as of \(PultikFormat.clock(fetchedAt))")
                    .font(Theme.Typo.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink3)
                    .help("When the box generated this snapshot")
            }
            DevboxClearStale(store: store)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// All eight metrics of D4: the widget's three gauges at page width, then
    /// pressure, swap, load, port slots and held — orange where the widget
    /// raises its alert line.
    private func metricStrip(_ glance: DevboxGlance) -> some View {
        let alerting = Set(glance.alerts.map(\.metric))
        return VStack(alignment: .leading, spacing: 10) {
            if let box = glance.box {
                Text(box.title)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .help("Every figure on this strip is box \(box.name)'s own — the other boxes are the lines below it")
            }
            HStack(alignment: .top, spacing: 18) {
                MeterBar(label: "CPU · \(glance.cores) cores", value: glance.cpuText,
                         fraction: glance.cpuFraction ?? 0)
                MeterBar(label: "RAM · floor \(DevboxGlance.compact(glance.floorBytes))G", value: glance.ramText,
                         fraction: glance.memoryFraction ?? 0, floor: glance.floorTick)
                MeterBar(label: "SSD", value: glance.ssdText, fraction: glance.diskFraction ?? 0)
            }
            HStack(spacing: 22) {
                stripCell("pressure", String(format: "%.1f%%", glance.pressurePercent),
                          alert: alerting.contains(.pressure),
                          help: "Memory pressure (PSI some, avg10) — the time tasks stalled waiting for memory")
                stripCell("swap", glance.swapUsedBytes > 0 ? "\(DevboxGlance.compact(glance.swapUsedBytes))G" : "0",
                          alert: alerting.contains(.swap))
                stripCell("load", glance.loadPerCore.map { String(format: "%.2f/core", $0) }
                    ?? String(format: "%.2f", glance.load1),
                    alert: alerting.contains(.load),
                    help: String(format: "load1 %.2f over %d cores", glance.load1, glance.cores))
                stripCell("port slots", slotsText(glance), alert: alerting.contains(.slots))
                stripCell("held", "\(glance.held)", alert: false,
                          help: "Workspaces exempt from the park sweep")
                stripCell("stale", "\(glance.stale)", alert: glance.stale > 0,
                          help: "Parked for more than 7 days")
            }
            // Never a sum (2026-10-14): the figures above are one box's own,
            // and every other box — draining, silent, the portal guest — is
            // a line of its own.
            if !glance.boxes.isEmpty {
                HStack(spacing: 22) {
                    ForEach(glance.boxes, id: \.name) { share in
                        let count = glance.workspacesByBox[share.name] ?? 0
                        stripCell(share.title, share.figure(workspaces: count), alert: share.isAlerting,
                                  help: share.help(workspaces: count, primary: glance.primaryBox))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .padding(.bottom, 6)
    }

    private func stripCell(_ label: String, _ value: String, alert: Bool, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(alert ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func slotsText(_ glance: DevboxGlance) -> String {
        guard let used = glance.slotsUsed, let total = glance.slotsTotal else { return "—" }
        return "\(used)/\(total)"
    }

    private var columnHeader: some View {
        HStack(spacing: DevboxColumn.spacing) {
            Text("WORKSPACE").frame(minWidth: DevboxColumn.name, maxWidth: .infinity, alignment: .leading)
            Text("PROJECT · BRANCH").frame(width: DevboxColumn.identity, alignment: .leading)
            Text("APPS").frame(width: DevboxColumn.apps, alignment: .trailing)
            Text("MEM").frame(width: DevboxColumn.memory, alignment: .trailing)
            Text("PEAK").frame(width: DevboxColumn.memory, alignment: .trailing)
            Text("AGE").frame(width: DevboxColumn.age, alignment: .trailing)
                .help("Running: since created · parked: since parked")
        }
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [DevboxWorkspace]) -> some View {
        if !rows.isEmpty {
            Kicker(text: title, count: rows.count)
                .padding(.horizontal, RailRowMetrics.inset)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(rows) { workspace in
                let id = Self.objectID(workspace)
                DevboxTableRow(workspace: workspace, markID: id, store: store, onClear: { clearing = workspace },
                               selected: selectedID == id, onOpen: { onOpen(id) })
                    .id(id)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// Running workspaces by memory, then parked ones oldest first, as drawn —
/// `ws:<id>`, the object Now's stale workspaces open. The detail is the
/// workspace's apps and per-source verbs; park, hold and clear stay on the
/// row, behind their own confirmations.
extension DevboxPage: ModulePage {
    static func objectID(_ workspace: DevboxWorkspace) -> String { "ws:\(workspace.id)" }

    static func running(_ rows: [DevboxWorkspace]) -> [DevboxWorkspace] {
        rows.filter(\.isHot).sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// Oldest first: the stale end of the pile is what a clean-up pass is
    /// looking for.
    static func parked(_ rows: [DevboxWorkspace]) -> [DevboxWorkspace] {
        rows.filter { !$0.isHot }
            .sorted { ($0.parkedAt ?? .distantFuture) < ($1.parkedAt ?? .distantFuture) }
    }

    var listWidth: CGFloat { 620 }
    /// `DevboxColumn` at its floors, the row inset and the page padding.
    var minListWidth: CGFloat { 580 }

    /// The row's lifecycle verbs on every marked workspace (bulk D5), one
    /// after another — the CLI takes one workspace per call and its
    /// admission locks — each row settled as it lands and the boxes re-read
    /// once at the end. Clear is Clear this's Keep: the runtime only, never
    /// a worktree; that stays a per-row decision in its popover.
    var bulkVerbs: [BulkVerb] {
        let workspaces = store.devboxWorkspaces
        let store = store
        func workspace(_ id: String) -> DevboxWorkspace? { workspaces.first { Self.objectID($0) == id } }
        func eligible(_ reason: @escaping (DevboxWorkspace) -> String?) -> @MainActor (String) -> String? {
            { id in workspace(id).map(reason) ?? "gone from the box" }
        }
        func each(_ done: String, _ work: @escaping (DevboxWorkspace) async -> String?)
            -> @MainActor ([String], @escaping BulkVerb.Report) async -> Void
        {
            { ids, report in
                for id in ids {
                    guard let workspace = workspace(id) else {
                        report(id, .skipped("gone from the box"))
                        continue
                    }
                    report(id, .running)
                    report(id, await work(workspace).map(BulkRowState.failed) ?? .done(done))
                }
                await store.refreshDevboxNow()
            }
        }
        let describe: @MainActor (String) -> String? = { id in
            workspace(id).map { [$0.box?.name, $0.project, $0.branch].compactMap { $0 }.joined(separator: " · ") }
        }
        return [
            BulkVerb(id: "park", title: "Park", symbol: "parkingsign.circle", noun: "workspace", destructive: true,
                     help: "Stop each stack; identity, ports and data stay, and Revive brings it back",
                     caution: "Each stack stops. Identity, ports and data stay; Revive brings it back in ~16 s.",
                     skip: eligible { $0.isParked ? "already parked" : nil }, describe: describe,
                     run: each("parked") { await DevboxClient.shared.attempt(.park, workspace: $0.name) }),
            BulkVerb(id: "revive", title: "Revive", symbol: "play.circle", noun: "workspace",
                     help: "devbox up from each workspace's own Mac worktree",
                     skip: eligible { workspace in
                         guard workspace.isParked else { return "running" }
                         guard let macPath = workspace.macPath else { return "the box recorded no Mac path" }
                         return DevboxLauncher.localDirectory(macPath, quiet: true) == nil ? "\(macPath) is not on this Mac" : nil
                     },
                     run: each("revived") { workspace in
                         guard let macPath = workspace.macPath else { return "no Mac path" }
                         return await DevboxClient.shared.up(workspace: workspace.name, macPath: macPath)
                             ? nil : "devbox up failed — Console has its output"
                     }),
            BulkVerb(id: "hold", title: "Hold", symbol: "pin", noun: "workspace",
                     help: "Exempt each from the park sweep",
                     skip: eligible { $0.hold ? "already held" : nil },
                     run: each("held") { await DevboxClient.shared.attempt(.hold, workspace: $0.name) }),
            BulkVerb(id: "unhold", title: "Unhold", symbol: "pin.slash", noun: "workspace",
                     help: "Return each to auto-parking",
                     skip: eligible { $0.hold ? nil : "not held" },
                     run: each("unheld") { await DevboxClient.shared.attempt(.unhold, workspace: $0.name) }),
            BulkVerb(id: "clear", title: "Clear", symbol: "trash", noun: "workspace", destructive: true,
                     help: "Retire each runtime; every source, worktree, commit and the data stay",
                     caution: "Retires each runtime. Mac source, worktrees, commits, the guest's source and its data all stay — removing a worktree is Clear this, one row at a time.",
                     skip: eligible { $0.hold ? "held — unhold it first" : nil }, describe: describe,
                     run: each("cleared — source and data kept") { workspace in
                         let report = await DevboxClient.shared.clearRuntime(workspace)
                         guard !report.ok else { return nil }
                         NSLog("pultik: bulk clear %@ failed:\n%@", workspace.name, report.log)
                         return report.reason
                     }),
        ]
    }

    var objects: [ModuleObject] {
        let rows = workspaces
        return (Self.running(rows) + Self.parked(rows)).map { workspace in
            var facts = [ModuleObject.Fact(label: "state", value: workspace.state)]
            if let project = workspace.project { facts.append(.init(label: "project", value: project)) }
            if let branch = workspace.branch { facts.append(.init(label: "branch", value: branch)) }
            if let box = workspace.box { facts.append(.init(label: "box", value: box.name)) }
            if !workspace.isParked { facts.append(.init(label: "memory", value: workspace.memoryLabel)) }
            facts.append(.init(label: "peak", value: workspace.memPeakLabel))
            if let ports = workspace.portWindowLabel { facts.append(.init(label: "ports", value: ports)) }
            if let macPath = workspace.macPath { facts.append(.init(label: "mac path", value: macPath)) }
            if let created = workspace.created { facts.append(.init(label: "created", value: PultikFormat.ago(created, now: Date()))) }
            let status = workspace.isParked ? Chip(workspace.parkedLabel, .neutral)
                : workspace.failedApps > 0 ? Chip("\(workspace.failedApps) down", .warn) : Chip("running", .ok)
            return ModuleObject(id: Self.objectID(workspace), title: workspace.shortName, label: workspace.box?.name,
                                status: status,
                                meta: [workspace.project, workspace.branch].compactMap { $0 }.joined(separator: " · "),
                                symbol: "shippingbox", project: workspace.project,
                                context: workspace.hold ? [Chip("held", .neutral, symbol: "pin.fill")] : [],
                                facts: facts, markable: true)
        }
    }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let workspace = store.devboxWorkspaces.first(where: { Self.objectID($0) == object.id }) {
            DevboxWorkspaceDetail(workspace: workspace)
                .kitTile()
        }
    }
}

/// Column widths of the workspace table — the header and every row share
/// them so the columns line up. The name takes what is left (`name` is its
/// floor); the verbs take nothing, they overlay the row's trailing edge.
private enum DevboxColumn {
    static let spacing: CGFloat = 6
    static let name: CGFloat = 160
    static let identity: CGFloat = 170
    static let apps: CGFloat = 40
    static let memory: CGFloat = 48
    static let age: CGFloat = 44
}

/// One workspace: dot · name · project/branch · apps · mem · peak · age, the
/// verbs overlaid while hovered or selected. Parked rows wear the hollow dot
/// every idle line in the panel wears; a stale one's age is orange.
private struct DevboxTableRow: View {
    let workspace: DevboxWorkspace
    /// Its object id: the mark's check takes the dot's place.
    let markID: String
    let store: StatusStore
    let onClear: () -> Void
    var selected = false
    let onOpen: () -> Void
    @State private var hovering = false

    private var tone: Color {
        if workspace.failedApps > 0 { return .orange }
        return workspace.isRunning ? .green : .secondary
    }

    /// Which box the row lives on — shown only when there is more than one,
    /// so the single-box table is unchanged.
    private var boxTag: String? {
        store.devboxBoxes.count > 1 ? workspace.box?.name : nil
    }

    /// Held workspaces are never stale: `gc --retire-stale` does not touch them.
    private var isStale: Bool {
        guard workspace.isParked, !workspace.hold, let parkedAt = workspace.parkedAt else { return false }
        return Date().timeIntervalSince(parkedAt) > DevboxGlance.staleAfter
    }

    var body: some View {
        HStack(spacing: DevboxColumn.spacing) {
            HStack(spacing: RailRowMetrics.dotGap) {
                MarkSlot(id: markID, hovering: hovering, size: 9) {
                    if workspace.isParked {
                        Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    } else {
                        Circle().fill(tone)
                    }
                }
                .frame(width: RailRowMetrics.dotSize, height: RailRowMetrics.dotSize)
                Text(workspace.shortName)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(workspace.isParked ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if workspace.hold {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("held")
                }
                if let box = boxTag {
                    Text(box)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("box \(box)")
                }
            }
            .frame(minWidth: DevboxColumn.name, maxWidth: .infinity, alignment: .leading)
            cell(identity, width: DevboxColumn.identity, alignment: .leading)
                .truncationMode(.middle)
            cell(apps, width: DevboxColumn.apps)
            cell(workspace.isParked ? "—" : workspace.memoryLabel, width: DevboxColumn.memory)
                .help(workspace.footprintHelp)
            cell(workspace.memPeakLabel, width: DevboxColumn.memory)
                .help(workspace.footprintHelp)
            cell(age, width: DevboxColumn.age, tone: isStale ? .orange : nil)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        // The selected row keeps its verbs: the keyboard has no hover.
        .overlay(alignment: .trailing) {
            DevboxVerbs(workspace: workspace, store: store, revealed: hovering || selected, onClear: onClear)
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, RailRowMetrics.verticalInset)
        .background { RowBackground(selected: selected, hovering: hovering, mark: markID) }
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.name), \(accessibilityState)")
        .accessibilityAction(named: "Open", onOpen)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .trailing,
                      tone: Color? = nil) -> some View
    {
        Text(text)
            .font(RailRowMetrics.metaFont)
            .monospacedDigit()
            .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private var identity: String {
        switch (workspace.project, workspace.branch) {
        case let (project?, branch?): "\(project) · \(branch)"
        case let (project?, nil): project
        case let (nil, branch?): branch
        default: "committed workspace"
        }
    }

    private var apps: String {
        if !workspace.unitApps.isEmpty { return "\(workspace.activeApps)/\(workspace.unitApps.count)" }
        return workspace.apps.isEmpty ? "—" : "\(workspace.apps.count)"
    }

    private var age: String {
        let since = workspace.isParked ? workspace.parkedAt : workspace.created
        return since.map { DevboxWorkspace.age(since: $0) } ?? "—"
    }

    private var accessibilityState: String {
        var parts = [workspace.isParked ? workspace.parkedLabel : workspace.isRunning ? "running" : "units down"]
        if workspace.hold { parts.append("held") }
        if isStale { parts.append("stale") }
        return parts.joined(separator: ", ")
    }

    private var help: String {
        var lines = [workspace.name, identity]
        if let box = boxTag { lines.append("box \(box)") }
        if workspace.isParked, let parkedAt = workspace.parkedAt {
            lines.append("parked \(parkedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if workspace.hold { lines.append("held — exempt from auto-parking") }
        if let window = workspace.portWindowLabel { lines.append("ports \(window)") }
        if let macPath = workspace.macPath { lines.append("mac \(macPath)") }
        if let created = workspace.created {
            lines.append("created \(created.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }
}

private extension DevboxAlert {
    /// The strip cell this alert tints.
    var metric: DevboxMetric {
        switch self {
        case .pressure: .pressure
        case .swap: .swap
        case .load: .load
        case .slots: .slots
        }
    }
}

private enum DevboxMetric {
    case pressure, swap, load, slots
}

extension DevboxGlance {
    var cpuFraction: Double? {
        cpuPercent.map { $0 / 100 }
    }

    var memoryFraction: Double? {
        memoryTotalBytes > 0 ? memoryUsedBytes / memoryTotalBytes : nil
    }

    var diskFraction: Double? {
        guard let used = diskUsedBytes, let total = diskTotalBytes, total > 0 else { return nil }
        return used / total
    }

    /// Where the floor sits on the RAM bar: used memory past this tick is
    /// eating into what the box keeps free.
    var floorTick: Double? {
        guard memoryTotalBytes > 0, floorBytes > 0 else { return nil }
        return (memoryTotalBytes - floorBytes) / memoryTotalBytes
    }

    var cpuText: String {
        cpuPercent.map { "\(Int($0.rounded()))% · \(cores)c" } ?? "—"
    }

    /// "41/64G · 15G free" — free is the headroom above the floor, "−2G"
    /// once the box is below it.
    var ramText: String {
        guard memoryTotalBytes > 0 else { return "—" }
        let free = headroomBytes < 0 ? "\u{2212}\(Self.compact(-headroomBytes))" : Self.compact(headroomBytes)
        return "\(Self.compact(memoryUsedBytes))/\(Self.compact(memoryTotalBytes))G · \(free)G free"
    }

    var ssdText: String {
        guard let used = diskUsedBytes, let total = diskTotalBytes, total > 0 else { return "—" }
        return formatSize(used: used, total: total)
    }
}

extension DevboxWorkspace {
    /// The name without its project prefix — siblings differ at the tail,
    /// and the prefix is what truncation would keep. Where the project is
    /// shown beside it (the page's identity column) nothing is lost; the
    /// full name stays in tooltips and accessibility labels.
    var shortName: String {
        guard let project,
              name.count > project.count + 1,
              name.hasPrefix("\(project)-")
        else { return name }
        return String(name.dropFirst(project.count + 1))
    }
}
