import Canvas
import SwiftUI

/// The PR workbench's Merge tab (vt-7968, `docs/specs/2026-10-18-merge-view-decisions.md`):
/// the pull request merged into its base branch's tip as WebStorm draws it — ours (the base)
/// · the result · theirs (the head), joined by ribbons, the merge base on ⌥B — one file at a
/// time, the files both sides changed beside it with their conflicts and resolutions counted.
/// A merge commit picked in Commits shows its own merge instead: its parents merged again,
/// and where the commit decided otherwise. Read only: "Resolve in …" hands a conflicting
/// preview to the agent shell (M3). ⇥ walks the conflicts and resolutions across the files.
struct PRMergeTab: View {
    let store: StatusStore
    let pr: ChangeRequest
    /// A merge commit Commits picked: its own merge instead of the preview.
    let commit: ChangeCommit?
    let active: Bool
    var clearCommit: () -> Void = {}
    @Environment(ModuleRouter.self) private var router

    @State private var preview: MergePreview?
    @State private var failure: String?
    @State private var attempt = 0
    /// Each file's conflicts left and regions resolved, as the engine counts them.
    @State private var counts: [String: FileCount] = [:]
    @State private var selected: String?
    /// The region ⇥ or a click is on, and why it reads as it does.
    @State private var reason: String?

    struct FileCount: Equatable {
        let conflicts: Int
        let resolved: Int

        var stops: Int { conflicts + resolved }
    }

    /// The engine owns ⇥ here (`KeyContext.mergeShown`): no focus ring.
    static func focusTargets() -> [String] { [] }

    private var loadKey: String {
        if let commit { return "commit:\(pr.ref.repo)@\(commit.sha)|\(attempt)" }
        return "pr:\(pr.ref.key)@\(pr.baseTipSHA ?? pr.baseRef)...\(pr.headSHA)|\(attempt)"
    }

    private var shownFile: MergeFile? {
        preview?.files.first { $0.path == selected } ?? preview?.files.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
            HStack(spacing: 0) {
                ZStack {
                    if let file = shownFile, let preview {
                        MergeCanvas(file: file, fileID: "\(loadKey)|\(file.path)", labels: labels(preview),
                                    showsBase: router.mergeShowsBase, active: active,
                                    scrollRequest: router.scrollRequest, stepRequest: router.mergeStep,
                                    onRegion: { _, why in reason = why },
                                    onWrap: { forward in carry(forward) })
                    } else if let preview, preview.files.isEmpty {
                        Text(preview.skipped.isEmpty ? "No file changed on both sides: this merge has nothing to resolve."
                             : "Every file both sides changed is binary or too large to draw.")
                            .font(Theme.Typo.body).foregroundStyle(Theme.ink2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if failure == nil {
                        SkeletonBars(widths: [0.5, 0.7, 0.4]).padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let preview, !(preview.files.isEmpty && preview.skipped.isEmpty) {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    fileColumn(preview)
                        .frame(width: 240)
                        .background(Theme.canvas)
                }
            }
            reasonLine
        }
        .background(CodePreferences.shared.themes.theme[.background].color)
        .task(id: loadKey) { await load() }
    }

    // MARK: - Loading

    private func load() async {
        failure = nil
        do {
            let loaded: MergePreview?
            if let commit {
                loaded = try await store.mergeCommitPreview(pr.ref.repo, sha: commit.sha)
                if loaded == nil { failure = "\(commit.sha.prefix(7)) is not a merge commit" }
            } else {
                loaded = try await store.mergePreview(pr)
            }
            try Task.checkCancellation()
            preview = loaded
            counts = [:]
            reason = nil
            guard let loaded else { return }
            let counted = await Self.count(loaded.files)
            try Task.checkCancellation()
            counts = counted
            // The first file with something to look at opens.
            selected = loaded.files.first { (counted[$0.path]?.conflicts ?? 0) > 0 }?.path
                ?? loaded.files.first { (counted[$0.path]?.stops ?? 0) > 0 }?.path ?? loaded.files.first?.path
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: merge of %@ failed: %@", pr.ref.key, error.localizedDescription)
            failure = error.localizedDescription
        }
    }

    /// Every file merged once off the main actor, for its counts.
    private static func count(_ files: [MergeFile]) async -> [String: FileCount] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: FileCount] = [:]
            for file in files {
                guard let c = try? MergeEngine.summary(path: file.path, base: file.base, ours: file.ours,
                                                       theirs: file.theirs) else { continue }
                out[file.path] = FileCount(conflicts: c.conflicts, resolved: c.resolved)
            }
            return out
        }.value
    }

    // MARK: - ⇥ across files

    /// ⇥ ran past the shown file's last stop (⇧⇥ its first): the next file with stops that way,
    /// stepped into.
    private func carry(_ forward: Bool) {
        guard let preview, let at = preview.files.firstIndex(where: { $0.path == shownFile?.path }) else { return }
        let n = preview.files.count
        for k in 1 ..< max(n, 1) {
            let file = preview.files[(at + (forward ? k : n - k)) % n]
            guard (counts[file.path]?.stops ?? 0) > 0 else { continue }
            // The new file shows, then takes this step into its first stop (one update).
            selected = file.path
            router.mergeNext(forward: forward)
            return
        }
    }

    // MARK: - Pieces

    private func labels(_ preview: MergePreview) -> [MergeEngine.Pane: String] {
        let short = { (sha: String) in String(sha.prefix(7)) }
        if let commit {
            return [.base: "Merge base · \(short(preview.base))", .ours: "First parent · \(short(preview.ours))",
                    .result: "Merge commit · \(short(commit.sha))", .theirs: "Second parent · \(short(preview.theirs))"]
        }
        return [.base: "Merge base · \(short(preview.base))", .ours: "\(pr.baseRef) · \(short(preview.ours))",
                .result: "Result · preview", .theirs: "\(pr.headRef) · \(short(preview.theirs))"]
    }

    private var statusLine: some View {
        let total = counts.values.reduce(FileCount(conflicts: 0, resolved: 0)) {
            FileCount(conflicts: $0.conflicts + $1.conflicts, resolved: $0.resolved + $1.resolved)
        }
        return HStack(spacing: 8) {
            if let commit {
                Chip("merge \(commit.sha.prefix(7))", .selected, symbol: "arrow.triangle.merge")
                Button("The PR's merge", action: clearCommit)
                    .buttonStyle(.plain).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            } else {
                Text(verbatim: "\(pr.headRef) into \(pr.baseRef)")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            if let preview {
                Text(verbatim: "\(preview.files.count + preview.skipped.count) files both changed")
                    .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if total.conflicts > 0 { Chip("\(total.conflicts) conflicts", .danger, symbol: "exclamationmark.triangle") }
            if total.resolved > 0 { Chip("\(total.resolved) resolved", .ok, symbol: "wand.and.sparkles") }
            if let failure {
                Text(verbatim: "Merge not read — \(failure)")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
                Button("Retry") { attempt += 1 }
                    .buttonStyle(.glass).controlSize(.small)
            }
            Spacer(minLength: 6)
            if commit == nil, total.conflicts > 0, let shell = SessionShell.installed {
                Button("Resolve in \(shell.name)") {
                    SessionShell.resolveMerge(repo: pr.ref.repo, number: pr.number, in: shell)
                }
                .buttonStyle(.glass).controlSize(.small)
            }
            KbdHint("⇥")
            Text("next").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            KbdHint("⌥B")
            Text(router.mergeShowsBase ? "hide base" : "base").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var reasonLine: some View {
        HStack(spacing: 6) {
            Image(systemName: reason == nil ? "arrow.right.to.line" : "info.circle")
                .foregroundStyle(Theme.ink3)
            Text(verbatim: reason ?? "⇥ walks the conflicts and what the engine resolved; a click on a ribbon picks one")
                .font(Theme.Typo.meta).foregroundStyle(reason == nil ? Theme.ink3 : Theme.ink2).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func fileColumn(_ preview: MergePreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(preview.files) { file in
                    let count = counts[file.path]
                    Button {
                        selected = file.path
                        reason = nil
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: (file.path as NSString).lastPathComponent)
                                .font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let count, count.conflicts > 0 {
                                Text(verbatim: "\(count.conflicts)").font(Theme.Typo.meta).monospacedDigit()
                                    .foregroundStyle(Theme.danger)
                            }
                            if let count, count.resolved > 0 {
                                Text(verbatim: "\(count.resolved)").font(Theme.Typo.meta).monospacedDigit()
                                    .foregroundStyle(Theme.ok)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(file.path == shownFile?.path ? Theme.selection : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.path)
                }
                if !preview.skipped.isEmpty {
                    Text("Binary or too large")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                        .padding([.horizontal, .top], 10)
                    ForEach(preview.skipped, id: \.self) { path in
                        Text(verbatim: (path as NSString).lastPathComponent)
                            .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .help(path)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}
