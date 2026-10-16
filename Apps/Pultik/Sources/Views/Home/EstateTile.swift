import SwiftUI

/// Home's Estate widget (vt-7727 D8, D9): every machine on one lean line —
/// This Mac first, then each host — with cpu · ram · disk as micro meters
/// and its firing count (`MachineLine`, a host counting its guests), then
/// the backups that need a look. Nothing is summed across hosts
/// (2026-10-14). Guests, services and renewals stay in Estate; a line opens
/// its machine there. Formats `serverMetrics`, the estate's firing alerts,
/// This Mac's report and the Semafors' estate — never a poll of its own.
struct EstateTile: View {
    let store: StatusStore
    /// The estate's firing rules (`estateFiring`), heartbeat excluded.
    let firing: [FiringAlert]
    var health: MacHealthStore = .shared
    var fans: FanStore = .shared
    /// A machine's object id in Estate; nil opens the module.
    let onOpen: (String?) -> Void
    @Environment(\.tileCompact) private var compact

    static func isShown(store: StatusStore) -> Bool {
        store.isSectionVisible("servers") && !store.serverMetrics.isEmpty
    }

    var body: some View {
        let lines = MachineLine.lines(servers: store.serverMetrics, firing: firing, mac: health.status, fans: fans,
                                      guests: false)
        let total = lines.reduce(0) { $0 + $1.firing }
        let critical = lines.contains(where: \.critical)
        VStack(alignment: .leading, spacing: 6) {
            TileHeader(title: "Estate", count: total, tone: critical ? .red : total > 0 ? .orange : .secondary,
                       caption: caption(machines: lines.count),
                       action: { onOpen(nil) }, actionHelp: "Every machine, its backups and services — .e")
            MachineColumnHeads()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        MachineRow(line: line, compact: compact) { onOpen(line.id) }
                            .help("Open \(line.name) in Estate")
                    }
                }
            }
            backupsLine
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }

    /// "5 machines · 40/67 apps synced": apps from the Semafors that answered.
    private func caption(machines: Int) -> String {
        let apps = store.estateBoxes.flatMap(\.box.appList)
        guard !apps.isEmpty else { return "\(machines) machines" }
        let synced = store.estateBoxes.reduce(0) { $0 + $1.box.syncedCount }
        return "\(machines) machines · \(synced)/\(apps.count) apps synced"
    }

    /// "backups: 3 need a look" — pipelines whose verdict is not go.
    @ViewBuilder
    private var backupsLine: some View {
        let now = Date()
        let look = store.estatePipelines.filter { BackupVerdict.of($0, now: now) != .go }
        if !look.isEmpty {
            let stop = look.contains { BackupVerdict.of($0, now: now) == .stop }
            Button { onOpen(nil) } label: {
                HStack(spacing: 6) {
                    StatusDot(tone: stop ? Theme.danger : Theme.warn)
                    Text("backups: \(look.count) need\(look.count == 1 ? "s" : "") a look")
                        .foregroundStyle(stop ? Theme.danger : Theme.warn)
                    Text(look.prefix(2).map(\.name).joined(separator: " · ")).foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                .font(Theme.Typo.meta).lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
    }
}
