import SwiftUI

/// The Vitrinka rail at the top of the left column: boards a Claude Code
/// session is currently tuned into, freshest heartbeat first, then the most
/// recently updated boards nobody is listening to (spec 2026-09-09
/// decision 5). A row opens the board (server-authoritative URL).
struct VitrinkaRail: View {
    let listening: [VitrinkaListening]
    let boards: [VitrinkaBoard]
    let onAllBoards: () -> Void

    static let recentCount = 100

    private var recent: [VitrinkaBoard] {
        let listened = Set(listening.map(\.scope))
        return Array(boards.filter { !listened.contains($0.slug) }.prefix(Self.recentCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(listening.prefix(6)) { entry in
                VitrinkaRailRow(entry: entry)
            }
            if listening.count > 6 {
                Text("+\(listening.count - 6) more listeners")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
            if listening.isEmpty {
                Text("no session is listening")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
            if !recent.isEmpty {
                HStack(spacing: 6) {
                    Text("recent")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .kerning(0.5)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button(action: onAllBoards) {
                        Text("open library ↗")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Open this workspace’s board library")
                }
                .padding(.horizontal, 8)
                .padding(.top, 3)
                ForEach(recent) { board in
                    VitrinkaBoardRailRow(board: board)
                }
            }
        }
    }
}

private struct VitrinkaRailRow: View {
    let entry: VitrinkaListening
    @State private var hovering = false

    private var subtitle: String {
        if let activity = entry.activity, entry.isLive { return activity }
        return entry.isLive ? "listening" : "last seen \(entry.lastSeen.shortAge)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.isLive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if entry.questionCount > 0 {
                Text("?\(entry.questionCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .help("\(entry.questionCount) open question\(entry.questionCount == 1 ? "" : "s")")
            }
            if entry.openCount > 0 {
                Text("\(entry.openCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { entry.open() }
        .help(entry.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A recent board in the rail: hollow dot, title, project.
private struct VitrinkaBoardRailRow: View {
    let board: VitrinkaBoard
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 6, height: 6)
            Text(board.displayTitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let project = board.project, !project.isEmpty {
                Text(project)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { board.open() }
        .help(board.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(board.displayTitle)\(board.project.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
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
