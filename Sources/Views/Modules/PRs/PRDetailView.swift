import SwiftUI

/// The PR's own content under the detail header (WP5, D7) — the read-first
/// GitHub mini app: an overview strip, checks failing first, reviews, the
/// open threads with the lines they are about, the description, then every
/// changed file with its diff. Drawn at once from what the query repository
/// holds, revalidated on open; ⌘↵ still opens the real page.
struct PRDetailContent: View {
    let store: StatusStore
    let ref: PRRef

    @State private var conversation: GitHubPRDetail.Conversation?
    /// The files of `conversation`'s own diff, or nil. The one exception is
    /// `filesStale`: the same head compared at an older base, shown marked
    /// while its exact diff loads — never another head's.
    @State private var files: GitHubPRDetail.Files?
    @State private var filesStale = false
    /// The conversation read failed (the cached one may still show).
    @State private var failure: String?
    /// The files read failed; the conversation stands.
    @State private var filesFailure: String?
    @State private var attempt = 0
    @State private var showsPassed = false
    @State private var showsResolved = false
    @State private var showsFullBody = false
    /// Files the operator expanded or collapsed against their default.
    @State private var toggledFiles: Set<String> = []

    /// A file this long starts collapsed, and so does every file once the
    /// diff drawn above it passes the page budget: layout stays bounded.
    static let collapseLines = 300
    static let pageLines = 1500

    init(store: StatusStore, ref: PRRef) {
        self.store = store
        self.ref = ref
        let cached = store.cachedPRDetail(ref)
        _conversation = State(initialValue: cached.conversation)
        _files = State(initialValue: cached.files)
    }

    /// Its own scroller over one lazy stack (`ModulePage.detailScrollsItself`):
    /// every tile, file header and diff chunk is a lazy item, so only what is
    /// near the viewport exists. A diff nested in a plain stack instantiated
    /// all of its text views — each with its own backing store, ~400 MB for
    /// a 1,500-line PR.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let conversation {
                    Group {
                        overview(conversation)
                        checks(conversation)
                        if !conversation.reviews.isEmpty || !conversation.requested.isEmpty { reviews(conversation) }
                        if !conversation.threads.isEmpty { threads(conversation) }
                        if !conversation.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            description(conversation.body)
                        }
                    }
                    .padding(.bottom, 10)
                    filesItems(conversation)
                } else if let failure {
                    Tile(kicker: "Pull request") {
                        Text(failure).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                    }
                } else {
                    skeleton
                }
            }
            .padding([.horizontal, .bottom], 14)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task(id: LoadKey(ref: ref, attempt: attempt)) { await load() }
    }

    private struct LoadKey: Equatable {
        let ref: PRRef
        let attempt: Int
    }

    private func load() async {
        do {
            let fresh = try await store.prConversation(ref)
            try Task.checkCancellation()
            if let exact = store.cachedPRFiles(ref, of: fresh) {
                files = exact
                filesStale = false
            } else if files != nil, conversation?.headSHA == fresh.headSHA {
                filesStale = true // same head, the base moved: keep it, marked
            } else {
                files = nil
                filesStale = false
            }
            conversation = fresh
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: PR detail %@#%d failed: %@", ref.repo, ref.number, error.localizedDescription)
            failure = error.localizedDescription
        }
        // A departed selection stops here: the files read is the heavy one.
        // An exact hit answers from memory at once (and counts as a use).
        guard let conversation, !Task.isCancelled else { return }
        do {
            let loaded = try await store.prFiles(ref, of: conversation)
            try Task.checkCancellation()
            files = loaded
            filesStale = false
            filesFailure = nil
        } catch is CancellationError {
        } catch {
            NSLog("pultik: PR files %@#%d failed: %@", ref.repo, ref.number, error.localizedDescription)
            filesFailure = error.localizedDescription
        }
    }

    // MARK: - Overview

    private func overview(_ pr: GitHubPRDetail.Conversation) -> some View {
        let failed = pr.checks.filter { $0.outcome == .failed }.count
        let running = pr.checks.filter { $0.outcome == .running }.count
        let passed = pr.checks.filter { $0.outcome == .passed }.count
        let skipped = pr.checks.filter { $0.outcome == .skipped }.count
        let open = pr.threads.filter { !$0.isResolved }.count
        let quiet = skipped == 0 ? "\(passed) passed" : "\(passed) passed · \(skipped) skipped"
        let checks: StatStrip.Cell = if failed > 0 {
            .init(label: "Checks", value: "\(failed) failed", tone: Theme.danger, caption: quiet)
        } else if running > 0 {
            .init(label: "Checks", value: "\(running) running", tone: Theme.ok, caption: quiet)
        } else if passed > 0 {
            .init(label: "Checks", value: "passed", tone: Theme.ok, caption: quiet)
        } else {
            .init(label: "Checks", value: "none", tone: Theme.ink3)
        }
        let review: StatStrip.Cell = switch pr.reviewVerdict {
        case "APPROVED": .init(label: "Review", value: "approved", tone: Theme.ok, caption: Self.requestedCaption(pr))
        case "CHANGES_REQUESTED": .init(label: "Review", value: "changes", tone: Theme.warn,
                                        caption: Self.requestedCaption(pr))
        default: .init(label: "Review", value: pr.requested.isEmpty ? "none" : "awaiting",
                       tone: pr.requested.isEmpty ? Theme.ink3 : Theme.ink2, caption: Self.requestedCaption(pr))
        }
        return VStack(alignment: .leading, spacing: 10) {
            StatStrip(cells: [
                checks, review,
                .init(label: "Threads", value: open == 0 ? "0" : "\(open) open", tone: open == 0 ? Theme.ink3 : Theme.warn,
                      caption: "\(pr.threads.count - open) resolved"),
                .init(label: "Changes", value: "+\(pr.additions) −\(pr.deletions)",
                      caption: pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files"),
            ])
            HStack(spacing: 6) {
                Text(verbatim: Self.metaLine(pr))
                    .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                ForEach(Self.stateChips(pr), id: \.text) { $0 }
                if conversation != nil, let failure {
                    Chip("not refreshed", .dashed, symbol: "clock").help(failure)
                }
            }
        }
        .kitTile()
    }

    private static func requestedCaption(_ pr: GitHubPRDetail.Conversation) -> String? {
        pr.requested.isEmpty ? nil : "\(pr.requested.count) requested"
    }

    /// `lukas · main ← feat/x · opened Oct 2 · updated 4m ago`
    private static func metaLine(_ pr: GitHubPRDetail.Conversation) -> String {
        let now = Date()
        var parts = [pr.author ?? "ghost", "\(pr.baseRef) ← \(pr.headRef)",
                     "opened \(PultikFormat.date(pr.createdAt, now: now))"]
        if let merged = pr.mergedAt {
            parts.append("merged \(PultikFormat.ago(merged, now: now))")
        } else {
            parts.append("updated \(PultikFormat.ago(pr.updatedAt, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    /// What the header's status chip never says: draft, merged and closed
    /// already lead it.
    private static func stateChips(_ pr: GitHubPRDetail.Conversation) -> [Chip] {
        guard pr.state == "OPEN", pr.mergeable == "CONFLICTING" else { return [] }
        return [Chip("conflicts", .danger, symbol: "exclamationmark.triangle")]
    }

    // MARK: - Checks

    private func checks(_ pr: GitHubPRDetail.Conversation) -> some View {
        let attention = pr.checks.filter { $0.outcome == .failed || $0.outcome == .running }
        let quiet = pr.checks.filter { $0.outcome == .passed || $0.outcome == .skipped }
        let failed = pr.checks.filter { $0.outcome == .failed }.count
        let caption = [failed > 0 ? "\(failed) failed" : nil,
                       quiet.isEmpty ? nil : "\(quiet.count) passed or skipped",
                       pr.checksTruncated ? "first \(GitHubPRDetail.checkLimit)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Tile(kicker: "Checks", caption: caption.isEmpty ? nil : caption) {
            VStack(alignment: .leading, spacing: 0) {
                if pr.checks.isEmpty {
                    Text("No checks on the head commit").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                ForEach(attention) { CheckRow(check: $0) }
                if !quiet.isEmpty {
                    DisclosureLine(text: "\(quiet.count) passed or skipped", open: $showsPassed) {
                        StatusDot(tone: Theme.ok, size: 5)
                    }
                    if showsPassed { ForEach(quiet) { CheckRow(check: $0) } }
                }
            }
        }
    }

    // MARK: - Reviews

    private func reviews(_ pr: GitHubPRDetail.Conversation) -> some View {
        Tile(kicker: "Reviews") {
            FlowRow(hSpacing: 6, vSpacing: 6) {
                ForEach(pr.reviews, id: \.author) { review in
                    switch review.state {
                    case "APPROVED": Chip("\(review.author) approved", .ok, symbol: "checkmark")
                    case "CHANGES_REQUESTED": Chip("\(review.author) requested changes", .warn,
                                                   symbol: "exclamationmark")
                    case "DISMISSED": Chip("\(review.author) dismissed", .dashed)
                    default: Chip("\(review.author) commented", .neutral, symbol: "text.bubble")
                    }
                }
                ForEach(pr.requested, id: \.self) { Chip("\($0) requested", .dashed, symbol: "clock") }
            }
        }
    }

    // MARK: - Threads

    private func threads(_ pr: GitHubPRDetail.Conversation) -> some View {
        let open = pr.threads.filter { !$0.isResolved }
        let resolved = pr.threads.filter(\.isResolved)
        let caption = ["\(open.count) open", resolved.isEmpty ? nil : "\(resolved.count) resolved",
                       pr.threadsTruncated ? "first \(GitHubPRDetail.threadLimit)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Tile(kicker: "Threads", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(open) { ThreadView(thread: $0) }
                if !resolved.isEmpty {
                    DisclosureLine(text: "\(resolved.count) resolved", open: $showsResolved) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ok)
                    }
                    if showsResolved { ForEach(resolved) { ThreadView(thread: $0) } }
                }
            }
        }
    }

    // MARK: - Description

    private func description(_ body: String) -> some View {
        let text = MarkdownLite.render(body)
        let long = body.split(separator: "\n", omittingEmptySubsequences: false).count > 10 || body.count > 900
        return Tile(kicker: "Description") {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.ink)
                    .lineLimit(showsFullBody ? nil : 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button(showsFullBody ? "Less" : "More") { showsFullBody.toggle() }
                        .buttonStyle(.plain)
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    // MARK: - Files

    /// The Files tile as lazy items stitched into one surface: its heading,
    /// each file's header, each `DiffView.chunkSize`-line chunk of an open
    /// diff and the notes — so a long diff costs only its visible chunks.
    @ViewBuilder
    private func filesItems(_ pr: GitHubPRDetail.Conversation) -> some View {
        let caption = "\(pr.changedFiles == 1 ? "1 file" : "\(pr.changedFiles) files") · +\(pr.additions) −\(pr.deletions)"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files").microLabel()
                Spacer(minLength: 8)
                Text(verbatim: caption).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if files != nil, filesStale {
                HStack(spacing: 8) {
                    Chip(filesFailure == nil ? "the base moved · refreshing" : "the base moved · not refreshed",
                         .dashed, symbol: "clock")
                        .help(filesFailure ?? "This diff was compared at an older base; the current one is loading")
                    if filesFailure != nil {
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            }
            if files == nil, let filesFailure {
                HStack(spacing: 8) {
                    Text(verbatim: "Files not loaded — \(filesFailure)")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(2)
                    Spacer(minLength: 6)
                    Button("Retry") { attempt += 1 }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else if files == nil {
                SkeletonBars(widths: [0.5, 0.7, 0.4])
            }
        }
        .tileSlice(top: true)
        if let files {
            ForEach(Self.items(files, toggled: toggledFiles)) { item in
                switch item.kind {
                case let .header(file, lines, collapsed):
                    FileHeader(file: file, lines: lines, collapsed: collapsed) {
                        toggledFiles.formSymmetricDifference([file.path])
                    }
                    .padding(.top, 8)
                    .tileSlice()
                case let .chunk(lines, digits, first, last):
                    DiffView(lines: lines, digits: digits)
                        .padding(.top, first ? 4 : 0)
                        .padding(.bottom, last ? 4 : 0)
                        .background(Theme.canvasDeep, in: UnevenRoundedRectangle(
                            topLeadingRadius: first ? Theme.Radius.row : 0, bottomLeadingRadius: last ? Theme.Radius.row : 0,
                            bottomTrailingRadius: last ? Theme.Radius.row : 0, topTrailingRadius: first ? Theme.Radius.row : 0,
                            style: .continuous))
                        .tileSlice()
                case let .note(text):
                    Text(verbatim: text).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .padding(.leading, 20)
                        .padding(.top, 2)
                        .tileSlice()
                }
            }
        }
        Color.clear.frame(height: 14).tileSlice(bottom: true)
    }

    /// The Files tile's lazy items. A file's default fold: past
    /// `collapseLines`, or once the lines drawn above pass `pageLines`.
    private static func items(_ files: GitHubPRDetail.Files, toggled: Set<String>) -> [FileItem] {
        var items: [FileItem] = []
        var drawn = 0
        for file in files.files {
            let lines = file.patch.map(GitHubPRDetail.DiffLine.parse) ?? []
            let byDefault = lines.count > collapseLines || drawn + lines.count > pageLines
            if !byDefault { drawn += lines.count }
            let collapsed = byDefault != toggled.contains(file.path)
            items.append(FileItem(id: "file:\(file.path)", kind: .header(file, lines: lines.count, collapsed: collapsed)))
            if lines.isEmpty {
                items.append(FileItem(id: "note:\(file.path)", kind: .note(file.trimmed
                        ? "Past the patch budget — ⌘↵ opens it on GitHub" : "No diff — binary, renamed or too large")))
            } else if collapsed {
                items.append(FileItem(id: "note:\(file.path)", kind: .note("\(lines.count) lines — click to show")))
            } else {
                let digits = DiffTextView.digits(lines)
                let starts = Array(stride(from: 0, to: lines.count, by: DiffView.chunkSize))
                for (index, start) in starts.enumerated() {
                    items.append(FileItem(id: "chunk:\(file.path):\(start)", kind: .chunk(
                        Array(lines[start ..< min(start + DiffView.chunkSize, lines.count)]), digits: digits,
                        first: index == 0, last: index == starts.count - 1)))
                }
                if file.trimmed {
                    items.append(FileItem(id: "note:\(file.path)",
                                          kind: .note("Diff cut at \(GitHubPRDetail.patchLineLimit) lines — ⌘↵ opens the rest")))
                }
            }
        }
        if files.truncated {
            items.append(FileItem(id: "truncated", kind: .note("GitHub lists the first \(files.files.count) files — ⌘↵ opens the rest")))
        }
        return items
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Tile { SkeletonBars(widths: [0.6, 0.35]) }
            Tile { SkeletonBars(widths: [0.45, 0.7, 0.55]) }
        }
    }
}

/// One lazy item of the Files tile.
private struct FileItem: Identifiable {
    enum Kind {
        case header(GitHubPRDetail.File, lines: Int, collapsed: Bool)
        case chunk([GitHubPRDetail.DiffLine], digits: Int, first: Bool, last: Bool)
        case note(String)
    }

    let id: String
    let kind: Kind
}

private extension View {
    /// One horizontal slice of a tile drawn as several lazy items: the
    /// `surface` fill, the tile's 14 pt content edge, and the tile's corners
    /// on its first and last slice.
    func tileSlice(top: Bool = false, bottom: Bool = false) -> some View {
        let radius = Theme.Radius.tile
        return padding(.horizontal, 14)
            .padding(.top, top ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: UnevenRoundedRectangle(
                topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0, style: .continuous))
    }
}

/// One check: its outcome's shape, name, workflow, duration and page.
private struct CheckRow: View {
    let check: GitHubPRDetail.Check

    var body: some View {
        HStack(spacing: 8) {
            glyph.frame(width: 14)
            Text(check.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
            if let workflow = check.workflow {
                Text(workflow).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(verbatim: check.duration.map(PultikFormat.duration) ?? "")
                .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                .frame(width: 64, alignment: .trailing)
            LinkGlyph(url: check.url.flatMap(URL.init(string:)), label: "Open check \(check.title)")
        }
        .frame(height: 24)
    }

    @ViewBuilder private var glyph: some View {
        switch check.outcome {
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
        case .running: StatusDot(tone: Theme.ok, style: .spin)
        case .passed: StatusDot(tone: Theme.ok)
        case .skipped: StatusDot(tone: Theme.ink3, style: .ring)
        }
    }
}

/// A review thread: where it is, the lines it is about, its comments.
private struct ThreadView: View {
    let thread: GitHubPRDetail.Thread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.head)
                if thread.isOutdated { Chip("outdated", .dashed) }
                if thread.isResolved { Chip("resolved", .ok, symbol: "checkmark") }
                Spacer(minLength: 6)
                LinkGlyph(url: thread.comments.first.flatMap { URL(string: $0.url) },
                          label: "Open the review thread on \(thread.path)")
            }
            let hunk = Self.tail(of: thread.hunk)
            if !hunk.isEmpty {
                DiffView(lines: hunk)
                    .padding(.vertical, 4)
                    .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(comment.author).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                        Text(verbatim: PultikFormat.ago(comment.createdAt, now: Date()))
                            .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    }
                    Text(MarkdownLite.render(comment.body))
                        .font(Theme.Typo.body).foregroundStyle(Theme.ink).tint(Theme.ink)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The commented line and the three above it.
    static func tail(of hunk: String) -> [GitHubPRDetail.DiffLine] {
        Array(GitHubPRDetail.DiffLine.parse(hunk).filter { $0.kind != .hunk }.suffix(4))
    }
}

/// One changed file: its header, then its diff — or why there is none.
/// One changed file's header row: fold chevron, status, path, counts. Its
/// diff and notes follow as their own lazy items.
private struct FileHeader: View {
    let file: GitHubPRDetail.File
    let lines: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: lines == 0 ? "doc" : collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 12)
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tone)
                    .help(file.status)
                Text(verbatim: file.path).font(Theme.Typo.figure).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.head)
                if let previous = file.previousPath {
                    Text(verbatim: "← \(previous)").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                Text(verbatim: "+\(file.additions)").font(Theme.Typo.figure).foregroundStyle(Theme.ok)
                Text(verbatim: "−\(file.deletions)").font(Theme.Typo.figure).foregroundStyle(Theme.danger)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lines == 0)
    }

    private var symbol: String {
        switch file.status {
        case "added": "plus"
        case "removed": "minus"
        case "renamed", "copied": "arrow.right"
        default: "pencil"
        }
    }

    private var tone: Color {
        switch file.status {
        case "added": Theme.ok
        case "removed": Theme.danger
        default: Theme.ink2
        }
    }
}

/// GitHub markdown as one attributed run for a glance: headings bold,
/// bullets as `•`, HTML comments gone, inline markup parsed, and links
/// underlined — the Text drawing it tints them `ink`, never the accent or
/// the system link blue.
enum MarkdownLite {
    static func render(_ markdown: String) -> AttributedString {
        let stripped = markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var result = AttributedString()
        var lines = stripped.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        for (index, raw) in lines.enumerated() {
            var line = raw
            var bold = false
            if let heading = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                line.removeSubrange(heading)
                bold = true
            } else if let bullet = line.range(of: "^\\s*[-*]\\s+", options: .regularExpression) {
                line.replaceSubrange(bullet, with: "• ")
            }
            var run = (try? AttributedString(markdown: line, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            for linked in run.runs where linked.link != nil {
                run[linked.range].foregroundColor = Theme.ink
                run[linked.range].underlineStyle = Text.LineStyle.single
            }
            if bold { run.font = Theme.Typo.title }
            result += run
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
