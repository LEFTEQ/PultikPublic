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
            Picker("Workspace", selection: Binding(get: { selected?.id ?? "" }, set: { store.setVitrinkaWorkspace($0) })) {
                ForEach(snapshots) { snapshot in
                    Text("\(snapshot.workspace.name) · \(snapshot.unavailable ? "offline" : String(snapshot.today.count))")
                        .tag(snapshot.id)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Vitrinka workspace")
            TextField("Find tasks and boards", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
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

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }
}
