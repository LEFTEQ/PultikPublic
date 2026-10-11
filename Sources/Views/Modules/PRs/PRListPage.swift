import SwiftUI

/// The PRs module's list (WP5): the inbox in fixed repo order, then — from
/// two typed characters — every PR GitHub knows, merged and closed included.
/// ↵ opens the GitHub mini app (`PRDetailContent`); resting the cursor on a
/// row warms its detail. The global results draw the same sections
/// (`PRRepoSection`, `PRArchiveSection`).
struct PRListPage: View {
    let store: StatusStore
    let filter: String
    /// Resolved before this summon: hidden, as on every surface.
    let hidden: Set<String>
    var selectedID: String?

    /// The inbox narrowed by `query`, resolved-and-hidden PRs gone. `.` and
    /// `/` are command surfaces, never PR search text.
    static func inbox(_ inbox: [StatusStore.InboxPR], hidden: Set<String>, matching query: String) -> [StatusStore.InboxPR] {
        let visible = inbox.filter { !hidden.contains("pr:\($0.id)") }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, !q.hasPrefix("."), !q.hasPrefix("/") else { return visible }
        return visible.filter { entry in
            entry.repoSlug.lowercased().contains(q)
                || entry.info.pr.title.lowercased().contains(q)
                || "#\(entry.info.pr.number)".contains(q)
                || entry.info.pr.head.ref.lowercased().contains(q)
        }
    }

    /// Consecutive inbox entries bucketed by repo — `store.inbox` already
    /// carries the fixed repo order, so grouping just preserves it.
    static func groups(_ entries: [StatusStore.InboxPR]) -> [PRRepoSection.Repo] {
        var groups: [PRRepoSection.Repo] = []
        for entry in entries {
            if groups.last?.slug == entry.repoSlug {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(PRRepoSection.Repo(slug: entry.repoSlug, name: entry.repoName, entries: [entry]))
            }
        }
        return groups
    }

    private var entries: [StatusStore.InboxPR] {
        Self.inbox(store.inbox, hidden: hidden, matching: filter)
    }

    /// Repos whose open list filled `GitHubEstate.openLimit`: their count is
    /// a floor wherever their section draws.
    static func cappedRepos(_ store: StatusStore) -> Set<String> {
        Set(store.repos.filter { $0.prs.count >= GitHubEstate.openLimit }.map(\.slug))
    }

    /// The archive is searched once two characters are typed.
    private var searching: Bool {
        filter.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        let entries = entries
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                // Silent while the archive has (or is fetching) something to
                // say — "no match" above a list of matches would be a lie.
                if entries.isEmpty, !(searching && (store.isSearching || !store.searchMatches.isEmpty)) {
                    RailNote(filter.isEmpty ? "No open pull requests" : "No match")
                        .padding(.top, 10)
                }
                let capped = Self.cappedRepos(store)
                ForEach(Self.groups(entries), id: \.slug) { group in
                    PRRepoSection(group: group, selectedID: selectedID, capped: capped.contains(group.slug))
                }
                PRArchiveSection(store: store, active: searching, selectedID: selectedID)
            }
            .padding(8)
        }
        // D8: prefetch on explicit selection only, where the cursor rests —
        // walking past rows costs nothing.
        .task(id: selectedID) {
            guard let selectedID, let ref = ref(for: selectedID) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let conversation = try? await store.prConversation(ref),
                  !Task.isCancelled else { return }
            _ = try? await store.prFiles(ref, of: conversation)
        }
    }

    /// The PR behind an object id: an inbox row by its database id, an
    /// archive hit by `repo#number`.
    func ref(for id: String) -> PRRef? {
        if id.hasPrefix("pr:"), let databaseID = Int(id.dropFirst(3)),
           let entry = store.inbox.first(where: { $0.id == databaseID }) {
            return PRRef(repo: entry.repoSlug, number: entry.info.pr.number)
        }
        if id.hasPrefix("archive:"), let hit = store.searchMatches.first(where: { "archive:\($0.id)" == id }) {
            return PRRef(repo: hit.repoSlug, number: hit.number)
        }
        return nil
    }
}

extension PRListPage: ModulePage {
    var objects: [ModuleObject] {
        let now = Date()
        let inbox = Self.groups(entries).flatMap(\.entries).map { entry in
            let info = entry.info
            // Checks and review lead the detail's own overview strip.
            var facts = [ModuleObject.Fact(label: "repo", value: entry.repoSlug),
                         .init(label: "branch", value: info.pr.head.ref)]
            if let updated = info.pr.updatedAt { facts.append(.init(label: "updated", value: PultikFormat.ago(updated, now: now))) }
            if let status = entry.eveSession?.status { facts.append(.init(label: "eve session", value: status)) }
            return ModuleObject(id: "pr:\(entry.id)", title: info.pr.title, label: "#\(info.pr.number)",
                                status: Self.status(info), meta: entry.repoName, symbol: "arrow.triangle.pull",
                                project: entry.repoName, url: URL(string: info.pr.htmlUrl),
                                context: [Chip(info.pr.head.ref, .neutral, symbol: "arrow.triangle.branch")],
                                facts: facts)
        }
        let archive: [ModuleObject] = searching ? store.searchMatches.map { pr -> ModuleObject in
            var facts = [ModuleObject.Fact(label: "repo", value: pr.repoSlug),
                         .init(label: "state", value: pr.outcome.label),
                         .init(label: "updated", value: PultikFormat.ago(pr.updatedAt, now: now))]
            if let branch = pr.branch { facts.insert(.init(label: "branch", value: branch), at: 1) }
            return ModuleObject(id: "archive:\(pr.id)", title: pr.title, label: "#\(pr.number)",
                                status: Chip(pr.outcome.label, .neutral), meta: pr.repoName,
                                symbol: "arrow.triangle.pull", project: pr.repoName, url: URL(string: pr.url),
                                facts: facts)
        } : []
        return inbox + archive
    }

    /// The mini app's diff is lazy items of its own scroller.
    var detailScrollsItself: Bool { true }

    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let ref = ref(for: object.id) {
            PRDetailContent(store: store, ref: ref).id(ref)
        }
    }

    private static func status(_ info: PRInfo) -> Chip {
        if info.isDraft { return Chip("draft", .dashed) }
        switch (info.state, info.review) {
        case (.failure, _): return Chip("checks failed", .failing)
        case (_, .changesRequested): return Chip("changes requested", .warn)
        case (.running, _): return Chip("checks running", .neutral)
        case (_, .approved): return Chip("approved", .ok)
        default: return Chip("open", .neutral)
        }
    }

}

/// One repo of the inbox: its heading (a link to the repo's pull requests)
/// and its PR rows. Attention tints the heading; it never moves a repo.
struct PRRepoSection: View {
    struct Repo {
        let slug: String
        let name: String
        var entries: [StatusStore.InboxPR]
    }

    let group: Repo
    var selectedID: String?
    /// The estate read stopped at `GitHubEstate.openLimit` open PRs: the
    /// repo may hold more, so its count reads `5+`, never complete.
    var capped = false

    var body: some View {
        Kicker(
            text: group.name,
            count: group.entries.count,
            countIsFloor: capped,
            tone: group.entries.contains { $0.info.attentionRank == 0 } ? .orange : .secondary,
            action: { OverviewURL.open(OverviewURL.repoPulls(group.slug)) },
            actionRole: .link,
            actionHelp: capped
                ? "The newest \(GitHubEstate.openLimit) open PRs — open all of \(group.slug)'s on GitHub"
                : "Open \(group.slug) pull requests on GitHub"
        )
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)
        ForEach(group.entries) { entry in
            InboxPRRow(entry: entry, selected: selectedID == "pr:\(entry.id)")
                .opacity(ResolvedStore.shared.isResolved("pr:\(entry.id)") ? 0.35 : 1)
                .id("pr:\(entry.id)")
        }
    }
}

/// The archive: everything GitHub knows about, fetched only while you are
/// searching (`active`). Not searching → the section does not exist.
struct PRArchiveSection: View {
    let store: StatusStore
    let active: Bool
    var selectedID: String?

    var body: some View {
        let matches = store.searchMatches
        if active, store.isSearching || !matches.isEmpty || store.searchError != nil {
            HStack(spacing: 6) {
                Kicker(text: store.searchIsPartial ? "Saved PRs · partial coverage" : "PR search", count: matches.count,
                       action: { OverviewURL.open(OverviewURL.githubPulls) },
                       actionRole: .link,
                       actionHelp: "Open the GitHub pull-request overview")
                if store.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(height: 10)
                }
                Spacer()
                if let fetchedAt = store.searchFetchedAt {
                    Text(fetchedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Cached PR metadata; last fetched \(fetchedAt.formatted())")
                }
                if let error = store.searchError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                        .help(error)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ForEach(matches) { pr in
                ArchivedPRRow(pr: pr, selected: selectedID == "archive:\(pr.id)")
                    .id("archive:\(pr.id)")
            }
        }
    }
}
