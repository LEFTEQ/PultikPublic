import SwiftUI

/// The Work module's list (WP8): today's work for the picked Vitrinka
/// workspace, grouped by why it is here (spec 2026-09-23 D9). The header
/// carries the workspace picker the left column's Vitrinka widget used to
/// own, with an orange `+N` when another workspace needs you. The field
/// narrows by reason, title or project (`.w overdue`). A row selects and
/// opens its detail; ⌘↵ opens the server's task URL.
struct WorkPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    /// A click selects the row and opens its detail.
    var onOpen: (String) -> Void = { _ in }

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
        // Eager, not lazy: the selection scrolls to `task:<id>` rows, which a
        // lazy stack could not locate before mounting them (its ForEach ids
        // are the raw task ids). Today's work is a short list.
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Today’s work")
                        .font(Theme.Typo.title)
                    Text(selected == nil ? "no Vitrinka workspace" : "needs you, overdue, due, in progress")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                    Spacer()
                    if !store.vitrinkaWorkspaces.isEmpty { workspaceMenu }
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
                            let id = Self.objectID(row)
                            // Titles are the content here: two lines (DESIGN.md §5).
                            ListRow(title: row.task.title, id: row.task.project, titleLines: 2,
                                    selected: selectedID == id, action: { onOpen(id) }) {
                                StatusDot(tone: Self.dot(row.reason))
                            }
                            .id(id)
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

    private static func dot(_ reason: String) -> Color {
        switch reason {
        case VitrinkaReason.needsYou: Theme.warn
        case VitrinkaReason.overdue: Theme.danger
        default: Theme.ink3
        }
    }

    // MARK: - Workspace picker

    /// A menu in the header's own voice, not the Aqua popup; attention in
    /// the other workspaces rides beside it as an orange `+N` (spec
    /// 2026-09-23 D7). Today's work, sessions and boards follow the pick.
    private var workspaceMenu: some View {
        let snapshots = store.vitrinkaWorkspaces
        let selected = store.selectedVitrinkaWorkspace
        let elsewhere = VitrinkaGlance(today: selected?.today ?? [], reason: \.reason, liveQuestions: [],
                                       elsewhere: snapshots.filter { $0.id != selected?.id && !$0.unavailable }
                                           .map(\.today)).elsewhere
        return Menu {
            ForEach(snapshots) { snapshot in
                Button {
                    store.setVitrinkaWorkspace(snapshot.id)
                } label: {
                    if snapshot.id == selected?.id {
                        Label(Self.workspaceTitle(snapshot), systemImage: "checkmark")
                    } else {
                        Text(Self.workspaceTitle(snapshot))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected?.workspace.name ?? "Workspace")
                    .font(Theme.Typo.figure)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                if let selected, selected.unavailable {
                    Text("offline").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                if let elsewhere {
                    Text("+\(elsewhere)")
                        .font(Theme.Typo.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.warn.opacity(0.14), in: Capsule())
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
        // The label names the control; the value carries what it shows.
        .accessibilityLabel("Vitrinka workspace")
        .accessibilityValue(selected.map(Self.workspaceTitle) ?? "none")
    }

    /// "exampleapp · 3" — what needs you there (needs you, overdue, due now), the
    /// measure the `+N` badge and the strip's Work signal use.
    private static func workspaceTitle(_ snapshot: VitrinkaWorkspaceSnapshot) -> String {
        guard !snapshot.unavailable else { return "\(snapshot.workspace.name) · offline" }
        let attention = snapshot.today.filter { VitrinkaReason.attention.contains($0.reason) }.count
        return "\(snapshot.workspace.name) · \(attention)"
    }
}

/// Today's work, grouped by reason, as drawn — `task:<id>`, the object Now's
/// ripe todos open. Todos, schedule and boards stay on `.t`, `.s` and `.b`.
extension WorkPage: ModulePage {
    static func objectID(_ row: VitrinkaWorkRow) -> String { "task:\(row.id)" }

    var objects: [ModuleObject] {
        groups.flatMap(\.rows).map { row in
            let status = switch row.reason {
            case VitrinkaReason.needsYou: Chip(row.reason, .warn)
            case VitrinkaReason.overdue: Chip(row.reason, .danger)
            default: Chip(row.reason, .neutral)
            }
            return ModuleObject(id: Self.objectID(row), title: row.task.title, status: status,
                                meta: row.task.project, symbol: "checklist", project: row.task.project,
                                // The server's task URL: a click never lands in the default workspace.
                                url: row.task.url,
                                facts: [.init(label: "project", value: row.task.project),
                                        .init(label: "reason", value: row.reason),
                                        .init(label: "task", value: row.task.url.absoluteString)])
        }
    }
}
