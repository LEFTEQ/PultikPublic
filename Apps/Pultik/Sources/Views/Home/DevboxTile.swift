import SwiftUI

/// Home's Devbox tile (panel Home D7, 2026-10-07): one row per workspace —
/// running ones first, heaviest first, then parked by how long they have
/// slept — with cpu, memory and age on fixed columns, a stale age in orange.
/// The verbs, the metric strip and the clear flows stay on `.devbox`; a row
/// opens that page narrowed to it. Formats `devboxWorkspaces` only.
struct DevboxTile: View {
    let store: StatusStore
    /// `.devbox` narrowed by the filter ("" for all).
    let onOpen: (String) -> Void

    static func isShown(store: StatusStore) -> Bool {
        store.isSectionVisible("devbox") && store.devboxSummary != nil
    }

    private enum Column {
        static let cpu: CGFloat = 38
        static let memory: CGFloat = 52
        static let age: CGFloat = 34
    }

    /// Every running workspace, then the most recently parked few — the
    /// pile of parked ones is a count that opens `.devbox`, not a list.
    private static let parkedShown = 6

    private var running: [DevboxWorkspace] {
        store.devboxWorkspaces.filter { !$0.isParked }.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    private var parked: [DevboxWorkspace] {
        store.devboxWorkspaces.filter(\.isParked)
            .sorted { ($0.parkedAt ?? .distantPast) > ($1.parkedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TileHeader(title: "Devbox", caption: caption,
                       captionTone: staleCount > 0 ? .orange : .secondary,
                       action: { onOpen("") }, actionHelp: "Every workspace — .devbox")
            columnHeads
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(running) { row($0) }
                    ForEach(parked.prefix(Self.parkedShown)) { row($0) }
                    if parked.count > Self.parkedShown {
                        morePile(parked.count - Self.parkedShown)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }

    private var staleCount: Int { store.devboxWorkspaces.filter(isStale).count }

    private var caption: String {
        let running = store.devboxWorkspaces.filter { !$0.isParked }.count
        var parts = ["\(running) running"]
        let parked = store.devboxWorkspaces.count - running
        if parked > 0 { parts.append("\(parked) parked") }
        if staleCount > 0 { parts.append("\(staleCount) stale") }
        return parts.joined(separator: " · ")
    }

    /// Held workspaces are never stale: `gc --retire-stale` does not touch them.
    private func isStale(_ workspace: DevboxWorkspace) -> Bool {
        guard workspace.isParked, !workspace.hold, let parkedAt = workspace.parkedAt else { return false }
        return Date().timeIntervalSince(parkedAt) > DevboxGlance.staleAfter
    }

    private var columnHeads: some View {
        HStack(spacing: 8) {
            Text("workspace").frame(maxWidth: .infinity, alignment: .leading)
            Text("cpu").frame(width: Column.cpu, alignment: .trailing)
            Text("mem").frame(width: Column.memory, alignment: .trailing)
            Text("age").frame(width: Column.age, alignment: .trailing)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, RailRowMetrics.inset)
    }

    private func row(_ workspace: DevboxWorkspace) -> some View {
        let stale = isStale(workspace)
        let since = workspace.isParked ? workspace.parkedAt : workspace.created
        return Button { onOpen(workspace.name) } label: {
            HStack(spacing: 8) {
                HStack(spacing: RailRowMetrics.dotGap) {
                    Group {
                        if workspace.isParked {
                            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                        } else {
                            Circle().fill(workspace.failedApps > 0 ? Color.orange : .green)
                        }
                    }
                    .frame(width: RailRowMetrics.dotSize, height: RailRowMetrics.dotSize)
                    Text(workspace.shortName)
                        .font(.system(size: 11, weight: workspace.isParked ? .regular : .medium))
                        .foregroundStyle(workspace.isParked ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if workspace.hold {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("held")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                cell(workspace.isParked ? "—" : "\(Int(workspace.cpuPercent.rounded()))%", width: Column.cpu)
                cell(workspace.isParked ? "—" : workspace.memoryLabel, width: Column.memory)
                cell(since?.shortAge ?? "—", width: Column.age, tone: stale ? .orange : nil)
            }
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.vertical, RailRowMetrics.verticalInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(workspace.name) — open on .devbox")
    }

    private func morePile(_ count: Int) -> some View {
        let stale = parked.dropFirst(Self.parkedShown).filter(isStale).count
        return Button { onOpen("") } label: {
            HStack(spacing: 4) {
                Text("+\(count) parked")
                if stale > 0 {
                    Text("· \(stale) stale").foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(RailRowMetrics.metaFont)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Every workspace, the clear and the reaper — .devbox")
    }

    private func cell(_ text: String, width: CGFloat, tone: Color? = nil) -> some View {
        Text(text)
            .font(RailRowMetrics.metaFont)
            .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}
