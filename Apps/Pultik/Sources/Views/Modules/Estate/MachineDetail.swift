import SwiftUI

/// One line of a detail's needs-you band (vt-7727 D9): what it is, why, how long.
struct NeedLine: Identifiable {
    let id: String
    let tone: Color
    let title: String
    var meta: String?
    var age: String?

    var symbol: String {
        tone == Theme.danger ? "xmark.circle.fill" : tone == Theme.warn ? "exclamationmark.circle.fill" : "circle"
    }
}

/// The band a machine's detail opens on (D9: trouble never below the fold):
/// every need as one line, danger-tinted when one is critical; a quiet
/// line when nothing needs you.
struct NeedsYouBand: View {
    let items: [NeedLine]
    var more: String?

    var body: some View {
        let critical = items.contains { $0.tone == Theme.danger }
        VStack(alignment: .leading, spacing: 2) {
            if items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Text("Nothing needs you").font(Theme.Typo.body).foregroundStyle(Theme.ink2)
                }
            } else {
                Text("Needs you · \(items.count)").microLabel(critical ? Theme.danger : Theme.warn)
                    .padding(.bottom, 4)
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(item.tone).frame(width: 14)
                        Text("\(Text(item.title).foregroundStyle(Theme.ink))\(Text(item.meta.map { " · \($0)" } ?? "").foregroundStyle(Theme.ink3))")
                            .font(Theme.Typo.body).lineLimit(1)
                        Spacer(minLength: 8)
                        if let age = item.age {
                            Text(age).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).fixedSize()
                        }
                    }
                    .frame(height: 26)
                }
                if let more {
                    Text(more).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).padding(.leading, 22)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((critical ? Theme.danger : Color.white).opacity(critical ? 0.07 : 0.03),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            if critical {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

/// A host's or guest's detail (vt-7727 D9): needs you first — its firing
/// alerts, Semafor's findings, apps not yet on `origin/main`, backups that
/// are not go — then a bento of CPU with a per-core heatmap, memory,
/// storage, guests, Semafor's apps and the last 24 h. The history is read
/// when the detail opens (`loadMachineHistory`), never polled.
struct MachineDetail: View {
    let store: StatusStore
    let server: ServerMetrics
    /// The firing alerts about it (a host's own; a guest's own).
    let alerts: [FiringAlert]
    var now = Date()

    private var guests: [ServerMetrics] {
        server.isGuest ? [] : store.serverMetrics.filter { $0.vmHost == server.instance }
    }

    /// Semafor's box of the same name, from the Semafor that observes it.
    private var box: SemaforEstateMap.Box? {
        server.isGuest ? nil
            : store.estateBoxes.first { $0.box.name.caseInsensitiveCompare(server.name) == .orderedSame }?.box
    }

    private var needs: [NeedLine] {
        var lines = alerts.map { alert in
            NeedLine(id: alert.id, tone: MachinesPage.tone(alert), title: alert.summary ?? alert.name,
                     meta: alert.name, age: alert.activeAt.map { PultikFormat.age(now.timeIntervalSince($0)) })
        }
        guard let box else { return lines }
        lines += store.estateFindings.filter { $0.box == box.name }.map { finding in
            NeedLine(id: "semafor:\(finding.id)", tone: finding.severity == "stop" ? Theme.danger : Theme.warn,
                     title: finding.title, meta: finding.why,
                     age: SemaforTime.date(finding.since).map { PultikFormat.age(now.timeIntervalSince($0)) })
        }
        let pending = box.pendingApps
        if !pending.isEmpty {
            let ahead = box.ahead.map { " is \($0) ahead" } ?? ""
            lines.append(NeedLine(id: "pending:\(box.name)", tone: Theme.warn,
                                  title: "\(pending.count) app\(pending.count == 1 ? "" : "s") pending: "
                                      + pending.map(\.name).joined(separator: ", "),
                                  meta: box.originMain?.sha.map { "origin \($0)\(ahead)" },
                                  age: SemaforTime.date(box.tickAt).map { "tick \(PultikFormat.age(now.timeIntervalSince($0)))" }))
        }
        for pipeline in store.estatePipelines where pipeline.box == box.name {
            let verdict = BackupVerdict.of(pipeline, now: now)
            guard verdict != .go else { continue }
            let lastOk = SemaforTime.date(pipeline.lastOkAt)
            lines.append(NeedLine(id: "backup:\(pipeline.id)", tone: verdict == .stop ? Theme.danger : Theme.warn,
                                  title: "Backup \(pipeline.name) \(verdict == .stop ? "stale" : "near its budget")",
                                  meta: lastOk.map { "last good \(PultikFormat.age(now.timeIntervalSince($0))) ago" }
                                      ?? "no good run",
                                  age: nil))
        }
        return lines
    }

    var body: some View {
        let history = store.machineHistory[server.id]
        VStack(alignment: .leading, spacing: 10) {
            NeedsYouBand(items: needs)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                cpu(history)
                memory
                storage
                if !guests.isEmpty { guestsTile }
                if let box { apps(box) }
                day(history)
            }
        }
        .task(id: server.id) { await store.loadMachineHistory(server) }
    }

    private func cpu(_ history: MachineHistory?) -> some View {
        Tile(kicker: "CPU", caption: server.cpuCount.map { "\($0) cores" }) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.cpu.map { "\(Int($0.rounded()))%" } ?? "—").font(Theme.Typo.stat)
                        .foregroundStyle(server.cpu.map { MeterBar.tone($0 / 100) } ?? Theme.ink3)
                    Text("busy").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                if let cores = history?.cores, !cores.isEmpty {
                    Heatmap(values: cores, cell: cores.count > 32 ? 8 : 10)
                } else {
                    Text(history == nil ? "reading cores…" : "no per-core series")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    private var memory: some View {
        let used = server.ramUsedBytes
        let total = server.ramTotalBytes
        return Tile(kicker: "Memory", caption: total.map { PultikFormat.size($0) }) {
            if let used, let total, total > 0 {
                MeterBar(label: "used", value: PultikFormat.sizeRatio(used: used, total: total), fraction: used / total)
                let guestsUsed = guests.compactMap(\.ramTotalBytes).reduce(0, +)
                if guestsUsed > 0 {
                    Text("guests hold \(PultikFormat.size(guestsUsed)) of it")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            } else {
                Text("—").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
        }
    }

    private var storage: some View {
        Tile(kicker: "Storage") {
            VStack(alignment: .leading, spacing: 8) {
                if let used = server.diskUsedBytes, let total = server.diskTotalBytes, total > 0 {
                    MeterBar(label: "root", value: PultikFormat.sizeRatio(used: used, total: total), fraction: used / total)
                }
                ForEach(server.pools, id: \.name) { pool in
                    MeterBar(label: "zfs \(pool.name)", value: PultikFormat.sizeRatio(used: pool.usedBytes, total: pool.totalBytes),
                             fraction: pool.percent / 100)
                }
                ForEach(server.datasets.prefix(4), id: \.name) { dataset in
                    MeterBar(label: dataset.name,
                             value: PultikFormat.sizeRatio(used: dataset.usedBytes, total: dataset.totalBytes) + " quota",
                             fraction: dataset.percent / 100)
                }
            }
        }
    }

    private var guestsTile: some View {
        let lines = MachineLine.lines(servers: store.serverMetrics, firing: alerts, mac: .hidden, fans: .shared,
                                      guests: true).filter { line in guests.contains { MachinesPage.objectID($0) == line.id } }
        return Tile(kicker: "Guests", caption: "\(guests.count) VM\(guests.count == 1 ? "" : "s")") {
            VStack(spacing: 0) {
                ForEach(lines) { line in
                    MachineRow(line: line, compact: true) {}
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func apps(_ box: SemaforEstateMap.Box) -> some View {
        let pending = box.pendingApps.count
        return Tile(kicker: "Apps", caption: "\(box.appList.count)\(pending > 0 ? " · \(pending) pending" : "")") {
            VStack(alignment: .leading, spacing: 8) {
                FlowRow(hSpacing: 4, vSpacing: 4) {
                    ForEach(box.appList, id: \.name) { app in
                        switch app.sync {
                        case "roll": Chip(app.name, .warn, symbol: "clock")
                        case "synced": Chip(app.name, app.health == "down" ? .danger : .ok, symbol: "checkmark")
                        default: Chip(app.name, .neutral)
                        }
                    }
                }
                if let applied = box.applied {
                    Text([applied.sha, applied.subject].compactMap { $0 }.joined(separator: " "))
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(2)
                }
            }
        }
    }

    private func day(_ history: MachineHistory?) -> some View {
        Tile(kicker: "Last 24 h", caption: "cpu") {
            if let day = history?.day, day.count > 1 {
                Sparkline(values: day, height: 36)
            } else {
                Text(history == nil ? "reading…" : "no history").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// This Mac's detail (vt-7727 D9): its worst findings first — each is a row
/// of the list too, with its Stop… — then toolkit's machine line, memory and
/// network (`MacHealthPage`).
struct ThisMacDetail: View {
    let page: MacHealthPage

    var body: some View {
        let worst = (page.health.status.fresh?.findingsWorstFirst ?? []).filter { $0.severity == .red || $0.severity == .amber }
        VStack(alignment: .leading, spacing: 10) {
            NeedsYouBand(items: worst.prefix(5).map { finding in
                NeedLine(id: finding.id, tone: finding.severity == .red ? Theme.danger : Theme.warn,
                         title: finding.title, meta: MacHealthFormat.cost(finding), age: finding.since.shortAge)
            }, more: worst.count > 5 ? "+\(worst.count - 5) more in the list, Stop… on each" : nil)
            page
        }
    }
}
