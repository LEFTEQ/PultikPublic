import SwiftUI

/// ONE row per machine — the estate servers and this Mac: the name over its
/// core count, then cpu · ram · disk as `GlanceGrid` cells, each a reading
/// over a bar tinted by its own load tier (panel Home D5, 2026-10-07: the
/// columns start where every other glance's do). Sizes are compact —
/// "215/251G", "1.5/1.7T"; the full figures are on the tooltip. A dash is
/// "unavailable" — never a number made up from another machine.
struct MachineVitals: View {
    let name: String
    let cpuCount: Int?
    let cpuPercent: Double?
    let memoryUsed: Double?
    let memoryTotal: Double?
    let diskUsed: Double?
    let diskTotal: Double?
    /// Prometheus already knows the percentages; a caller that has them passes
    /// them so a box reporting no byte counters still gets a tone.
    var memoryPercent: Double? = nil
    var diskPercent: Double? = nil
    /// This Mac tints memory by kernel pressure, where used-% over-alarms.
    var memoryTone: Color? = nil

    private var memoryLoad: Double? {
        if let memoryPercent { return memoryPercent }
        guard let memoryUsed, let memoryTotal, memoryTotal > 0 else { return nil }
        return memoryUsed / memoryTotal * 100
    }

    private var diskLoad: Double? {
        if let diskPercent { return diskPercent }
        guard let diskUsed, let diskTotal, diskTotal > 0 else { return nil }
        return diskUsed / diskTotal * 100
    }

    var body: some View {
        GlanceRow(name: name, detail: cpuCount.map { "\($0) cores" }, cells: [
            GlanceCell(percentText(cpuPercent), fraction: cpuPercent.map { $0 / 100 }),
            memoryCell,
            GlanceCell(compactText(used: diskUsed, total: diskTotal) ?? percentText(diskLoad),
                       fraction: diskLoad.map { $0 / 100 }),
        ], help: help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// This Mac passes a pressure tone: calm pressure reads calm whatever
    /// used-% says, so the bar keeps the fraction but not its alarm.
    private var memoryCell: GlanceCell {
        let text = compactText(used: memoryUsed, total: memoryTotal) ?? percentText(memoryLoad)
        let fraction = memoryLoad.map { $0 / 100 }
        guard let memoryTone else { return GlanceCell(text, fraction: fraction) }
        let calm = memoryTone == .secondary
        return GlanceCell(text, fraction: fraction, tone: calm ? .primary : memoryTone,
                          barTone: calm ? .green : memoryTone)
    }

    private func compactText(used: Double?, total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return compactSize(used: max(0, used), total: total)
    }

    private func percentText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func sizeText(used: Double?, total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return formatSize(used: max(0, used), total: total)
    }

    private var help: String {
        var parts = [name]
        if let cpuCount { parts.append("\(cpuCount) cores") }
        if let disk = sizeText(used: diskUsed, total: diskTotal) { parts.append("disk \(disk)") }
        return parts.joined(separator: " — ")
    }

    private var accessibilityLabel: String {
        "\(name), \(cpuCount.map { "\($0) CPUs, " } ?? "")CPU \(cpuPercent.map { String(format: "%.0f percent", $0) } ?? "unavailable"), "
            + "memory \(sizeText(used: memoryUsed, total: memoryTotal) ?? "unavailable"), "
            + "disk \(sizeText(used: diskUsed, total: diskTotal) ?? "unavailable")"
    }
}
