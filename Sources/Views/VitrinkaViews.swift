import SwiftUI

/// A live session in the Vitrinka widget: the board a Claude Code session is
/// tuned into, its latest activity underneath, open questions and items at
/// the edge (spec 2026-09-09 decision 5). Opens the board (server URL).
struct VitrinkaListenerRailRow: View {
    let entry: VitrinkaListening

    var body: some View {
        RailRow(dot: .filled(entry.isLive ? Color.green : Color.secondary.opacity(0.4)),
                title: entry.title,
                subtitle: entry.subtitle,
                badges: entry.badges,
                help: entry.helpText,
                action: entry.open)
    }
}

/// A recent board nobody is listening to — hollow dot, project at the edge.
/// The widget stacks as many as its height allows (spec 2026-09-23 D12).
struct VitrinkaBoardRailRow: View {
    let board: VitrinkaBoard

    var body: some View {
        RailRow(dot: .hollow,
                title: board.displayTitle,
                meta: board.project.flatMap { $0.isEmpty ? nil : $0 },
                help: board.helpText,
                action: board.open)
    }
}

private extension VitrinkaListening {
    var subtitle: String {
        if let activity, isLive { return activity }
        return isLive ? "listening" : "last seen \(lastSeen.shortAge)"
    }

    var badges: [RailBadge] {
        var out: [RailBadge] = []
        if questionCount > 0 {
            out.append(RailBadge(text: "?\(questionCount)", tone: Theme.accent,
                                 help: "\(questionCount) open question\(questionCount == 1 ? "" : "s")"))
        }
        if openCount > 0 {
            out.append(RailBadge(text: "\(openCount)", tone: .orange,
                                 help: "\(openCount) open item\(openCount == 1 ? "" : "s")"))
        }
        return out
    }
}

/// One board line for the CENTER list (`.b` mode): title ······ project.
struct VitrinkaBoardRow: View {
    let board: VitrinkaBoard
    var selected = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(board.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let project = board.project, !project.isEmpty {
                Text(project)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(selected ? Theme.accent.opacity(0.16)
                    : hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { board.open() }
        .help(board.helpText)
    }
}

extension VitrinkaBoard {
    @MainActor
    func open() {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Palette filtering — title, slug or project.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || slug.lowercased().contains(q)
            || (project?.lowercased().contains(q) ?? false)
    }

    var helpText: String {
        var parts = [slug]
        if let project, !project.isEmpty { parts.append(project) }
        parts.append(url)
        return parts.joined(separator: " — ")
    }
}

/// One listener line for the CENTER list — the same dense single-line idiom
/// as PR rows: live dot · board title ······ open-count, listening chip.
/// The session (host:port) lives in the hover tooltip, not the row.
struct VitrinkaListRow: View {
    let entry: VitrinkaListening
    var selected = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(entry.isLive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .frame(width: 14)
            Text(entry.title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 8)

            if entry.openCount > 0 {
                Text("\(entry.openCount) open")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(entry.isLive ? "listening" : "gone \(entry.lastSeen.shortAge)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(selected ? Theme.accent.opacity(0.16)
                    : hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { entry.open() }
        .help(entry.helpText)
    }
}

extension VitrinkaListening {
    @MainActor
    func open() {
        guard let url = url.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Palette filtering — the same query that narrows PRs narrows listeners.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || scope.lowercased().contains(q)
    }

    var helpText: String {
        var parts = [scopeKind == "all" ? "every board" : scope]
        if !actor.isEmpty { parts.append(actor) }
        if !session.isEmpty { parts.append(session) }
        parts.append("\(openCount) open work item\(openCount == 1 ? "" : "s")")
        if questionCount > 0 { parts.append("\(questionCount) open question\(questionCount == 1 ? "" : "s")") }
        if let activity { parts.append(activity) }
        return parts.joined(separator: " — ")
    }
}
