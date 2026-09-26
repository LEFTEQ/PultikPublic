import SwiftUI

/// The `.devbox` page (spec 2026-09-23 D8 B): every metric of D4 on one strip
/// with the stale clear beside the title, then one row per workspace grouped
/// running · parked, held ones pinned in place. Verbs appear on the hovered (or expanded) row in
/// a fixed trailing slot; a click on a row opens its per-app detail below
/// it. `filter` matches name, project or branch.
struct DevboxPage: View {
    let store: StatusStore
    let filter: String
    let onBack: () -> Void

    @State private var expanded: Set<String> = []

    private var workspaces: [DevboxWorkspace] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return store.devboxWorkspaces }
        return store.devboxWorkspaces.filter { workspace in
            [workspace.name, workspace.project ?? "", workspace.branch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        ScrollView {
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
                    group("Running", rows.filter(\.isHot)
                        .sorted { $0.memoryBytes > $1.memoryBytes })
                    // Oldest first: the stale end of the pile is what a
                    // clean-up pass is looking for.
                    group("Parked", rows.filter { !$0.isHot }
                        .sorted { ($0.parkedAt ?? .distantFuture) < ($1.parkedAt ?? .distantFuture) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Devbox")
                .font(.system(size: 14, weight: .semibold))
            Text("workspaces on the box — running first")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            if let fetchedAt = store.devboxFetchedAt {
                Text(fetchedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
            HStack(alignment: .top, spacing: 18) {
                DevboxGauge(label: "CPU · \(glance.cores) cores", fraction: glance.cpuFraction,
                            value: glance.cpuText)
                DevboxGauge(label: "RAM · floor \(DevboxGlance.compact(glance.floorBytes))G",
                            fraction: glance.memoryFraction, tick: glance.floorTick,
                            value: glance.ramText, valueTone: glance.headroomBytes < 0 ? .red : nil)
                DevboxGauge(label: "SSD", fraction: glance.diskFraction, value: glance.ssdText)
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
            // One devbox over several guests (spec 2026-09-25): the figures
            // above are every box combined; each box's own free memory, and
            // a silent one, only when there is more than one.
            if !glance.boxes.isEmpty {
                HStack(spacing: 22) {
                    ForEach(glance.boxes, id: \.name) { share in
                        stripCell("box \(share.name)", share.freeText, alert: share.isSilent,
                                  help: share.isSilent
                                      ? "Box \(share.name) did not answer its last poll — its workspaces are missing until it does"
                                      : "Free memory above box \(share.name)'s floor")
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
            Text("WORKSPACE").frame(width: DevboxColumn.name, alignment: .leading)
            Text("PROJECT · BRANCH").frame(width: DevboxColumn.identity, alignment: .leading)
            Text("APPS").frame(width: DevboxColumn.apps, alignment: .trailing)
            Text("MEM").frame(width: DevboxColumn.memory, alignment: .trailing)
            Text("PEAK").frame(width: DevboxColumn.memory, alignment: .trailing)
            Text("AGE").frame(width: DevboxColumn.age, alignment: .trailing)
                .help("Running: since created · parked: since parked")
            Spacer(minLength: 0)
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
                DevboxTableRow(workspace: workspace, store: store,
                               expanded: expanded.contains(workspace.id),
                               onToggle: { toggle(workspace.id) })
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

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.14)) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
    }
}

/// Column widths of the workspace table — the header and every row share
/// them so the columns line up; the verbs take what is left.
private enum DevboxColumn {
    static let spacing: CGFloat = 6
    static let name: CGFloat = 160
    static let identity: CGFloat = 170
    static let apps: CGFloat = 40
    static let memory: CGFloat = 48
    static let age: CGFloat = 44
}

/// One workspace: dot · name · project/branch · apps · mem · peak · age ·
/// verbs. Parked rows wear the hollow dot every idle line in the panel wears;
/// a stale one's age is orange.
private struct DevboxTableRow: View {
    let workspace: DevboxWorkspace
    let store: StatusStore
    let expanded: Bool
    let onToggle: () -> Void
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DevboxColumn.spacing) {
                HStack(spacing: RailRowMetrics.dotGap) {
                    Group {
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
                .frame(width: DevboxColumn.name, alignment: .leading)
                cell(identity, width: DevboxColumn.identity, alignment: .leading)
                    .truncationMode(.middle)
                cell(apps, width: DevboxColumn.apps)
                cell(workspace.isParked ? "—" : workspace.memoryLabel, width: DevboxColumn.memory)
                    .help(workspace.footprintHelp)
                cell(workspace.memPeakLabel, width: DevboxColumn.memory)
                    .help(workspace.footprintHelp)
                cell(age, width: DevboxColumn.age, tone: isStale ? .orange : nil)
                Spacer(minLength: 4)
                DevboxVerbs(workspace: workspace, store: store, revealed: hovering || expanded)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            if expanded {
                DevboxWorkspaceDetail(workspace: workspace)
                    .padding(.leading, RailRowMetrics.indent)
            }
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, RailRowMetrics.verticalInset)
        .background(hovering ? RailRowMetrics.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.name), \(accessibilityState)")
        .accessibilityAction(named: expanded ? "Collapse" : "Expand", onToggle)
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
