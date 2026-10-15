import SwiftUI

/// Each module chip's live signal (D5-A), projected from the stores the panel
/// already holds — the strip formats state, it never polls. A module whose
/// source has nothing to say carries no signal; ordinary state (running
/// checks, busy sessions) stays quiet.
@MainActor
enum ModuleSignals {
    static func make(store: StatusStore, fanStore: FanStore, macHealth: MacHealthStore) -> [PanelModule: ModuleSignal] {
        var signals: [PanelModule: ModuleSignal] = [:]

        let digest = PRDigest(store.inbox, repo: \.repoSlug, info: \.info)
        let onYou = digest.repos.reduce(0) { $0 + $1.needsYou.count }
        if onYou > 0 {
            signals[.prs] = ModuleSignal(kind: .pill("\(onYou)"), tone: Theme.warn,
                                         help: "\(onYou) pull request\(onYou == 1 ? "" : "s") on you")
        }

        let ci = CIGlance(board: store.laneBoard, repos: store.repos)
        if ci.failedRuns > 0 {
            signals[.ci] = ModuleSignal(kind: .text("\(ci.failedRuns) failed", symbol: "xmark.circle.fill"),
                                        tone: Theme.danger)
        }

        signals[.prod] = prodSignal(store.prodGlance, dots: store.prodDots)

        // Every box's stale rows — the table's, which the trash reaps — not
        // only the strip's box.
        if store.devboxSummary != nil {
            let stale = DevboxGlance.staleCount(store.devboxWorkspaces)
            if stale > 0 {
                signals[.devbox] = ModuleSignal(kind: .text("\(stale) stale", symbol: nil), tone: Theme.warn)
            }
        }

        if let selected = store.selectedVitrinkaWorkspace {
            let glance = VitrinkaGlance(today: selected.today, reason: \.reason, liveQuestions: [], elsewhere: [])
            let needs = glance.needsYou + glance.overdue + glance.dueNow
            if needs > 0 {
                signals[.work] = ModuleSignal(kind: .pill("\(needs)"), tone: glance.overdue > 0 ? Theme.danger : Theme.warn)
            }
        }

        // Sessions: a live fleet session or an eve workflow blocked on you. A
        // busy session, a stale or restored snapshot, or an eve PR session
        // "waiting" on CI or review stays quiet.
        let fleet = FleetStore.shared
        let sessionsWaiting = fleet.isStale() ? 0
            : (fleet.snapshot?.sessions ?? []).filter { $0.state == .waiting && ($0.liveness == .alive || $0.liveness == .unknown) }.count
        let now = Date()
        let approvals = store.eveLastKnownAt == nil ? store.eveApprovals.filter { !$0.drifts(now: now) }.count : 0
        let waiting = sessionsWaiting + approvals
        if waiting > 0 {
            signals[.sessions] = ModuleSignal(kind: .text("\(waiting) waiting", symbol: "hand.raised.fill"),
                                              tone: Theme.warn,
                                              help: "\(sessionsWaiting) session\(sessionsWaiting == 1 ? "" : "s") and "
                                                  + "\(approvals) eve approval\(approvals == 1 ? "" : "s") waiting on you")
        }

        let firing = AlertGlance(store.firingAlerts).rows
        if !firing.isEmpty {
            signals[.estate] = ModuleSignal(kind: .text("\(firing.count) firing", symbol: "bell.fill"),
                                            tone: firing.contains(where: \.critical) ? Theme.danger : Theme.warn)
        }

        // This Mac is one of Estate's machines (vt-7727 D1): its full disk or
        // red findings speak for Estate while nothing is firing.
        if signals[.estate] == nil, let total = fanStore.diskTotalBytes, total > 0, let free = fanStore.diskFreeBytes {
            let used = 1 - Double(free) / Double(total)
            if used >= 0.8 {
                signals[.estate] = ModuleSignal(kind: .text("Mac disk \(PultikFormat.percent(used))", symbol: nil),
                                                tone: MeterBar.tone(used))
            }
        }
        if signals[.estate] == nil, let chip = macHealth.status.chip, chip.severity == .red {
            signals[.estate] = ModuleSignal(kind: .text(chip.text, symbol: nil), tone: Theme.danger, help: chip.help)
        }
        return signals
    }

    /// One dot per deployment; a red deployment washes the chip in danger
    /// and names itself with its failing check (`ExampleApp prod · jobs stuck +1`).
    private static func prodSignal(_ glance: ProdGlance, dots: [ProdGlance.Dot]) -> ModuleSignal? {
        guard !dots.isEmpty else { return nil }
        let marks = dots.map { dot -> ModuleSignal.Dot in
            switch dot.tone {
            case .green: ModuleSignal.Dot(tone: Theme.ok)
            case .orange: ModuleSignal.Dot(tone: Theme.warn)
            case .red: ModuleSignal.Dot(tone: Theme.danger)
            case .blind, .hollow: ModuleSignal.Dot(tone: Theme.idle, hollow: true)
            }
        }
        let red = glance.cards.filter { $0.tone == .red }
        var alarm: String?
        if let first = red.first {
            let failing = first.chips.first { $0.tone != .green }?.label
            alarm = [first.title, failing].compactMap { $0 }.joined(separator: " · ")
                + (red.count > 1 ? " +\(red.count - 1)" : "")
        }
        return ModuleSignal(kind: .dots(marks), tone: Theme.ink2, alarm: alarm)
    }
}

extension ModuleSignal {
    /// The chip's signal as it reads on screen — `14`, `10 failed`, `●●○`
    /// (○ = hollow: blind or unmonitored), then the alarm that widens a
    /// danger chip. nil when the chip is quiet. The debug driver's `strip`.
    var drawnText: String? {
        let signal: String? = switch kind {
        case .none: nil
        case let .pill(text): text
        case let .text(text, _): text
        case let .dots(dots): dots.map { $0.hollow ? "○" : "●" }.joined()
        }
        let parts = [signal, alarm].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
