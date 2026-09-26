import SwiftUI

/// The Vitrinka widget at the top of the overview column (spec 2026-09-23
/// D5–D7, D12): the kicker with the workspace picker and its elsewhere
/// badge, one counts line, the three rows that need you most, the live
/// sessions, then recent boards filling whatever height is left. It is the
/// column's only flexible block — no scroller of its own (the column
/// scrolls only when this widget's floor cannot fit), no search; the full lists
/// are the `.work` and `.boards` pages.
struct VitrinkaWidget: View {
    let store: StatusStore
    let snapshots: [VitrinkaWorkspaceSnapshot]
    /// The widget's share of the column: the column budget less the machine
    /// widgets beneath it. The panel proposes no height (see `ScrollColumn`),
    /// so recent boards are fitted against this number, never a proposal.
    let maxHeight: CGFloat
    let onOpenWork: (String) -> Void
    let onOpenBoards: () -> Void

    /// Live sessions beyond this collapse into a note — they are the head
    /// of the widget, and the head is never dropped to make room.
    static let liveLimit = 6
    /// No column is tall enough for more recent rows than this; the rest
    /// are never built.
    static let recentCeiling = 40

    private var selected: VitrinkaWorkspaceSnapshot? {
        store.selectedVitrinkaWorkspace
    }

    var body: some View {
        // `today` rebuilds on every read — take it once per render.
        let today = selected?.today ?? []
        let live = selected?.tray.listeners.filter(\.isLive) ?? []
        let glance = VitrinkaGlance(today: today, reason: \.reason,
                                    liveQuestions: live.map(\.questionCount),
                                    elsewhere: snapshots
                                        .filter { $0.id != selected?.id && !$0.unavailable }
                                        .map(\.today))
        BudgetColumn(budget: max(0, maxHeight - Self.padding * 2)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Kicker(text: "Vitrinka", count: glance.needsYou + glance.overdue + glance.dueNow,
                       action: { onOpenWork("") },
                       actionHelp: "Open today’s work")
                workspaceMenu(elsewhere: glance.elsewhere)
            }
            .padding(.horizontal, RailRowMetrics.inset)
            if let selected {
                if selected.unavailable {
                    RailNote("Workspace unavailable")
                } else {
                    countsLine(glance)
                    if selected.workUnavailable {
                        RailNote("Some work could not be loaded")
                    }
                    ForEach(glance.top) { row in
                        let attention: Color? = row.reason == VitrinkaReason.needsYou ? .orange
                            : row.reason == VitrinkaReason.overdue ? .red : nil
                        RailRow(dot: .filled(attention ?? Color.secondary.opacity(0.4)),
                                title: row.task.title,
                                subtitle: "\(row.task.project) · \(row.reason)",
                                subtitleTone: attention,
                                help: row.task.url.absoluteString,
                                action: { NSWorkspace.shared.open(row.task.url) })
                    }
                    Kicker(text: "Live sessions", count: live.count)
                        .padding(.horizontal, RailRowMetrics.inset)
                        .padding(.top, 6)
                    ForEach(live.prefix(Self.liveLimit)) { entry in
                        VitrinkaListenerRailRow(entry: entry)
                    }
                    if live.count > Self.liveLimit {
                        RailNote("+\(live.count - Self.liveLimit) more live sessions")
                    }
                    if live.isEmpty {
                        RailNote("no session is listening")
                    }
                    let recent = recentBoards(selected, live: live)
                    if !recent.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Kicker(text: "Recent boards")
                            Spacer(minLength: 0)
                            Button(action: onOpenBoards) {
                                Text("all \(selected.tray.boards.count) ›")
                                    .font(RailRowMetrics.metaFont)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Open every recent board (.boards)")
                            Button {
                                NSWorkspace.shared.open(VitrinkaClient.shared.base
                                    .appending(path: "w/\(selected.id)/boards"))
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Open the workspace's board library on the web")
                            .accessibilityLabel("Board library on the web")
                        }
                        .padding(.horizontal, RailRowMetrics.inset)
                        .padding(.top, 6)
                        ForEach(recent) { board in
                            VitrinkaBoardRailRow(board: board)
                                .layoutValue(key: Droppable.self, value: true)
                        }
                    }
                }
            }
        }
        // Rows the budget dropped are parked far outside the window, where
        // they can neither draw nor take a click; the clip is belt and braces.
        .clipped()
        .padding(Self.padding)
    }

    private static let padding: CGFloat = 10

    /// Boards a live session holds are already on screen as sessions.
    private func recentBoards(_ snapshot: VitrinkaWorkspaceSnapshot,
                              live: [VitrinkaListening]) -> [VitrinkaBoard] {
        let listened = Set(live.map(\.scope))
        return Array(snapshot.tray.boards.filter { !listened.contains($0.slug) }.prefix(Self.recentCeiling))
    }

    // MARK: - Counts line

    private struct CountEntry: Identifiable {
        let count: Int
        let label: String
        let short: String
        let reason: String
        let tone: Color
        var id: String { reason }
    }

    /// "3 need you · 1 overdue · 2 due · 4 in progress · ?3 ›" — zeros are
    /// left out, and a line too wide for the column falls back to short
    /// labels rather than wrapping. Each count opens `.work <reason>`.
    @ViewBuilder
    private func countsLine(_ glance: VitrinkaGlance<VitrinkaWorkRow>) -> some View {
        let entries = [
            CountEntry(count: glance.needsYou, label: "need you", short: "you",
                       reason: VitrinkaReason.needsYou, tone: .orange),
            CountEntry(count: glance.overdue, label: "overdue", short: "late",
                       reason: VitrinkaReason.overdue, tone: .red),
            CountEntry(count: glance.dueNow, label: "due", short: "due",
                       reason: VitrinkaReason.dueNow, tone: .primary),
            CountEntry(count: glance.inProgress, label: "in progress", short: "wip",
                       reason: VitrinkaReason.inProgress, tone: .secondary),
        ].filter { $0.count > 0 }
        if entries.isEmpty && glance.openQuestions == 0 {
            RailNote("Nothing needs you right now")
        } else {
            ViewThatFits(in: .horizontal) {
                countsRow(entries, questions: glance.openQuestions, short: false)
                countsRow(entries, questions: glance.openQuestions, short: true)
            }
            .padding(.horizontal, RailRowMetrics.inset)
        }
    }

    private func countsRow(_ entries: [CountEntry], questions: Int, short: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Text("·").foregroundStyle(.tertiary) }
                Button { onOpenWork(entry.reason) } label: {
                    HStack(spacing: 3) {
                        Text("\(entry.count)").foregroundStyle(entry.tone)
                        Text(short ? entry.short : entry.label).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(entry.reason) work")
            }
            if questions > 0 {
                if !entries.isEmpty { Text("·").foregroundStyle(.tertiary) }
                Text("?\(questions)")
                    .foregroundStyle(Theme.eve)
                    .help("\(questions) open question\(questions == 1 ? "" : "s") on boards a live session is listening to")
            }
            Spacer(minLength: 0)
            Button { onOpenWork("") } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Open today’s work")
        }
        .font(RailRowMetrics.metaFont)
        .monospacedDigit()
        .lineLimit(1)
    }

    // MARK: - Workspace picker

    /// The workspace is a menu wearing the header's own voice — name in the
    /// row meta font, a small chevron — not the Aqua popup. Attention in the
    /// other workspaces rides beside it as an orange `+N` (D7).
    private func workspaceMenu(elsewhere: Int?) -> some View {
        Menu {
            ForEach(snapshots) { snapshot in
                Button {
                    store.setVitrinkaWorkspace(snapshot.id)
                } label: {
                    if snapshot.id == selected?.id {
                        Label(workspaceTitle(snapshot), systemImage: "checkmark")
                    } else {
                        Text(workspaceTitle(snapshot))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected?.workspace.name ?? "Workspace")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let selected, selected.unavailable {
                    Text("offline")
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                if let elsewhere {
                    Text("+\(elsewhere)")
                        .font(RailRowMetrics.metaFont)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(elsewhere.map { "Vitrinka workspace — \($0) item\($0 == 1 ? "" : "s") need you in other workspaces" }
            ?? "Vitrinka workspace — today’s work, sessions and boards are scoped to it")
        // The label names the control; the value carries what it shows,
        // so VoiceOver still announces the workspace and its count.
        .accessibilityLabel("Vitrinka workspace")
        .accessibilityValue(selected.map(workspaceTitle) ?? "none")
    }

    /// "exampleapp · 3" — the count is what needs you there (needs you, overdue,
    /// due now), the same measure the kicker and the `+N` badge use.
    private func workspaceTitle(_ snapshot: VitrinkaWorkspaceSnapshot) -> String {
        guard !snapshot.unavailable else { return "\(snapshot.workspace.name) · offline" }
        let attention = snapshot.today.filter { VitrinkaReason.attention.contains($0.reason) }.count
        return "\(snapshot.workspace.name) · \(attention)"
    }
}

/// Marks a row the widget may drop when its budget runs out.
private struct Droppable: LayoutValueKey {
    static let defaultValue = false
}

/// A VStack that drops trailing `Droppable` rows its budget has no room for,
/// keeping at least `minimumKept` of them (D12: never fewer than three
/// recent boards). Rows keep their order; a dropped row is still a subview
/// and must be placed, so it goes far below the window at zero size — a row
/// parked just under the column would stay clickable over the widget below.
private struct BudgetColumn: Layout {
    let budget: CGFloat
    var spacing: CGFloat = 4
    var minimumKept = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = visibleRows(subviews, width: proposal.width)
        let width = proposal.width ?? rows.map(\.size.width).max() ?? 0
        return CGSize(width: width, height: height(of: rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = visibleRows(subviews, width: bounds.width)
        let shown = Set(rows.map(\.index))
        var y = bounds.minY
        for row in rows {
            subviews[row.index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: bounds.width, height: row.size.height))
            y += row.size.height + spacing
        }
        for index in subviews.indices where !shown.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.maxY + Self.offstage),
                                  anchor: .topLeading, proposal: .zero)
        }
    }

    /// Further below the column than any screen is tall.
    private static let offstage: CGFloat = 100_000

    private func visibleRows(_ subviews: Subviews, width: CGFloat?) -> [(index: Int, size: CGSize)] {
        var rows: [(index: Int, size: CGSize)] = []
        var used: CGFloat = 0
        var kept = 0
        var full = false
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let step = size.height + (rows.isEmpty ? 0 : spacing)
            if subviews[index][Droppable.self] {
                // Once one row misses, every later one does too — a shorter
                // row further down must not leapfrog it.
                guard !full, kept < minimumKept || used + step <= budget else {
                    full = true
                    continue
                }
                kept += 1
            }
            rows.append((index, size))
            used += step
        }
        return rows
    }

    private func height(of rows: [(index: Int, size: CGSize)]) -> CGFloat {
        rows.reduce(0) { $0 + $1.size.height } + spacing * CGFloat(max(0, rows.count - 1))
    }
}
