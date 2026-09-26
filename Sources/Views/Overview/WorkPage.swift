import SwiftUI

// MARK: - .work mode — today's work, full width

/// Today's work for the selected Vitrinka workspace, grouped by why it is
/// here (spec 2026-09-23 D9): the list the left column gave up for its
/// widget. The palette text after `.work` narrows by reason, title or
/// project — the widget's counts open this page as `.work overdue`.
struct WorkPage: View {
    let store: StatusStore
    let filter: String
    let onBack: () -> Void

    /// The order `VitrinkaWorkspaceSnapshot.today` ranks reasons in; a reason
    /// the server adds later lands after these rather than vanishing.
    private static let order = [VitrinkaReason.needsYou, VitrinkaReason.overdue, VitrinkaReason.dueNow,
                                VitrinkaReason.inProgress, "assigned to you", "mentioned"]

    private var rows: [VitrinkaWorkRow] {
        let today = store.selectedVitrinkaWorkspace?.today ?? []
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return today }
        return today.filter {
            $0.reason.lowercased().contains(q) || $0.task.title.lowercased().contains(q)
                || $0.task.project.lowercased().contains(q)
        }
    }

    private struct Group: Identifiable {
        let reason: String
        let rows: [VitrinkaWorkRow]
        var id: String { reason }
    }

    private var groups: [Group] {
        let rows = self.rows
        let reasons = Self.order + rows.map(\.reason).filter { !Self.order.contains($0) }
        var seen: Set<String> = []
        return reasons.compactMap { reason in
            guard seen.insert(reason).inserted else { return nil }
            let members = rows.filter { $0.reason == reason }
            return members.isEmpty ? nil : Group(reason: reason, rows: members)
        }
    }

    var body: some View {
        let selected = store.selectedVitrinkaWorkspace
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text("Today’s work")
                        .font(.system(size: 14, weight: .semibold))
                    Text(selected.map { "\($0.workspace.name) — needs you, overdue, due, in progress" }
                        ?? "no Vitrinka workspace")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if let selected, selected.unavailable {
                    note("Workspace unavailable")
                } else {
                    if selected?.workUnavailable == true {
                        note("Some work could not be loaded")
                    }
                    let groups = self.groups
                    if groups.isEmpty {
                        note(filter.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Nothing needs you right now" : "no work matches")
                    }
                    ForEach(groups) { group in
                        Kicker(text: group.reason, count: group.rows.count, tone: Self.tone(group.reason))
                            .padding(.horizontal, 8)
                            .padding(.top, 7)
                            .padding(.bottom, 2)
                        ForEach(group.rows) { row in
                            WorkRow(row: row, tone: Self.tone(row.reason))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    /// Needs you is orange and overdue red on every surface that shows them.
    private static func tone(_ reason: String) -> Color {
        switch reason {
        case VitrinkaReason.needsYou: .orange
        case VitrinkaReason.overdue: .red
        default: .secondary
        }
    }
}

/// One task line for the CENTER list: dot · title ······ project, in the
/// same dense idiom as the board and listener rows. Opens the server's task
/// URL, so a click never lands in the default workspace.
private struct WorkRow: View {
    let row: VitrinkaWorkRow
    let tone: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tone == .secondary ? Color.secondary.opacity(0.4) : tone)
                .frame(width: 6, height: 6)
                .frame(width: 14)
            Text(row.task.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.task.project)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(row.task.url) }
        .help("\(row.reason) — \(row.task.url.absoluteString)")
    }
}
