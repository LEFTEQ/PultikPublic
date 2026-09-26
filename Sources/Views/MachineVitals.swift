import SwiftUI

/// ONE line per machine — the same capacity grammar for the estate servers
/// and the Devbox guest: name, then cpu / ram / disk, each tinted by its own
/// load tier. Column widths are fixed and sized to the widest value each can
/// hold — "AppServer", "100%", "147/251 GB" — because ragged numeric columns
/// are unreadable at 9.5pt (restored 2026-09-14; the two-row grid it briefly
/// became scattered the reading across three lines and lost the tones).
///
/// Disk shows a percentage to stay narrow; the absolute figure and the core
/// count are a hover away on the row's tooltip rather than lost. A dash is
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

    private enum Column {
        static let name: CGFloat = 60
        static let percent: CGFloat = 26
        static let size: CGFloat = 58
    }

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
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Column.name, alignment: .leading)
            Vital(symbol: "cpu", percent: cpuPercent, text: percentText(cpuPercent), width: Column.percent)
            Vital(symbol: "memorychip", percent: memoryLoad,
                  text: sizeText(used: memoryUsed, total: memoryTotal) ?? percentText(memoryLoad),
                  width: Column.size)
            Vital(symbol: "internaldrive", percent: diskLoad, text: percentText(diskLoad),
                  width: Column.percent)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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

// MARK: - Shared vital cell

/// Icon + number, tinted by load. Two initialisers because the callers know
/// different things: the Mac tier has already chosen a tone (a fan's tone
/// comes from its own min/max, not a percentage; memory from kernel
/// pressure), the machine row has a percentage and wants the shared
/// `LoadTier` scale applied to it.
struct Vital: View {
    let symbol: String
    let text: String
    let tone: Color
    var width: CGFloat?
    var help: String?

    init(symbol: String, text: String, tone: Color, help: String? = nil) {
        self.symbol = symbol
        self.text = text
        self.tone = tone
        self.help = help
    }

    init(symbol: String, percent: Double?, text: String, width: CGFloat) {
        self.symbol = symbol
        self.text = text
        self.width = width
        self.tone = percent.map(percentTone) ?? .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .frame(width: 10)
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: width == nil ? .leading : .trailing)
        }
        .foregroundStyle(tone)
        .help(help ?? "")
    }
}
