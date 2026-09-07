import SwiftUI

extension TodoItem {
    /// Palette filtering — the same query that narrows PRs narrows todos.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return name.lowercased().contains(q)
            || project.lowercased().contains(q)
            || (when?.lowercased().contains(q) ?? false)
    }

}

/// The todos tab — the vitrinka todo engine at a glance, in the center
/// column where the project page also lives. Read-only by design: rows open
/// the task in vitrinka, and state changes go through `vitrinka todo` / the AI.
struct TodosPageView: View {
    let todoStore: TodoStore
    /// Pre-filtered by the caller — the panel owns query + resolved-hiding,
    /// so the page can't drift out of sync with the keyboard's item list.
    let todos: [TodoItem]
    let isSelected: (String) -> Bool
    var selectedID: String?
    let onBack: () -> Void

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Back (Esc)")
                    Text("Todos")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(VitrinkaClient.shared.myWorkURL)
                    } label: {
                        Text("vitrinka")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(VitrinkaClient.shared.myWorkURL.absoluteString)
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)

                if todos.isEmpty {
                    Text(todoStore.isReachable
                         ? "nothing here — `vitrinka todo add` or /todo in a session"
                         : "vitrinka unreachable — off the mesh, or not signed in (vitrinka login)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    Kicker(text: "Open", count: todos.count)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(todos) { todo in
                        TodoRow(todo: todo, selected: isSelected("todo:\(todo.id)"))
                            .opacity(ResolvedStore.shared.isResolved("todo:\(todo.id)") ? 0.35 : 1)
                            .id(todo.id)
                    }
                }

            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .onChange(of: selectedID) { _, id in
            // Offscreen lazy rows are located by ForEach's identity. A
            // prefixed palette ID only exists after its row is mounted.
            guard let id, id.hasPrefix("todo:"),
                  let todoID = TodoItem.ID(id.dropFirst("todo:".count)) else { return }
            withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(todoID, anchor: .bottom) }
        }
        }
        // Through the poller, never around it: the breaker decides whether
        // opening the tab is allowed to cost a request.
        .onAppear { Task { await StatusStore.shared.refreshIfStale() } }
    }
}

/// One todo line: priority tick, name, when, project — dense-panel idiom.
/// Click opens the task in vitrinka.
struct TodoRow: View {
    let todo: TodoItem
    var selected = false
    @State private var hovering = false

    private var tone: Color {
        switch todo.priority {
        case "high": .orange
        case "low": .secondary.opacity(0.6)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: todo.priority == "high" ? "circle.fill" : "circle")
                .font(.system(size: 6))
                .foregroundStyle(tone)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(todo.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let when = todo.when {
                    Text(when)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(todo.project)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { todo.open() }
        .help(todo.when ?? todo.name)
    }

    private var background: Color {
        if selected { return Theme.accent.opacity(0.16) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }
}
