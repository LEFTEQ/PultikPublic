import SwiftUI

struct VitrinkaDailyRail: View {
    let store: StatusStore
    let snapshots: [VitrinkaWorkspaceSnapshot]
    let maxHeight: CGFloat
    @State private var search = ""
    @State private var showAllTasks = false

    private var selected: VitrinkaWorkspaceSnapshot? {
        store.selectedVitrinkaWorkspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The workspace is a menu wearing the rail's own label, not the
            // Aqua popup: name in body weight, count in mono, a small chevron.
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
                HStack(spacing: 5) {
                    Text(selected?.workspace.name ?? "Workspace")
                        .font(.system(size: 12, weight: .semibold))
                    if let selected {
                        Text(selected.unavailable ? "offline" : "\(selected.today.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.horizontal, 2)
            // The label names the control; the value carries what it shows,
            // so VoiceOver still announces the workspace and its count.
            .accessibilityLabel("Vitrinka workspace")
            .accessibilityValue(selected.map(workspaceTitle) ?? "none")
            RailSearchField(prompt: "Find tasks and boards", text: $search)
            if let selected {
                // Filtered once: the headings count what the search left, not
                // what the workspace holds, or a filtered list reads as broken.
                let today = selected.today.filter { matches($0.task.title + " " + $0.task.project) }
                let listeners = selected.tray.listeners.filter { matches($0.title) }
                let boards = selected.tray.boards.filter {
                    matches($0.title + " " + $0.slug + " " + ($0.project ?? ""))
                }
                ScrollColumn(maxHeight: max(80, maxHeight - Self.chrome)) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if selected.unavailable {
                            Text("Workspace unavailable").foregroundStyle(.secondary)
                        } else {
                            Kicker(text: "Today’s work", count: today.count)
                            if selected.workUnavailable {
                                Text("Some work could not be loaded")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            ForEach(Array(today
                                .prefix(showAllTasks || !search.isEmpty ? Int.max : 8))) { row in
                                Button { NSWorkspace.shared.open(row.task.url) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.task.title).font(.system(size: 11)).lineLimit(2)
                                        Text("\(row.task.project) · \(row.reason)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(row.reason == "needs you" || row.reason == "overdue" ? Color.orange : .secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(row.task.url.absoluteString)
                            }
                            if today.isEmpty && !selected.workUnavailable {
                                Text(search.isEmpty ? "Nothing needs you right now" : "No match")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            if today.count > 8 && search.isEmpty {
                                Button(showAllTasks ? "Show fewer tasks" : "Show all \(today.count) tasks") {
                                    showAllTasks.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Divider().padding(.vertical, 4)
                            Kicker(text: "Live sessions", count: listeners.count)
                            VitrinkaRail(listening: listeners,
                                         boards: boards,
                                         onAllBoards: {
                                             NSWorkspace.shared.open(VitrinkaClient.shared.base
                                                .appending(path: "w/\(selected.id)/boards"))
                                         })
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// The workspace picker, the search field and their spacing sit above the
    /// scroller; only the rest of the budget is the list's to scroll in.
    private static let chrome: CGFloat = 70

    private func workspaceTitle(_ snapshot: VitrinkaWorkspaceSnapshot) -> String {
        "\(snapshot.workspace.name) · \(snapshot.unavailable ? "offline" : String(snapshot.today.count))"
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }
}
