import CodeThemes
import SwiftUI

/// The workbench's Files changed tab (PR workbench D5, WP2): every changed
/// file on the code canvas — in the code theme, highlighted, wrapped under the
/// gutter until ⌥Z (D9) — under one status line. ⇥ walks the files and ↵
/// folds the ringed one; ↑/↓ scroll while the PR is entered.
struct PRFilesTab: View {
    let store: StatusStore
    let pr: ChangeRequest
    /// The files of `pr`'s own diff — or, `stale`, the same head at an older
    /// base, shown marked while the exact one loads.
    let files: ChangeSet?
    let stale: Bool
    let failure: String?
    /// This tab is shown and owns the keys.
    let active: Bool
    /// Scoped to one commit (WP5): what the status line says, and the way back.
    var scope: (title: String, clear: () -> Void)?
    let retry: () -> Void
    @Environment(ModuleRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Files the operator folded or unfolded against their default.
    @State private var toggledFiles: Set<String> = []
    @State private var document: DiffDocument?
    @State private var documentID = ""
    /// The file at the top of the canvas, which the tree selects.
    @State private var currentFile: String?
    @State private var reveal: (file: Int, line: Int?, serial: Int)?
    /// The review comment being written (WP4): its lines and text.
    @State private var composer: CommentDraft?
    @FocusState private var composerFocused: Bool
    /// The side column's pane, ⌘⇧F's focus, a lookup's results and the peek (WP6).
    @State private var pane: SidePane = .tree
    @State private var searchFocus = 0
    @State private var lookup: (title: String, symbols: [SymbolIndex.Symbol]?, failure: String?)?
    @State private var peek: (word: CodeCanvasView.CodeWord, symbol: SymbolIndex.Symbol)?

    /// A comment on `lines` (indices into the file's diff lines) of `file`.
    struct CommentDraft {
        let file: Int
        var lines: ClosedRange<Int>
        var body = ""
        var sending = false
        var failure: String?
    }

    /// ⇥'s walk on this tab.
    static func focusTargets(_ files: ChangeSet?) -> [String] {
        files?.files.map { "file:\($0.path)" } ?? []
    }

    private var changes: ChangeSet? {
        #if DEBUG
        if let fixture = DiffFixture.shared.changes { return fixture }
        #endif
        return files
    }

    /// What the document is built from: the compared pair, whether it is
    /// the exact diff, and the folds.
    private var documentKey: String {
        let fixture: String
        #if DEBUG
        fixture = DiffFixture.shared.changes == nil ? "" : "|fixture:\(DiffFixture.shared.serial)"
        #else
        fixture = ""
        #endif
        return "\(pr.ref.key)@\(pr.baseSHA)...\(pr.headSHA)|\(scope?.title ?? "")|\(changes?.files.count ?? -1)|\(stale)\(fixture)|"
            + toggledFiles.sorted().joined(separator: "\u{1F}")
    }

    var body: some View {
        // A verb landing re-reads the activity: the marks follow it.
        _ = store.prVerbRevision[pr.ref]
        let pending = store.cachedPRActivity(pr.ref)?.pendingReview
        return VStack(alignment: .leading, spacing: 0) {
            statusLine
            HStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    if let document {
                        CodeCanvas(document: document, documentID: documentID, wraps: CodePreferences.shared.wraps,
                                   active: active, focusedFile: focusedFile(document),
                                   scrollRequest: router.scrollRequest,
                                   blob: { [store, repo = pr.ref.repo] sha in try await store.blobText(repo: repo, sha: sha) },
                                   reveal: reveal, marks: marks(document, pending: pending),
                                   anchor: composer.map { ($0.file, $0.lines) },
                                   callbacks: callbacks(document))
                    } else if failure == nil {
                        SkeletonBars(widths: [0.5, 0.7, 0.4]).padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if let document, composer != nil {
                        composerCard(document, pending: pending?.comments.count ?? 0)
                            .transition(Theme.Motion.toast(reduceMotion))
                    } else if let peek {
                        peekCard(peek)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if CodePreferences.shared.sideColumnShown, let changes {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    sideColumn(changes)
                        .frame(width: 240)
                        .background(Theme.canvas)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(CodePreferences.shared.themes.theme[.background].color)
        .onChange(of: composer != nil, initial: true) { _, open in if active { router.setComposing(open) } }
        .onChange(of: active) { _, active in router.setComposing(active && composer != nil) }
        .onChange(of: router.composerCommand) { _, command in
            guard active, composer != nil, let command else { return }
            switch command.action {
            case .submit: submitComment()
            case .close: withAnimation(Theme.Motion.pop(reduceMotion)) { composer = nil }
            }
        }
        .onDisappear { if active { router.setComposing(false) } }
        .onChange(of: router.codeRequest) { _, request in
            guard active, let request else { return }
            switch request.kind {
            case .search:
                withAnimation(Theme.Motion.swap(reduceMotion)) {
                    CodePreferences.shared.sideColumnShown = true
                    pane = .search
                }
                searchFocus += 1
            case .definition, .references:
                guard let word = CodeCanvasView.active?.lastWord else {
                    show(lookupTitle: "Click a name first, then F12", failure: nil)
                    return
                }
                navigate(word, references: request.kind == .references)
            }
        }
        .task(id: documentKey) {
            let key = documentKey
            let changes = changes
            let toggled = toggledFiles
            let built = await Task.detached(priority: .userInitiated) { DiffDocument(changes, collapsed: toggled) }.value
            guard !Task.isCancelled else { return }
            document = changes == nil ? nil : built
            documentID = key
        }
        .onChange(of: router.activated) { _, target in
            guard active, let target, target.hasPrefix("file:") else { return }
            toggledFiles.formSymmetricDifference([String(target.dropFirst(5))])
            router.consumeActivation()
        }
    }

    private func callbacks(_ document: DiffDocument) -> CodeCanvasView.Callbacks {
        var callbacks = CodeCanvasView.Callbacks()
        callbacks.toggleFile = { path in toggledFiles.formSymmetricDifference([path]) }
        callbacks.topFile = { file in currentFile = file.flatMap { document.files[safe: $0]?.path } }
        callbacks.hover = { word in hover(word) }
        callbacks.definition = { word in navigate(word, references: false) }
        // A gutter click starts a comment on that line; ⇧-click extends it
        // within the same file (keyboard line selection is out of scope).
        callbacks.gutter = { file, index, extend in
            guard [.added, .removed, .context].contains(document.files[file].lines[index].kind) else { return }
            withAnimation(Theme.Motion.push(reduceMotion)) {
                if extend, var draft = composer, draft.file == file {
                    draft.lines = min(draft.lines.lowerBound, index) ... max(draft.lines.upperBound, index)
                    composer = draft
                } else {
                    composer = CommentDraft(file: file, lines: index ... index)
                }
            }
            composerFocused = true
        }
        return callbacks
    }

    // MARK: - Code navigation and search (WP6, D2, D3)

    @ViewBuilder
    private func sideColumn(_ changes: ChangeSet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(SidePane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding([.horizontal, .top], 8)
            switch pane {
            case .tree:
                FileTreeView(files: changes.files, current: currentFile) { path in reveal(path) }
            case .search:
                CodeSearchPane(store: store, repo: pr.ref.repo, head: pr.headSHA, prPaths: changes.files.map(\.path),
                               focusRequest: searchFocus) { hit in open(path: hit.path, line: hit.line) }
            case .references:
                if let lookup {
                    ReferencesPane(title: lookup.title, symbols: lookup.symbols, failure: lookup.failure) { symbol in
                        open(path: symbol.path, line: symbol.line + 1)
                    }
                } else {
                    Text("Click a name, then F12 for its definition or ⇧F12 for its references; ⌘-click opens a definition.")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).padding(8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func show(lookupTitle: String, failure: String?) {
        lookup = (lookupTitle, [], failure)
        withAnimation(Theme.Motion.swap(reduceMotion)) {
            CodePreferences.shared.sideColumnShown = true
            pane = .references
        }
    }

    /// F12, ⇧F12 or ⌘-click: the symbol index at the head answers. One
    /// definition opens; several, or references, list in the side column.
    private func navigate(_ word: CodeCanvasView.CodeWord, references: Bool) {
        lookup = ((references ? "References of " : "Definitions of ") + word.name, nil, nil)
        withAnimation(Theme.Motion.swap(reduceMotion)) {
            CodePreferences.shared.sideColumnShown = true
            pane = .references
        }
        let repo = pr.ref.repo
        let head = pr.headSHA
        Task {
            do {
                let found = try await store.lookUp(word.name, repo: repo, head: head, from: word.path,
                                                   references: references)
                if !references, found.count == 1, let only = found.first {
                    lookup?.symbols = found
                    open(path: only.path, line: only.line + 1)
                } else {
                    lookup?.symbols = found
                }
            } catch {
                NSLog("pultik: looking up %@ in %@ failed: %@", word.name, repo, error.localizedDescription)
                lookup?.failure = error.localizedDescription
            }
        }
    }

    /// A line the diff draws scrolls there; any other opens its file card.
    private func open(path: String, line: Int) {
        if let document, let file = document.files.firstIndex(where: { $0.path == path }),
           document.files[file].lines.contains(where: { $0.new == line }) {
            reveal = (file, line, (reveal?.serial ?? 0) + 1)
            return
        }
        withAnimation(Theme.Motion.push(reduceMotion)) {
            router.push(DetailRef(kind: .file, id: CodeFileRef(repo: pr.ref.repo, sha: pr.headSHA, path: path, line: line).id))
        }
    }

    /// The hover peek (D2): a word's definition, only once the index is
    /// built — hovering never starts indexing.
    private func hover(_ word: CodeCanvasView.CodeWord?) {
        guard let word else {
            peek = nil
            return
        }
        let repo = pr.ref.repo
        let head = pr.headSHA
        Task {
            let definitions = await store.peek(word.name, repo: repo, head: head, from: word.path)
            if let first = definitions.first { peek = (word, first) } else if peek?.word == word { peek = nil }
        }
    }

    private func peekCard(_ peek: (word: CodeCanvasView.CodeWord, symbol: SymbolIndex.Symbol)) -> some View {
        HStack(spacing: 8) {
            Text(peek.symbol.kind).font(Theme.Typo.micro).foregroundStyle(Theme.accent)
            Text(peek.word.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            Text(verbatim: "\(peek.symbol.path):\(peek.symbol.line + 1)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            KbdHint("⌘-click")
            Text("open").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .padding(12)
    }

    private func reveal(_ path: String) {
        guard let index = document?.files.firstIndex(where: { $0.path == path }) else { return }
        reveal = (index, nil, (reveal?.serial ?? 0) + 1)
    }

    /// Lines carrying a pending review comment or an open thread.
    private func marks(_ document: DiffDocument, pending: PendingReview?) -> [Int: Set<Int>] {
        var marks: [Int: Set<Int>] = [:]
        let anchors = (pending?.comments ?? []).map { ($0.path, $0.line, $0.side) }
            + pr.openThreads.compactMap { thread in thread.line.map { (thread.path, $0, DraftReviewComment.Side.right) } }
        for (path, line, side) in anchors {
            guard let file = document.files.firstIndex(where: { $0.path == path }) else { continue }
            let lines = document.files[file].lines
            if let index = lines.firstIndex(where: { side == .left ? $0.old == line && $0.kind == .removed : $0.new == line }) {
                marks[file, default: []].insert(index)
            }
        }
        return marks
    }

    /// The draft as the host takes it: the last line and its side, and the
    /// first when it spans several (removed lines are the base's).
    private static func review(_ draft: CommentDraft, in document: DiffDocument) -> DraftReviewComment? {
        let file = document.files[draft.file]
        func anchor(_ index: Int) -> (line: Int, side: DraftReviewComment.Side)? {
            let line = file.lines[index]
            if line.kind == .removed { return line.old.map { ($0, .left) } }
            return line.new.map { ($0, .right) }
        }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let end = anchor(draft.lines.upperBound) else { return nil }
        let start = draft.lines.count > 1 ? anchor(draft.lines.lowerBound) : nil
        return DraftReviewComment(path: file.path, line: end.line, side: end.side, startLine: start?.line,
                                  startSide: start?.side, body: body)
    }

    private func submitComment() {
        guard let document, var draft = composer, !draft.sending, let comment = Self.review(draft, in: document) else { return }
        draft.sending = true
        draft.failure = nil
        composer = draft
        let ref = pr.ref
        Task {
            do {
                try await store.performPRVerb(.addReviewComment(comment), ref: ref)
                withAnimation(Theme.Motion.pop(reduceMotion)) { composer = nil }
            } catch {
                NSLog("pultik: review comment on %@ failed: %@", ref.key, error.localizedDescription)
                composer?.sending = false
                composer?.failure = error.localizedDescription
            }
        }
    }

    /// The review comment's card over the canvas: where it lands, the text,
    /// and how many comments the pending review already holds.
    private func composerCard(_ document: DiffDocument, pending: Int) -> some View {
        let draft = composer ?? CommentDraft(file: 0, lines: 0 ... 0)
        let file = document.files[safe: draft.file]
        let numbers = draft.lines.compactMap { file?.lines[safe: $0].flatMap { $0.new ?? $0.old } }
        let span = numbers.count > 1 ? "L\(numbers.first ?? 0)–L\(numbers.last ?? 0)" : "L\(numbers.first ?? 0)"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Review comment").microLabel()
                Text(verbatim: "\(file?.path ?? "") · \(span)").font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 6)
                if pending > 0 {
                    Chip("\(pending) pending", .neutral, symbol: "text.bubble")
                        .help("Your pending review holds \(pending) comment\(pending == 1 ? "" : "s"); submit it with Review")
                }
            }
            TextEditor(text: Binding(get: { composer?.body ?? "" }, set: { composer?.body = $0 }))
                .font(Theme.Typo.code)
                .scrollContentBackground(.hidden)
                .focused($composerFocused)
                .frame(height: 76)
                .padding(6)
                .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            HStack(spacing: 8) {
                if let failure = draft.failure {
                    Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.danger).lineLimit(2)
                } else {
                    Text("⇧-click another line to span several").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 6)
                KbdHint("esc")
                Button("Cancel") { withAnimation(Theme.Motion.pop(reduceMotion)) { composer = nil } }
                    .buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                KbdHint("⌘↵")
                Button(pending > 0 ? "Add to review" : "Start a review", action: submitComment)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(draft.sending || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .padding(10)
    }

    private func focusedFile(_ document: DiffDocument) -> Int? {
        guard let focus = router.focus, focus.hasPrefix("file:") else { return nil }
        let path = String(focus.dropFirst(5))
        return document.files.firstIndex { $0.path == path }
    }

    /// `64 files · +1532 −319`, why the diff may be old or missing, and the wrap key.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if let scope {
                Chip("commit \(scope.title)", .selected, symbol: "smallcircle.filled.circle")
                Button("All changes", action: scope.clear)
                    .buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            } else {
                Text(verbatim: "\(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files") · +\(pr.additions) −\(pr.deletions)")
                    .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
            }
            if files != nil, stale {
                Chip(failure == nil ? "the base moved · refreshing" : "the base moved · not refreshed", .dashed, symbol: "clock")
                    .help(failure ?? "This diff was compared at an older base; the current one is loading")
            }
            if files == nil, let failure {
                Text(verbatim: "Files not loaded — \(failure)")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            if failure != nil {
                Button("Retry", action: retry)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            Spacer(minLength: 6)
            KbdHint("⌥Z")
            Text(CodePreferences.shared.wraps ? "unwrap" : "wrap").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            KbdHint("⌘B")
            Text(CodePreferences.shared.sideColumnShown ? "hide tree" : "tree").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.canvas)
    }
}

#if DEBUG
/// A diff the panel driver loads in place of the PR's (`diff-fixture`):
/// AC 4's 5,000-line scroll bench needs one that size.
@MainActor
@Observable
final class DiffFixture {
    static let shared = DiffFixture()
    private(set) var changes: ChangeSet?
    private(set) var serial = 0

    /// A unified diff file (`git diff --full-index` output), or nil to clear.
    func load(_ path: String?) {
        serial += 1
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            changes = nil
            return
        }
        // Its blobs are another repository's: it highlights from the patch alone.
        let files = GitMirror.parse(diff: text).map {
            ChangedFile(path: $0.path, previousPath: $0.previousPath, status: $0.status, additions: $0.additions,
                        deletions: $0.deletions, patch: $0.patch, trimmed: $0.trimmed)
        }
        changes = ChangeSet.bounded(files, truncated: false, lineLimit: ChangeSet.mirrorLineLimit,
                                    byteBudget: ChangeSet.mirrorByteBudget)
    }
}
#endif
