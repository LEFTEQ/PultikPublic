import SwiftUI

/// One machine as a lean line (vt-7727 D9): This Mac, a host or a guest,
/// cpu · ram · disk as fractions and its firing count. Estate's Machines
/// and Home's Estate widget both draw it with `MachineRow`.
struct MachineLine: Identifiable, Equatable {
    let id: String
    let name: String
    var meta: String?
    var cpu: Double?
    var ram: Double?
    var disk: Double?
    var firing = 0
    var critical = false
    /// Replaces the firing count: This Mac's "25 orph.".
    var note: String?
    var guest = false

    /// This Mac, then each host in Settings order — followed by its guests
    /// when `guests`; without them a host counts its guests' alerts too.
    /// Never a figure summed across hosts (2026-10-14).
    @MainActor
    static func lines(servers: [ServerMetrics], firing: [FiringAlert], mac: MacHealthStatus, fans: FanStore,
                      guests: Bool) -> [MachineLine]
    {
        var lines: [MachineLine] = []
        if let report = mac.fresh {
            let machine = report.machine
            let disk = fans.diskTotalBytes.flatMap { total in
                fans.diskFreeBytes.map { 1 - Double($0) / Double(max(total, 1)) }
            }
            let orphans = report.headline.orphans
            lines.append(MachineLine(id: PaletteMode.thisMac, name: "This Mac", meta: "\(machine.cores) cores",
                                     cpu: machine.cpuPct / 100,
                                     ram: machine.memTotalGb > 0 ? machine.memUsedGb / machine.memTotalGb : nil,
                                     disk: disk, note: orphans > 0 ? "\(orphans) orph." : nil))
        }
        func line(_ server: ServerMetrics, counting ids: Set<String>) -> MachineLine {
            let alerts = firing.filter { $0.serverID(among: servers).map(ids.contains) ?? false }
            // build-server-next keeps its data on ZFS `vy`: there the pool is the disk.
            let pool = server.pools.first
            let cores = server.cpuCount.map { server.isGuest ? "\($0) · guest" : "\($0) cores" }
            return MachineLine(id: MachinesPage.objectID(server), name: server.name, meta: cores,
                               cpu: server.cpu.map { $0 / 100 },
                               ram: fraction(server.ramUsedBytes, server.ramTotalBytes) ?? server.ram.map { $0 / 100 },
                               disk: pool.map { $0.percent / 100 }
                                   ?? fraction(server.diskUsedBytes, server.diskTotalBytes) ?? server.disk.map { $0 / 100 },
                               firing: alerts.count, critical: alerts.contains { $0.severity == "critical" },
                               guest: server.isGuest)
        }
        for host in servers where !host.isGuest {
            let own = servers.filter { $0.vmHost == host.instance }
            lines.append(line(host, counting: guests ? [host.id] : Set([host.id] + own.map(\.id))))
            if guests { lines += own.map { line($0, counting: [$0.id]) } }
        }
        return lines
    }

    static func fraction(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }
}

/// One machine: status dot · name (cores) · cpu · ram · disk micro meters ·
/// firing. A guest sits indented under its host.
struct MachineRow: View {
    let line: MachineLine
    var selected = false
    /// A narrow Home widget: no cores.
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 28

    private var tone: Color {
        if line.critical { return Theme.danger }
        if line.firing > 0 || line.note != nil { return Theme.warn }
        return Theme.ok
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StatusDot(tone: tone)
                Text(line.name)
                    .font(.system(size: line.guest ? 12 : 13))
                    .foregroundStyle(line.guest ? Theme.ink2 : Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !compact, let meta = line.meta {
                    Text(meta).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 4)
                MicroMeter(fraction: line.cpu)
                MicroMeter(fraction: line.ram)
                MicroMeter(fraction: line.disk)
                Group {
                    if let note = line.note {
                        Text(note).foregroundStyle(Theme.warn)
                    } else {
                        Text(verbatim: line.firing > 0 ? "\(line.firing)" : "—")
                            .foregroundStyle(line.critical ? Theme.danger : line.firing > 0 ? Theme.warn : Theme.ink3)
                    }
                }
                .font(Theme.Typo.meta).monospacedDigit().lineLimit(1)
                .frame(width: compact ? 36 : 52, alignment: .trailing)
            }
            .padding(.leading, line.guest && !compact ? 22 : 6)
            .padding(.trailing, 6)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The micro labels over `MachineRow`'s columns.
struct MachineColumnHeads: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Machine").microLabel()
            Spacer(minLength: 4)
            ForEach(["cpu", "ram", "disk"], id: \.self) { Text($0).microLabel().frame(width: 34) }
            Text("Firing").microLabel().frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
    }
}
