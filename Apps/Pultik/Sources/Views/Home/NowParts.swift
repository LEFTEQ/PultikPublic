import SwiftUI

// The parts Home's Now column draws the queue with (copilot shell D6, D14;
// vt-7727 D7: the PR list's line). They format `NowQueue` only — ranking,
// folding and onsets are the queue's — and hold no state.

/// One line of Home's Now list: a live row, or the tombstone a resolved
/// selection leaves at its old place until the next arrow (contract
/// "Selection": ↵ never silently targets another row).
enum NowHomeRow: Identifiable, Equatable {
    case live(NowRow)
    case tombstone(NowRow)

    var row: NowRow {
        switch self {
        case let .live(row), let .tombstone(row): row
        }
    }

    /// A tombstone has its own id: the same incident can return as a live
    /// row while its tombstone still holds the selection.
    var id: String { isTombstone ? Self.goneID(row.key) : Self.id(row.key) }
    var isTombstone: Bool {
        if case .tombstone = self { return true }
        return false
    }

    static func id(_ key: String) -> String { "now:\(key)" }
    static func goneID(_ key: String) -> String { "now-gone:\(key)" }

    /// Any Home Now row's id, live or tombstone.
    static func owns(_ id: String) -> Bool { id.hasPrefix("now:") || id.hasPrefix("now-gone:") }
}

/// A selected row that left the queue, held in place until the next arrow.
struct NowTombstone: Equatable {
    let row: NowRow
    /// The visible row it draws after; nil = first.
    let after: String?
}

extension NowLane {
    var title: String {
        switch self {
        case .onFire: "On fire"
        case .waitingOnYou: "Waiting on you"
        case .due: "Due"
        case .drifting: "Drifting"
        }
    }

    var tone: Color {
        switch self {
        case .onFire: Theme.danger
        case .waitingOnYou, .due: Theme.warn
        case .drifting: Theme.idle
        }
    }
}

extension NowSeverity {
    /// A need's colour is its severity (the lane is its class): critical and
    /// emergency are danger, a warning warns, normal takes the lane's tone.
    func tone(in lane: NowLane) -> Color {
        switch self {
        case .emergency, .critical: Theme.danger
        case .warning: Theme.warn
        case .normal: lane.tone
        }
    }

    /// The line's leading glyph: the shape says it too, never colour alone.
    var symbol: String {
        switch self {
        case .emergency, .critical: "xmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .normal: "circle"
        }
    }
}

extension NowKind {
    /// The kind column's micro tag: "alert", "session", "pr".
    var tag: String {
        switch self {
        case .deployment: "prod"
        case .monitoringBlind: "blind"
        case .sentryIssue: "sentry"
        case .firingAlert: "alert"
        case .eveNotification: "eve"
        case .eveApproval: "approval"
        case .sessionWaiting: "session"
        case .failedCheck: "ci"
        case .reviewRequested: "review"
        case .stalePR: "pr"
        case .reminder: "reminder"
        case .overdueTask: "todo"
        case .staleWorkspace: "devbox"
        case .macFinding: "mac"
        case .expiry: "expiry"
        }
    }

    /// A fold's noun: "+3 sessions waiting".
    var plural: String {
        switch self {
        case .deployment: "deployments"
        case .monitoringBlind: "blind sources"
        case .sentryIssue: "issues"
        case .firingAlert: "alerts firing"
        case .eveNotification: "eve notifications"
        case .eveApproval: "approvals"
        case .sessionWaiting: "sessions waiting"
        case .failedCheck: "failed checks"
        case .reviewRequested: "reviews requested"
        case .stalePR: "stale PRs"
        case .reminder: "reminders due"
        case .overdueTask: "overdue tasks"
        case .staleWorkspace: "stale workspaces"
        case .macFinding: "Mac findings"
        case .expiry: "expiries"
        }
    }
}

/// A lane as the PR list draws a repo: its title in the lane's tone and its
/// incident count, over its lines.
struct NowLaneHeading: View {
    let summary: NowLaneSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(summary.lane.title).microLabel(summary.lane.tone)
            Text(verbatim: "\(summary.incidents)")
                .font(Theme.Typo.micro).monospacedDigit().foregroundStyle(Theme.ink2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.06), in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26, alignment: .bottom)
        .padding(.bottom, 2)
    }
}

/// One 28 pt line (D7): severity glyph · kind · the title with its meta in
/// ink3 · age. Only the selected line names its verb; a fold reads "+N
/// sessions waiting · …" and opens in place; a tombstone says the object
/// left Now.
struct NowLine: View {
    let item: NowHomeRow
    let now: Date
    let selected: Bool
    var expanded = false
    let action: () -> Void

    static let height: CGFloat = 28
    @State private var hovering = false

    var body: some View {
        let row = item.row
        Button(action: action) {
            HStack(spacing: 8) {
                glyph(row).frame(width: 14)
                Text(item.isTombstone ? "" : row.kind.tag).microLabel().frame(width: 62, alignment: .leading)
                text(row).lineLimit(1).truncationMode(.tail)
                    .opacity(item.isTombstone ? 0.55 : 1)
                Spacer(minLength: 8)
                if selected { verb(row) }
                Text(item.isTombstone ? "—" : PultikFormat.age(now.timeIntervalSince(row.lead.onset.date)))
                    .font(Theme.Typo.figure)
                    .foregroundStyle(row.lead.onset.isObserved ? Theme.ink3 : Theme.ink2)
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 46, alignment: .trailing)
            }
            // An open fold's children sit under its header.
            .padding(.leading, row.parentKey == nil ? 6 : 20)
            .padding(.trailing, 6)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.lead.lead.displayID ?? "")
    }

    @ViewBuilder
    private func glyph(_ row: NowRow) -> some View {
        if item.isTombstone {
            Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Theme.ink3)
        } else if row.shape == .fold {
            Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(Theme.ink2)
        } else {
            let severity = row.lead.severity
            Image(systemName: severity.symbol)
                .font(.system(size: 12))
                .foregroundStyle(severity == .normal ? Theme.ink3 : severity.tone(in: row.lane))
        }
    }

    /// The title, then its meta after a `·` in ink3, on one line.
    private func text(_ row: NowRow) -> Text {
        let title: String
        var meta: [String] = []
        let need = row.lead.lead
        switch (item.isTombstone, row.shape) {
        case (true, _):
            title = "Resolved · no longer in Now"
            meta.append(need.title)
        case (false, .fold):
            title = "+\(row.incidents.count) \(row.kind.plural)"
            meta.append(row.incidents.prefix(3).map(\.lead.title).joined(separator: " · "))
        case (false, .series):
            title = "\(need.title) ×\(row.incidents.count)"
            meta.append("\(row.incidents.count) objects")
        case (false, .incident):
            title = need.title
            if let subtitle = need.subtitle, !subtitle.isEmpty { meta.append(subtitle) }
            if row.lead.evidence > 1 { meta.append("\(row.lead.evidence) signals") }
            if need.onset.isObserved { meta.append("observed \(PultikFormat.clock(row.lead.onset.date))") }
        }
        if !item.isTombstone, row.shape != .fold, let deadline = row.lead.deadline {
            meta.append(deadline < now ? "overdue \(PultikFormat.date(deadline, now: now))"
                : "due \(PultikFormat.date(deadline, now: now))")
        }
        let tail = meta.isEmpty ? "" : " · " + meta.joined(separator: " · ")
        return Text("\(Text(title).foregroundStyle(Theme.ink))\(Text(tail).foregroundStyle(Theme.ink3))")
            .font(Theme.Typo.body)
    }

    /// ↵'s meaning on the selected line: the need's verb, or the fold's.
    private func verb(_ row: NowRow) -> some View {
        let title = item.isTombstone ? nil
            : row.shape == .fold ? (expanded ? "Collapse" : "Expand")
            : row.lead.lead.verb.title
        return HStack(spacing: 5) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                KbdHint("↵")
            }
        }
        .padding(.horizontal, title == nil ? 0 : 8)
        .frame(height: 20)
        .background(Color.white.opacity(title == nil ? 0 : 0.1), in: Capsule())
        .fixedSize()
    }
}

/// Needs cleared within the window (D14): out of rank and counts, each with
/// the time it cleared.
struct NowHandledSection: View {
    let entries: [ObservationLedger.Entry]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Handled · 24 h").microLabel()
                    Text(verbatim: "\(entries.count)").font(Theme.Typo.micro).monospacedDigit()
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: 26, alignment: .bottom)
                .padding(.bottom, 2)
                ForEach(entries.prefix(12), id: \.episodeID) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
                            .frame(width: 14)
                        Text(entry.need.kind.tag).microLabel().frame(width: 62, alignment: .leading)
                        Text("\(Text(entry.need.title).foregroundStyle(Theme.ink2))\(Text(entry.need.subtitle.map { " · \($0)" } ?? "").foregroundStyle(Theme.ink3))")
                            .font(Theme.Typo.body).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("cleared \(entry.clearedAt.map { PultikFormat.clock($0) } ?? "—")")
                            .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).fixedSize()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: NowLine.height)
                }
            }
        }
    }
}
