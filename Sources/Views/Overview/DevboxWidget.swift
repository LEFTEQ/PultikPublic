import SwiftUI

/// The Devbox widget of the overview column (spec 2026-09-23, leaned by
/// 2026-09-27): CPU / RAM / SSD / swap gauges, the workspace pile in one line
/// and — only past a threshold — one orange line naming the strain. A tap
/// opens the `.devbox` page, where the names are. No summary (box
/// unreachable, laptop off the mesh) → the widget is not drawn at all.
struct DevboxWidget: View {
    let store: StatusStore
    let onOpen: (String) -> Void

    var body: some View {
        if let summary = store.devboxSummary {
            let glance = DevboxGlance(summary: summary, workspaces: store.devboxWorkspaces)
            GlanceGrid.tile {
                VStack(alignment: .leading, spacing: 4) {
                    header(glance, pressure: summary.pressure)
                        .padding(.bottom, 2)
                    gauges(glance)
                    if !glance.boxes.isEmpty {
                        boxLine(glance)
                    }
                    pile(glance)
                    if !glance.bannerAlerts.isEmpty {
                        alertLine(glance)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen("") }
        }
    }

    private func header(_ glance: DevboxGlance, pressure: DevboxOverviewSummary.Pressure) -> some View {
        // The headroom is what admission spends, so it rides the heading.
        TileHeader(title: "Devbox", count: glance.running.count,
                   tone: Self.tone(pressure) ?? .secondary,
                   caption: glance.freeText,
                   captionTone: glance.headroomBytes < 0 ? .red : .secondary,
                   action: { onOpen("") },
                   actionHelp: "Open every devbox workspace")
            .padding(.horizontal, RailRowMetrics.inset)
    }

    /// The guest on the shared grid (D5): cpu · ram · ssd, then swap under
    /// cpu. RAM's tick is the floor the box keeps free and its reading turns
    /// red past it; swap turns orange past the threshold the alert line used
    /// to name. The headroom and the full SSD reading are on the `.devbox` strip.
    private func gauges(_ glance: DevboxGlance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            GlanceHeads(titles: ["cpu", "ram", "ssd"])
            GlanceRow(name: glance.boxes.isEmpty ? "guest" : "boxes", detail: "\(glance.cores) cores", cells: [
                GlanceCell(glance.cpuPercentText, fraction: glance.cpuFraction),
                GlanceCell(glance.ramCompactText, fraction: glance.memoryFraction, tick: glance.floorTick,
                           tone: glance.headroomBytes < 0 ? .red : nil),
                GlanceCell(glance.ssdCompactText, fraction: glance.diskFraction),
            ])
            GlanceRow(name: "swap", cells: [
                GlanceCell(glance.swapText, fraction: glance.swapFraction,
                           tone: glance.swapUsedBytes > DevboxGlance.swapAlertBytes ? .orange : nil),
            ])
        }
        .help("\(glance.cores) cores. RAM's orange tick is the \(DevboxGlance.compact(glance.floorBytes))G floor the box keeps free")
    }

    /// One devbox over several guests (spec 2026-09-25): the gauges are the
    /// boxes combined; this line — drawn only with more than one box — is
    /// each box's free memory, and names a silent box in orange.
    private func boxLine(_ glance: DevboxGlance) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(glance.boxes.enumerated()), id: \.element.name) { index, share in
                if index > 0 { Text(" · ") }
                if share.isSilent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .padding(.trailing, 2)
                }
                Text(share.label)
                    .foregroundStyle(share.isSilent ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            }
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, RailRowMetrics.inset)
        .help("Free memory above each box's floor; the gauges are every box combined. A silent box did not answer its last poll — its workspaces are missing until it does.")
    }

    /// The whole pile in one line: running, parked, stale (parked over a
    /// week) in orange — what the page's clear is for — then held.
    private func pile(_ glance: DevboxGlance) -> some View {
        HStack(spacing: 0) {
            Text("\(glance.running.count) running · ")
            Text(glance.parked == 0 ? "nothing parked" : "\(glance.parked) parked")
            if glance.stale > 0 {
                Text(" · ")
                Text("\(glance.stale) stale")
                    .foregroundStyle(.orange)
            }
            if glance.held > 0 {
                Text(" · \(glance.held) held")
            }
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.horizontal, RailRowMetrics.inset)
    }

    /// Present only while at least one threshold is crossed, so a calm box
    /// stays compact and a stressed one says why (spec 2026-09-23 D13).
    private func alertLine(_ glance: DevboxGlance) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text(glance.bannerAlerts.map(\.label).joined(separator: " · "))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(RailRowMetrics.metaFont)
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .padding(.horizontal, RailRowMetrics.inset - 2)
        .help("Shown past a threshold: memory pressure over 5 %, load over 1 per core, port slots over 80 % (swap over 0.5 G tints its gauge)")
    }

    /// The box's own pressure verdict tints the heading (thresholds in
    /// `DevboxOverviewSummary.pressure`), never a HUD guess.
    static func tone(_ pressure: DevboxOverviewSummary.Pressure) -> Color? {
        switch pressure {
        case .critical: return .red
        case .elevated: return .orange
        case .normal: return nil
        }
    }
}

/// Label, a thin bar and its reading — one cell of the Devbox gauges, shared
/// by the widget and the `.devbox` page's strip. `tick` marks a threshold on
/// the bar (the RAM floor); the bar tints by `LoadTier`.
struct DevboxGauge: View {
    let label: String
    let fraction: Double?
    var tick: Double?
    let value: String
    var valueTone: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(RailRowMetrics.metaFont)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    if let fraction {
                        Capsule()
                            .fill(barTone.opacity(0.8))
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                    if let tick {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 1.5, height: 8)
                            .offset(x: proxy.size.width * min(max(tick, 0), 1) - 0.75)
                    }
                }
            }
            .frame(height: 4)
            Text(value)
                .font(RailRowMetrics.metaFont)
                .monospacedDigit()
                .foregroundStyle(valueTone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private var barTone: Color {
        fraction.map { percentTone($0 * 100) } ?? .secondary
    }
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

    /// The glance's grid cell — the headroom moved to the heading.
    var ramCompactText: String {
        guard memoryTotalBytes > 0 else { return "—" }
        return "\(Self.compact(memoryUsedBytes))/\(Self.compact(memoryTotalBytes))G"
    }

    /// "88G free", "−4G free" once the box is below its floor.
    var freeText: String? {
        guard memoryTotalBytes > 0 else { return nil }
        let free = headroomBytes < 0 ? "\u{2212}\(Self.compact(-headroomBytes))" : Self.compact(headroomBytes)
        return "\(free)G free"
    }

    var ssdText: String {
        guard let used = diskUsedBytes, let total = diskTotalBytes, total > 0 else { return "—" }
        return formatSize(used: used, total: total)
    }

    var cpuPercentText: String {
        cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// "418/483G" — the widget's cell; the page's strip keeps `ssdText`.
    var ssdCompactText: String {
        guard let used = diskUsedBytes, let total = diskTotalBytes, total > 0 else { return "—" }
        return "\(Self.compact(used))/\(Self.compact(total))G"
    }

    var swapFraction: Double? {
        swapTotalBytes > 0 ? swapUsedBytes / swapTotalBytes : nil
    }

    /// "20/24G" — same shape as the RAM reading; "none" on a box without swap.
    var swapText: String {
        guard swapTotalBytes > 0 else { return "none" }
        return "\(Self.compact(swapUsedBytes))/\(Self.compact(swapTotalBytes))G"
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
