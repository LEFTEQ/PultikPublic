import SwiftUI

/// The vitrinka listeners in the services rail: boards a Claude Code session
/// is currently tuned into, freshest heartbeat first. A row opens the board
/// (server-authoritative URL) where the work actually lives.
struct VitrinkaRail: View {
    let listening: [VitrinkaListening]

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
        }
    }
}

private struct VitrinkaRailRow: View {
    let entry: VitrinkaListening
    @State private var hovering = false

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
                Text(entry.isLive ? "listening" : "last seen \(entry.lastSeen.shortAge)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
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
        var parts = [scope]
        if !session.isEmpty { parts.append(session) }
        parts.append("\(openCount) open work item\(openCount == 1 ? "" : "s")")
        return parts.joined(separator: " — ")
    }
}
