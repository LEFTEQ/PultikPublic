import SwiftUI

extension StatusPanelView {
    /// Open todos narrowed by the palette — one query, every surface.
    var filteredTodos: [TodoItem] {
        todoStore.openTodos.filter {
            $0.matches(query) && !hiddenResolved.contains("todo:\($0.id)")
        }
    }

    /// Notes matching the typed query. Unlike todos and listeners, notes have
    /// NO resting section: the rail is their glance, so they only enter the
    /// center column when you actually search for one.
    var filteredNotes: [SavedNote] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.hasPrefix("."), !q.hasPrefix("/") else { return [] }
        return notes.ordered.filter { $0.matches(q) }
    }

    // MARK: - Palette

    var palette: some View {
        return HStack(spacing: 10) {
            // Every write goes through the router, which applies the dot
            // grammar on the spot: `.c` is CI's scope chip before the next key.
            TextField(paletteHint, text: Binding(get: { router.text }, set: { router.type($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                // One line, scrolling sideways: a pasted paragraph used to
                // wrap inside the fixed-height bar with its first line clipped.
                // Long text is read where it lands (the `.notes` draft row);
                // ⌘V (`pasteMultiline`) keeps its newlines.
                .lineLimit(1)
                .focused($paletteFocused)
                .onSubmit(submitPalette)
                .onChange(of: query) { _, new in
                    let global = router.module == nil
                    // New query, new result list — a stale index would point at
                    // a different PR than the one that was highlighted. A
                    // module's filter keeps its selection: it is held by id.
                    if global { selectedID = nil }
                    // A successful slash verb clears the field itself and
                    // the notice is its only feedback — only new typing
                    // retires it.
                    if !new.isEmpty { commandNotice = nil }
                    pathTarget = global ? Self.detectPath(new) : nil
                    pathVerbIndex = 0
                    // "/" and "." are command surfaces, not search text — a
                    // GitHub archive query for ".p" is pure noise. Nor is a
                    // pasted path. Inside a module only PRs search the archive.
                    let isPathShaped = PathTarget.looksLikePath(new)
                    let searches = global ? !(new.hasPrefix("/") || new.hasPrefix(".") || isPathShaped)
                        : router.module == .prs
                    store.search(searches ? new : "")
                    // Issues are searched ONLY from inside their mode, so no
                    // keystroke anywhere else spends an issue-search call.
                    let issueFilter = global ? PaletteMode.parse(new)
                        .flatMap { $0.mode == .issues ? $0.filter : nil } : nil
                    store.searchIssues(issueFilter ?? "")
                }
            if selectedID != nil {
                // ↵ belongs to the highlighted row now, not to eve — say so.
                // In a module, and on a PR anywhere, it opens the detail.
                let opensDetail = router.module != nil || selectedID?.hasPrefix("pr:") == true
                    || selectedID?.hasPrefix("archive:") == true
                Text(opensDetail ? "↵ detail · ⌘↵ open" : "↵ open · ↑ back")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize()
            } else if query.isEmpty, eveOnline == true {
                HStack(spacing: 4) {
                    StatusDot(tone: Theme.ok, size: 6)
                    Text("eve")
                }
                .font(Theme.Typo.meta)
                .foregroundStyle(Theme.ink3)
                .fixedSize()
            }
        }
    }

    /// Typing "todo…" surfaces the todos tab. Prefix-only on purpose: a PR
    /// titled "fix todo list" must not hijack the search results.
    var todosMatch: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        return "todos".hasPrefix(q) || q == "td"
    }

    var paletteHint: String {
        if eveAskedPrompt != nil { return "Ask eve again…" }
        if let module = router.module {
            return PaletteMode.alias(of: module)?.fieldHint ?? "Filter PRs — title, repo, #number, branch…"
        }
        if let (mode, _) = activeMode { return mode.fieldHint }
        if showTodos { return "Search todos…" }
        return "Search PRs, repos…  (/ask for eve · \".\" for modes)"
    }

    func submitPalette() {
        // A module's field is a filter: the keyboard already opened the
        // detail of the selected (or first) object.
        guard router.module == nil else { return }
        let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // Slash commands are explicit verbs — they run before any fuzzy match
        // gets a chance to reinterpret them.
        if let (command, argument) = SlashCommands.parse(prompt) {
            switch command.action {
            case .askEve:
                let evePrompt = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !evePrompt.isEmpty else {
                    commandNotice = .failed("usage: \(command.usage)")
                    return
                }
                guard eveOnline == true else {
                    commandNotice = .failed("eve is offline")
                    return
                }
                askEve(evePrompt)
                query = ""
            case .local:
                let result = command.run(argument)
                commandNotice = result
                if !result.isFailure { query = "" }
            }
            return
        }
        // A path card: the key router normally takes ↵ first, but a submit
        // that reaches here (no monitor, a synthetic submit) does the same.
        if let target = pathTarget {
            runPathVerb(target.verbs[min(pathVerbIndex, target.verbs.count - 1)])
            return
        }
        // Once `/ask` deliberately opened the conversation, this field is a
        // composer rather than a search box. Follow-ups stay conversational;
        // dismissing the overlay returns to the search-only contract.
        if eveAskedPrompt != nil {
            guard eveOnline == true else {
                commandNotice = .failed("eve is offline")
                return
            }
            askEve(prompt)
            query = ""
            return
        }
        // A mode's field is a filter — ↵ opens the top match; a partial mode
        // token completes.
        if let (mode, filter) = activeMode {
            switch mode {
            case .todos: modeTodos(filter).first?.open()
            case .schedule: modeSchedule(filter).first?.open()
            case .prod:
                if let issue = modeProd(filter).first { Self.open(issue.issue.permalink) }
            case .boards: modeBoards(filter).first?.open()
            case .issues:
                if let issue = modeIssues(filter).first { Self.open(issue.url) }
            case .notes:
                // Text that finds no note is a note to write, not a failed search.
                if let note = modeNotes(filter).first { toggleNote(note) } else { createNote(filter) }
            case .work, .devbox, .ci, .estate, .health, .mac, .fans, .vit, .home, .prs, .kit:
                break // a module's alias never stays global (`ModuleRouter.route`)
            case .organize:
                // Bare ↵ runs "default" (names() sorts it first); unmatched
                // text runs literally — the Lua engine may know layouts the
                // settings file doesn't list yet.
                runOrganize(modeOrganize(filter).first ?? (filter.isEmpty ? "default" : filter))
            }
            return
        }
        if let mode = modePickerMatches.first {
            enterMode(mode)
            return
        }
        // Inside the todos tab the field is a filter — ↵ opens the top match.
        if showTodos {
            filteredTodos.first?.open()
            return
        }
        // Todos, then projects ("fix ↵" opens the ExampleApp on-call page), then
        // commands ("v ↵" opens vitrinka). Unmatched text remains a search.
        if todosMatch {
            query = ""
            showTodos = true
            return
        }
        if let project = store.matchProject(prompt) {
            query = ""
            activeProject = project
            return
        }
        if let command = QuickCommand.matching(prompt).first {
            query = ""
            command.run()
            AppDelegate.shared?.closePanel()
            return
        }
        return
    }

    // MARK: - Path card

    /// Path detection for the palette. Never while the text is (or is
    /// completing into) a slash verb — `/open` must not resolve to the
    /// nearest ancestor `/`.
    static func detectPath(_ text: String) -> PathTarget? {
        guard PathTarget.looksLikePath(text) else { return nil }
        guard SlashCommands.parse(text) == nil, SlashCommands.matching(text).isEmpty else { return nil }
        return PathTarget.detect(text)
    }

    /// Runs a card verb and closes the panel — the destination is another
    /// app, exactly like a quick command.
    func runPathVerb(_ verb: PathVerb) {
        guard let target = pathTarget else { return }
        let result = verb.run(target)
        guard !result.isFailure else {
            commandNotice = result
            return
        }
        query = ""
        pathTarget = nil
        pathVerbIndex = 0
        AppDelegate.shared?.closePanel()
    }

    // MARK: - Floating completions (slash verbs + palette modes, on glass)

    var slashMatches: [SlashCommand] {
        SlashCommands.matching(query)
    }

    /// The completion card floating OVER the list: slash verbs when typing
    /// "/", palette modes when typing ".". Arrow keys walk it (the rows are
    /// paletteItems), ↵/click completes into the field.
    var floatingResults: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(slashMatches, id: \.name) { command in
                FloatingCompletionRow(
                    systemImage: "chevron.right.square",
                    primary: command.usage, primaryMono: true,
                    blurb: command.blurb,
                    selected: isSelected("slash:\(command.name)")
                ) { completeSlash(command) }
            }
            ForEach(modePickerMatches, id: \.rawValue) { mode in
                FloatingCompletionRow(
                    systemImage: mode.systemImage,
                    primary: ".\(mode.rawValue) — \(mode.title)", primaryMono: false,
                    blurb: mode.blurb,
                    selected: isSelected("mode:\(mode.rawValue)")
                ) { enterMode(mode) }
            }
        }
        .padding(5)
        .modifier(GlassCard())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    func completeSlash(_ command: SlashCommand) {
        query = "/" + command.name + " "
        selectedID = nil
        DispatchQueue.main.async { moveCaretToEnd() }
    }

    // MARK: - Mode pages

    @ViewBuilder
    func modePage(_ mode: PaletteMode, filter: String) -> some View {
        switch mode {
        case .todos:
            TodosPageView(todoStore: todoStore, todos: modeTodos(filter),
                          isSelected: { isSelected($0) },
                          selectedID: selectedID) { query = "" }
        case .schedule:
            SchedulePageView(todos: modeSchedule(filter),
                             isSelected: { isSelected($0) },
                             selectedID: selectedID) { query = "" }
        case .prod:
            ProdArchiveView(archive: prodArchive, issues: modeProd(filter),
                            selectedID: selectedID,
                            isSelected: { isSelected($0) }) { query = "" }
        case .boards:
            BoardsAllView(boards: modeBoards(filter),
                          isSelected: { isSelected($0) }) { query = "" }
        case .issues:
            IssueSearchView(store: store, issues: modeIssues(filter),
                            selectedID: selectedID,
                            isSelected: { isSelected($0) }) { query = "" }
        case .notes:
            NotesPageView(store: notes, notes: modeNotes(filter),
                          newNote: filter.isEmpty ? nil : filter,
                          newNoteID: Self.noteDraftID,
                          onCreate: { createNote(filter) },
                          selectedID: selectedID,
                          isSelected: { isSelected($0) },
                          expandedID: expandedNoteID,
                          editingID: $editingNoteID,
                          onToggle: { toggleNote($0) }) { query = "" }
        case .organize:
            OrganizePageView(layouts: modeOrganize(filter),
                             isSelected: { isSelected($0) },
                             onRun: { runOrganize($0) }) { query = "" }
        // A module's alias never stays global: the module draws its page.
        case .work, .devbox, .ci, .estate, .health, .mac, .fans, .vit, .home, .prs, .kit:
            EmptyView()
        }
    }

    /// Layout names narrowed by the palette, read fresh from settings.json —
    /// see `WorkspaceLayouts.names()` for why nothing is cached.
    func modeOrganize(_ filter: String) -> [String] {
        let q = filter.lowercased()
        let all = WorkspaceLayouts.names()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    /// Fire-and-report: the move/tile/spawn happens inside Hammerspoon (which
    /// shows its own on-screen summary); the palette only carries the verdict
    /// as an inline notice — a broken hs must never modal.
    func runOrganize(_ name: String) {
        commandNotice = .ok("organizing — \(name)…")
        Task {
            commandNotice = await OrganizeRunner.run(layout: name)
        }
    }

    func modeNotes(_ filter: String) -> [SavedNote] {
        notes.ordered.filter { $0.matches(filter) }
    }

    /// The `.notes` draft row's palette id — the typed or pasted filter,
    /// offered as a new note above whatever it matched.
    static let noteDraftID = "note-draft"

    /// Saves the draft, clears the filter and leaves the new note selected
    /// on top of the list, so the next ↵ reads it back.
    func createNote(_ text: String) {
        guard let note = notes.add(text) else { return }
        enterMode(.notes)
        expandedNoteID = note.id
        // The query change clears the selection on its way through onChange.
        DispatchQueue.main.async { selectedID = "note:\(note.id)" }
    }

    /// Expand-in-place, everywhere: the note opens where you found it. Second
    /// ↵ (or Esc) folds it back — see `handleKey`.
    func toggleNote(_ note: SavedNote) {
        withAnimation(.easeOut(duration: 0.16)) {
            expandedNoteID = expandedNoteID == note.id ? nil : note.id
        }
    }

    /// The agenda, narrowed by the palette. Unlike `modeTodos` this keeps
    /// resolved-hiding out of it — a scheduled item is dismissed by doing it,
    /// not by triaging it away.
    func modeSchedule(_ filter: String) -> [TodoItem] {
        todoStore.scheduledTodos.filter { $0.matches(filter) }
    }

    func modeTodos(_ filter: String) -> [TodoItem] {
        todoStore.openTodos.filter {
            $0.matches(filter) && !hiddenResolved.contains("todo:\($0.id)")
        }
    }

    func modeProd(_ filter: String) -> [ProdIssue] {
        let visible = prodArchive.issues.filter { !hiddenResolved.contains("prod:\($0.id)") }
        let q = filter.lowercased()
        guard !q.isEmpty else { return visible }
        return visible.filter {
            $0.issue.title.lowercased().contains(q)
                || $0.project.lowercased().contains(q)
                || $0.issue.shortId.lowercased().contains(q)
        }
    }

    /// Issue hits come back already answered to `filter` — GitHub matched the
    /// body text too, so re-filtering locally would hide real hits. Only the
    /// resting list needs narrowing, while a one-character query is still too
    /// short to be worth a request.
    func modeIssues(_ filter: String) -> [ArchivedIssue] {
        let visible = store.issueMatches.filter { !hiddenResolved.contains("issue:\($0.id)") }
        guard store.showingRecentIssues, !filter.isEmpty else { return visible }
        let q = filter.lowercased()
        return visible.filter {
            $0.title.lowercased().contains(q)
                || $0.repoSlug.lowercased().contains(q)
                || "#\($0.number)".contains(q)
                || $0.labels.contains { $0.lowercased().contains(q) }
        }
    }

    func modeVit(_ filter: String) -> [VitrinkaListening] {
        store.vitrinkaListening.filter {
            $0.matches(filter) && !hiddenResolved.contains("vit:\($0.id)")
        }
    }

    func modeBoards(_ filter: String) -> [VitrinkaBoard] {
        store.vitrinkaBoards.filter { $0.matches(filter) }
    }

    /// Opening a URL activates the browser, which resigns the panel's key
    /// status — it closes itself, exactly as a mouse click does today.
    static func open(_ url: String) {
        if let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }

    func isSelected(_ id: String) -> Bool {
        selectedID == id
    }

    /// The panel's field editor is shared window machinery — grab it and park
    /// the insertion point after the last character.
    func moveCaretToEnd() {
        guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    // MARK: - Eve

    func askEve(_ prompt: String) {
        askTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            eveAskedPrompt = prompt
        }
        // The field is rebuilt in its new home, which drops first-responder —
        // hand focus back so the conversation can continue by typing.
        DispatchQueue.main.async { paletteFocused = true }
        eveReply = ""
        eveDone = false
        eveError = nil
        eveExpanded = false
        askTask = Task {
            do {
                for try await event in await EveClient.shared.ask(prompt, settingsToken: store.eveToken) {
                    if Task.isCancelled { return }
                    eveReply = event.text
                    if event.done { eveDone = true }
                }
                eveDone = true
            } catch {
                if !Task.isCancelled {
                    eveError = error.localizedDescription
                    eveDone = true
                }
            }
        }
    }

    func dismissEve() {
        askTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            eveAskedPrompt = nil
        }
        eveReply = ""
        eveError = nil
        DispatchQueue.main.async { paletteFocused = true }
    }

    // MARK: - Palette rows (what ↓ ↑ walk while the search is global)

    /// One activatable result. The list is flattened in the exact visual order
    /// the panel renders — project match, quick commands, prod, inbox, archive —
    /// so ↓ never jumps somewhere the eye isn't.
    struct PaletteItem {
        let id: String
        let activate: @MainActor () -> Void
        /// ↵ normally activates and drops the selection (the row opened a URL
        /// or a page, so there is nothing left to be selected). A note toggles
        /// its expansion in place — it has to stay selected, or the second ↵
        /// would have nothing to close.
        var keepsSelection = false
        /// The row's page in the browser — the only thing ⌘↵ opens. nil: ⌘↵
        /// does nothing on this row (it never runs the row's ↵).
        var url: String?

        init(id: String, keepsSelection: Bool = false, url: String? = nil,
             activate: @escaping @MainActor () -> Void)
        {
            self.id = id
            self.activate = activate
            self.keepsSelection = keepsSelection
            self.url = url
        }
    }

    var paletteItems: [PaletteItem] {
        // The project page and the eve overlay replace the result list; the
        // todos page keeps the keyboard — its rows ARE the result list there.
        guard activeProject == nil, eveAskedPrompt == nil else { return [] }
        if showTodos {
            return filteredTodos.map { todo in
                PaletteItem(id: "todo:\(todo.id)", url: todo.url.absoluteString) { todo.open() }
            }
        }
        if let (mode, filter) = activeMode {
            switch mode {
            case .todos:
                return modeTodos(filter).map { todo in
                    PaletteItem(id: "todo:\(todo.id)", url: todo.url.absoluteString) { todo.open() }
                }
            case .schedule:
                return modeSchedule(filter).map { todo in
                    PaletteItem(id: "todo:\(todo.id)", url: todo.url.absoluteString) { todo.open() }
                }
            case .prod:
                return modeProd(filter).map { issue in
                    PaletteItem(id: "prod:\(issue.id)", url: issue.issue.permalink) { Self.open(issue.issue.permalink) }
                }
            case .boards:
                return modeBoards(filter).map { board in
                    PaletteItem(id: "board:\(board.slug)", url: board.url) { board.open() }
                }
            case .issues:
                return modeIssues(filter).map { issue in
                    PaletteItem(id: "issue:\(issue.id)", url: issue.url) { Self.open(issue.url) }
                }
            case .notes:
                let create = filter.isEmpty ? [] : [PaletteItem(id: Self.noteDraftID) { createNote(filter) }]
                return create + modeNotes(filter).map { note in
                    PaletteItem(id: "note:\(note.id)", keepsSelection: true) {
                        toggleNote(note)
                    }
                }
            // The deck is controls; a module's alias never stays global.
            case .fans, .work, .devbox, .ci, .estate, .health, .mac, .vit, .home, .prs, .kit:
                return []
            case .organize:
                return modeOrganize(filter).map { name in
                    PaletteItem(id: "organize:\(name)") { runOrganize(name) }
                }
            }
        }
        var items: [PaletteItem] = []
        for command in slashMatches {
            items.append(PaletteItem(id: "slash:\(command.name)") { completeSlash(command) })
        }
        for mode in modePickerMatches {
            items.append(PaletteItem(id: "mode:\(mode.rawValue)") { enterMode(mode) })
        }
        if !items.isEmpty { return items } // a completion card owns the keyboard
        if todosMatch {
            items.append(PaletteItem(id: "todos") {
                query = ""
                showTodos = true
            })
        }
        if let project = store.matchProject(query) {
            items.append(PaletteItem(id: "project:\(project.id)") {
                query = ""
                activeProject = project
            })
        }
        for command in QuickCommand.matching(query) {
            items.append(PaletteItem(id: "cmd:\(command.id)") {
                query = ""
                command.run()
                AppDelegate.shared?.closePanel()
            })
        }
        // Home walks the Now rows it draws (copilot shell D6), pinned repos
        // or not: a row's ↵ opens its object in its module, a fold's opens
        // it in place; ⌘↵ opens the object's real page.
        if showsHome {
            return items + homeNowRows.map { item in
                PaletteItem(id: item.id, keepsSelection: true, url: item.row.lead.lead.target.url) {
                    activateNow(item)
                }
            }
        }
        guard !(store.pinned.isEmpty && query.isEmpty) else { return items }
        // Matching the visual order exactly: PRs in fixed repo order, todos,
        // archive, then the pinned strips at the foot — prod, links.
        for entry in filteredInbox {
            items.append(PaletteItem(id: "pr:\(entry.id)", keepsSelection: true, url: entry.info.pr.htmlUrl) {
                openPRDetail("pr:\(entry.id)")
            })
        }
        for todo in filteredTodos {
            items.append(PaletteItem(id: "todo:\(todo.id)", url: todo.url.absoluteString) { todo.open() })
        }
        if searchActive {
            for pr in store.searchMatches {
                items.append(PaletteItem(id: "archive:\(pr.id)", keepsSelection: true, url: pr.url) {
                    openPRDetail("archive:\(pr.id)")
                })
            }
            for issue in store.sentryMatches {
                items.append(PaletteItem(id: "sentry:\(issue.id)", url: issue.issue.permalink) {
                    Self.open(issue.issue.permalink)
                })
            }
        }
        for note in filteredNotes {
            items.append(PaletteItem(id: "note:\(note.id)", keepsSelection: true) {
                toggleNote(note)
            })
        }
        // The links strip draws only while searching; its rows are selectable
        // exactly then.
        if searchActive {
            for link in filteredLinks.prefix(4) {
                items.append(PaletteItem(id: "link:\(link.id)", url: link.url) { openLink(link) })
            }
        }
        return items
    }

    /// ⌘V: the single-line field folds a paste's newlines into spaces, and a
    /// note pasted after `.note` would lose its paragraphs. Multi-line text
    /// is spliced in here; anything else takes the field's own paste.
    func pasteMultiline() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), text.contains(where: \.isNewline)
        else { return false }
        let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView
        let current = query as NSString
        var range = editor?.selectedRange ?? NSRange(location: current.length, length: 0)
        if NSMaxRange(range) > current.length { range = NSRange(location: current.length, length: 0) }
        query = current.replacingCharacters(in: range, with: text)
        let caret = range.location + (text as NSString).length
        DispatchQueue.main.async {
            guard let editor, caret <= (editor.string as NSString).length else { return }
            editor.selectedRange = NSRange(location: caret, length: 0)
        }
        return true
    }
}
