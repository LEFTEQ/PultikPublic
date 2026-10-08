import SwiftUI

/// Home's Pull requests tile (panel Home D3, 2026-10-07): needs-you rows
/// grouped by repo in the inbox's fixed order, each repo's ready PRs as one
/// counted line that opens in place, and one drafts · stale fold at the foot.
/// Expansion lives with the panel, which walks `PRDigest.visible(expanded:)`
/// for keyboard selection — so what the arrows reach is what is drawn.
struct PRDigestTile: View {
    let digest: PRDigest<StatusStore.InboxPR>
    @Binding var expanded: Set<String>
    var selectedID: String?
    var isResolved: (String) -> Bool = { _ in false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TileHeader(title: "Pull requests", count: digest.needsYouCount,
                       tone: digest.needsYouCount > 0 ? .orange : .secondary,
                       caption: caption)
            if digest.total == 0 {
                Text("no open PRs")
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(digest.repos, id: \.slug) { repo in
                                repoSection(repo)
                            }
                            if !digest.drafts.isEmpty || !digest.stale.isEmpty {
                                fold
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }

    private var caption: String {
        var parts = ["\(digest.total) open"]
        if digest.readyCount > 0 { parts.append("\(digest.readyCount) ready") }
        if !digest.drafts.isEmpty { parts.append("\(digest.drafts.count) draft\(digest.drafts.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func repoSection(_ repo: PRDigest<StatusStore.InboxPR>.Repo) -> some View {
        let name = repo.slug.split(separator: "/").last.map(String.init) ?? repo.slug
        Button { OverviewURL.open(OverviewURL.repoPulls(repo.slug)) } label: {
            HStack(spacing: 4) {
                Text(name)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.5)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(repo.slug) pull requests on GitHub")
        .padding(.top, 6)
        .padding(.horizontal, 2)
        ForEach(repo.needsYou) { row($0) }
        if !repo.ready.isEmpty {
            foldLine(key: repo.slug, symbol: "checkmark.circle.fill", tone: .green,
                     label: "\(repo.ready.count) ready",
                     detail: repo.ready.map { "#\($0.info.pr.number)" }.joined(separator: " "))
            if expanded.contains(repo.slug) {
                ForEach(repo.ready) { row($0) }
            }
        }
    }

    @ViewBuilder
    private var fold: some View {
        let parts = [digest.drafts.isEmpty ? nil : "\(digest.drafts.count) draft\(digest.drafts.count == 1 ? "" : "s")",
                     digest.stale.isEmpty ? nil : "\(digest.stale.count) stale"].compactMap { $0 }
        Divider().overlay(Theme.hairline).padding(.vertical, 4)
        foldLine(key: PRDigest<StatusStore.InboxPR>.foldKey, symbol: "tray", tone: .secondary,
                 label: parts.joined(separator: " · "), detail: "no update in 7 d, or not ready")
        if expanded.contains(PRDigest<StatusStore.InboxPR>.foldKey) {
            ForEach(digest.drafts + digest.stale) { row($0) }
        }
    }

    private func row(_ entry: StatusStore.InboxPR) -> some View {
        InboxPRRow(entry: entry, selected: selectedID == "pr:\(entry.id)", showsRepo: false)
            .opacity(isResolved("pr:\(entry.id)") ? 0.35 : 1)
            .id("pr:\(entry.id)")
    }

    private func foldLine(key: String, symbol: String, tone: Color, label: String, detail: String) -> some View {
        let open = expanded.contains(key)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if open { expanded.remove(key) } else { expanded.insert(key) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tone)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}
