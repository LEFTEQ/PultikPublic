import SwiftUI

extension StatusPanelView {
    @ViewBuilder
    var commandResults: some View {
        if let notice = commandNotice {
            HStack(spacing: 6) {
                Image(systemName: notice.isFailure ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 10))
                Text(notice.text)
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(notice.isFailure ? Color.orange : .secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
        if todosMatch, !showTodos {
            Button {
                query = ""
                showTodos = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text("Todos")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("vitrinka — \(todoStore.openTodos.count) open")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if selectedID == nil || isSelected("todos") { KeyChip("↵") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                selectedID == nil || isSelected("todos")
                    ? Theme.accentSoft.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        if let project = store.matchProject(query), activeProject == nil {
            Button {
                query = ""
                activeProject = project
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(project.title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text("project page — PRs, prod, services, links")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if selectedID == nil || isSelected("project:\(project.id)") { KeyChip("↵") }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                // With nothing arrowed-to, ↵ still lands here — keep the cue.
                selectedID == nil || isSelected("project:\(project.id)")
                    ? Theme.accentSoft.opacity(0.6) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
        let commands = QuickCommand.matching(query)
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    Button {
                        query = ""
                        command.run()
                        AppDelegate.shared?.closePanel()
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: command.systemImage)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Text(command.title)
                                .font(.system(size: 12.5, weight: .medium))
                            Text(command.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if commandIsEnterTarget(command, index: index) { KeyChip("↵") }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        commandIsHighlighted(command, index: index)
                            ? Theme.accentSoft.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    /// Where an un-arrowed ↵ goes: `submitPalette` prefers a project match, so
    /// the first command only owns ↵ when there is no project to beat it.
    func commandIsEnterTarget(_ command: QuickCommand, index: Int) -> Bool {
        if selectedID != nil { return isSelected("cmd:\(command.id)") }
        return index == 0 && store.matchProject(query) == nil
    }

    func commandIsHighlighted(_ command: QuickCommand, index: Int) -> Bool {
        if selectedID != nil { return isSelected("cmd:\(command.id)") }
        return index == 0
    }

    // MARK: - Links strip (search results)

    /// Saved links matching the palette query, pinned at the foot of the
    /// centre column while searching: capped at four rows. At rest the links
    /// live at the right rail's foot.
    @ViewBuilder
    var linksStrip: some View {
        let items = filteredLinks
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Kicker(text: "Links", count: items.count)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
                ForEach(items.prefix(4)) { link in
                    LinkStripRow(link: link, selected: isSelected("link:\(link.id)")) {
                        openLink(link)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            hairline
        }
    }

    var filteredLinks: [SavedLink] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ordered = links.ordered
        guard !q.isEmpty, !q.hasPrefix("/") else { return ordered }
        return ordered.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    func openLink(_ link: SavedLink) {
        links.recordOpen(id: link.id)
        Self.open(link.url)
    }

    // MARK: - PR inbox (fixed repo order)

    @ViewBuilder
    var inbox: some View {
        let entries = filteredInbox
        if entries.isEmpty {
            // Silent while the archive has (or is fetching) something to say —
            // "no matches" above a list of matches would be a lie.
            if searchActive && (store.isSearching || store.isSearchingSentry
                || !store.searchMatches.isEmpty || !store.sentryMatches.isEmpty)
            {
                EmptyView()
            } else if filteredTodos.isEmpty && filteredNotes.isEmpty {
                Text(query.isEmpty
                    ? "no open PRs"
                    : "no matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            // No PRs doesn't mean nothing to show — todos keep their
            // section. Live sessions are the Sessions module's.
            todosSection
        } else {
            // Fixed order (2026-07-29): one section per repo, always in the
            // same sequence (preferences.repoOrder, rest by recency) — the
            // eye knows where each project lives. Attention still shows as
            // an orange kicker when a repo has a needs-you PR, but it never
            // moves anything.
            VStack(alignment: .leading, spacing: 2) {
                let capped = PRListPage.cappedRepos(store)
                ForEach(PRListPage.groups(entries), id: \.slug) { group in
                    PRRepoSection(group: group, selectedID: selectedID, capped: capped.contains(group.slug))
                }
                todosSection
            }
        }
    }

    /// The inbox narrowed by the global query — the PRs module draws the
    /// same rows (`PRListPage`).
    var filteredInbox: [StatusStore.InboxPR] {
        PRListPage.inbox(store.inbox, hidden: hiddenResolved, matching: query)
    }

    // MARK: - Todos (main list section)

    /// Open todos in the main list, below the PR inbox — the tab is the full
    /// view (with broken-file diagnostics); this is the glance.
    @ViewBuilder
    var todosSection: some View {
        let todos = filteredTodos
        if !todos.isEmpty {
            Kicker(text: "Todos", count: todos.count,
                   action: { enterMode(.todos) },
                   actionHelp: "Open all todos")
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
            ForEach(todos) { todo in
                TodoRow(todo: todo, selected: isSelected("todo:\(todo.id)"))
                    .opacity(resolvedStore.isResolved("todo:\(todo.id)") ? 0.35 : 1)
                    .id("todo:\(todo.id)")
            }
        }
    }

    // MARK: - Search results (all PRs, incl. merged & closed)

    var searchActive: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// The archive: everything GitHub knows about, fetched only while you are
    /// searching. Empty palette → this section does not exist.
    var searchSection: some View {
        PRArchiveSection(store: store, active: searchActive, selectedID: selectedID)
    }

    // MARK: - Sentry search results (org-wide, incl. resolved & non-prod)

    /// Sentry's answer to the typed query — short ids ("EXAMPLEAPP-API-86") resolve
    /// exactly, anything else is full text. Same contract as the PR archive:
    /// exists only while searching, hides what the prod strip already shows.
    @ViewBuilder
    var sentrySection: some View {
        let matches = store.sentryMatches
        if searchActive, store.isSearchingSentry || !matches.isEmpty {
            HStack(spacing: 6) {
                Kicker(text: "Sentry", count: matches.count,
                       action: { OverviewURL.open(OverviewURL.sentryIssues) },
                       actionRole: .link,
                       actionHelp: "Open the Sentry issue overview")
                if store.isSearchingSentry {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(height: 10)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)

            ForEach(matches) { prodIssue in
                ProdIssueRow(prodIssue: prodIssue,
                             selected: isSelected("sentry:\(prodIssue.id)"), rowID: "sentry:\(prodIssue.id)")
                    .id("sentry:\(prodIssue.id)")
            }
        }
    }

    // MARK: - Notes (search hits only)

    /// Notes matching the query, at the TAIL of the results — a note you wrote
    /// five minutes ago must never outrank the PR you were hunting for. ↵
    /// expands the hit in place; the 680px column is where a long note reads.
    @ViewBuilder
    var notesSection: some View {
        let matches = filteredNotes
        if !matches.isEmpty {
            Kicker(text: "Notes", count: matches.count,
                   action: { enterMode(.notes) },
                   actionHelp: "Open all notes")
                .padding(.horizontal, 8)
                .padding(.top, 7)
                .padding(.bottom, 2)
            ForEach(matches) { note in
                NoteRow(
                    note: note,
                    style: .wide,
                    selected: isSelected("note:\(note.id)"),
                    expanded: expandedNoteID == note.id,
                    onToggle: { toggleNote(note) },
                    onRemove: { notes.remove(id: note.id) },
                    onCopy: { copyNote(note) }
                )
                .id("note:\(note.id)")
            }
        }
    }

    func copyNote(_ note: SavedNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        commandNotice = .ok("copied the note")
    }
}

/// One sticky-strip link row: same dense idiom as the rail's rows, plus the
/// keyboard-selection chrome the strip's siblings (prod, PRs, todos) carry.
private struct LinkStripRow: View {
    let link: SavedLink
    var selected = false
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "link")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(link.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(link.url)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
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
        .onTapGesture(perform: onOpen)
        .help("\(link.url) — /rm-link \(link.title) to remove")
    }
}

private struct KeyChip: View {
    let label: String
    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}
