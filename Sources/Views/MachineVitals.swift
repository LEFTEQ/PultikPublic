import SwiftUI

/// The same capacity grammar for the Mac, estate servers and Devbox guest.
struct MachineVitals: View {
    var name: String?
    let cpuCount: Int?
    let cpuPercent: Double?
    let memoryUsed: Double?
    let memoryTotal: Double?
    let diskUsed: Double?
    let diskTotal: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let name { Text(name).fontWeight(.medium) }
                Spacer(minLength: 2)
                Image(systemName: "cpu")
                Text(cpuCount.map { "\($0)c" } ?? "—c")
                Text(cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—%")
                    .foregroundStyle(cpuPercent.map(percentTone) ?? .secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                Text(size(memoryUsed, memoryTotal))
                Spacer(minLength: 4)
                Image(systemName: "internaldrive")
                Text(size(diskUsed, diskTotal))
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name ?? "Machine"), \(cpuCount.map(String.init) ?? "unknown") CPUs, CPU \(cpuPercent.map { String(format: "%.0f percent", $0) } ?? "unavailable"), memory \(size(memoryUsed, memoryTotal)) used of total, disk \(size(diskUsed, diskTotal)) used of total")
        .help("CPU count and utilization · RAM used/total · disk used/total. A dash means unavailable.")
    }

    private func size(_ used: Double?, _ total: Double?) -> String {
        guard let used, let total, total > 0 else { return "—/— GB" }
        return formatSize(used: max(0, used), total: total)
    }
}
