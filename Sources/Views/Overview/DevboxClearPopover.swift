import AppKit
import SwiftUI

/// Owned by the page, so a cleared row disappearing cannot dismiss its log.
/// Reads top-down as an answer: the verdict, then one self-summarising row per
/// fact (files, commits) for every source. Expanding a row is for detail only —
/// docs/specs/2026-10-08-clear-this-glance-decisions.md.
struct DevboxClearPopover: View {
    let workspace: DevboxWorkspace
    let store: StatusStore
    let onClose: () -> Void
    @State private var preview: DevboxClearPreview?
    @State private var source: DevboxClearSourceAction = .keep
    @State private var report: DevboxClearReport?
    @State private var busy = false
    @State private var history = ""
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let report { result(report) } else { verdict }
                if let preview {
                    sourceBlock(preview, id: "primary", branch: workspace.branch)
                    ForEach(Array(preview.additionalSources.enumerated()), id: \.offset) { index, other in
                        sourceBlock(other, id: "source-\(index)", branch: nil)
                    }
                    worktreeAction(preview)
                } else {
                    skeleton
                }
                ClearRow(expanded: binding("log"), motion: motion) {
                    Text("Command log").font(ClearMetrics.label)
                    Spacer()
                } detail: {
                    scrolling(maxHeight: 180) {
                        Text(logText.isEmpty ? "No command has run." : logText)
                            .font(ClearMetrics.code).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 540)
        .task { refresh() }
        .interactiveDismissDisabled(busy)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PanelDriver.paletteNotification)) { note in
            guard note.userInfo?["cmd"] as? String == "clear-action", let action = note.userInfo?["text"] as? String else { return }
            switch action {
            case "clear": perform(recover: false)
            case "keep", "backup", "discard":
                if !busy, report?.ok != true, let selection = DevboxClearSourceAction(rawValue: action), selection == .keep || preview?.canRemove == true { choose(selection) }
            case "show-log": withAnimation(motion) { _ = expanded.insert("log") }
            case "show-changes": withAnimation(motion) { expanded.formUnion(allRowIDs) }
            case "refresh": refresh()
            case "inspect": perform(recover: true)
            case "close": if !busy { onClose() }
            default: break
            }
        }
        #endif
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Clear").font(.system(size: 12, weight: .semibold))
            Text(workspace.name)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let box = workspace.box {
                Text("box \(box.name)").font(ClearMetrics.meta).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).disabled(busy).help("Close (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Read local changes again").disabled(busy)
            Button("Copy log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logText, forType: .string)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
                Text(preview == nil ? "Reading…" : "Working…").font(ClearMetrics.label).foregroundStyle(.secondary)
            } else if report?.ok != true {
                if report != nil {
                    Button(needsUnhold ? "Unhold and clear" : "Inspect and retry clear") { perform(recover: true) }
                } else {
                    Button(source.button) { perform(recover: false) }
                        .buttonStyle(.borderedProminent)
                        .tint(source == .discard ? .red : .accentColor)
                        .keyboardShortcut(.defaultAction)
                        .contentTransition(.interpolate)
                }
            }
        }
        .controlSize(.small)
        .disabled(preview == nil)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Verdict

    private var summaries: [DevboxClearSummary] {
        guard let preview else { return [] }
        return ([preview] + preview.additionalSources).map(DevboxClearSummary.init)
    }

    private var verdict: some View {
        let judged = preview.map { _ in DevboxClearSummary.verdict(summaries, action: source) }
        let look = VerdictLook(judged)
        let detail = look.detail(source)
        // Text-states swap: the whole verdict blurs into the next one, in place.
        return VerdictCard(look: look, detail: detail, loading: judged == nil)
            .id(look.title + detail)
            .transition(swap)
    }

    private var swap: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    // MARK: Sources

    private func sourceBlock(_ preview: DevboxClearPreview, id: String, branch: String?) -> some View {
        let summary = DevboxClearSummary(preview)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(Self.abbreviated(preview.path ?? "unavailable on this Mac"))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 6)
                if let branch { Text(branch).lineLimit(1).truncationMode(.middle) }
                if id != "primary" { Text("kept").foregroundStyle(.tertiary) }
            }
            .font(ClearMetrics.meta).foregroundStyle(.secondary)
            .padding(.horizontal, ClearMetrics.inset).padding(.bottom, 3)
            ClearRow(expanded: binding("\(id)-files"), motion: motion, expandable: !summary.files.isEmpty) {
                factLabel("Files", glyph: !summary.readable ? .unread : summary.files.isEmpty ? .ok : .work)
                filesSummary(summary)
            } detail: {
                fileList(summary, diff: preview.diff, id: id)
            }
            ClearRow(expanded: binding("\(id)-commits"), motion: motion, expandable: !summary.commits.isEmpty) {
                factLabel("Commits", glyph: !summary.readable ? .unread : summary.commits.isEmpty ? .ok : .work)
                commitsSummary(summary)
            } detail: {
                commitList(summary)
            }
            .help("Compared with this Mac's remote refs, which may be stale. Clearing never deletes the branch or its commits.")
        }
    }

    private func factLabel(_ title: String, glyph: Glyph) -> some View {
        factLabel(title, symbol: glyph.symbol, tint: glyph.tint)
    }

    private func factLabel(_ title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 12)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(ClearMetrics.label)
        }
        .frame(width: ClearMetrics.labelWidth, alignment: .leading)
    }

    @ViewBuilder private func filesSummary(_ summary: DevboxClearSummary) -> some View {
        if !summary.readable {
            Text("could not read").font(ClearMetrics.value).foregroundStyle(.orange)
        } else if summary.files.isEmpty {
            Text("clean").font(ClearMetrics.value).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text("\(summary.files.count) \(summary.files.count == 1 ? "file" : "files")")
                    .contentTransition(.numericText(value: Double(summary.files.count)))
                HStack(spacing: 5) {
                    ForEach(summary.kinds, id: \.kind) { tally in
                        Text("\(String(tally.kind))\(tally.count)").foregroundStyle(Self.tint(tally.kind))
                    }
                }
                .font(ClearMetrics.meta)
                Spacer(minLength: 4)
                lineCounts(added: summary.added, removed: summary.removed)
                DiffStatBar(added: summary.added, removed: summary.removed)
            }
            .font(ClearMetrics.value)
        }
    }

    @ViewBuilder private func commitsSummary(_ summary: DevboxClearSummary) -> some View {
        let target = summary.upstream ?? "any remote"
        if !summary.readable {
            Text("could not read").font(ClearMetrics.value).foregroundStyle(.orange)
        } else if summary.commits.isEmpty {
            Text(summary.upstream.map { "in sync with \($0)" } ?? "all on a remote")
                .font(ClearMetrics.value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        } else {
            HStack(spacing: 4) {
                Text("\(summary.commits.count)").contentTransition(.numericText(value: Double(summary.commits.count)))
                Text("not on \(target)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .font(ClearMetrics.value)
        }
    }

    private func fileList(_ summary: DevboxClearSummary, diff: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            scrolling(maxHeight: 176) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(summary.files, id: \.path) { file in
                        HStack(spacing: 8) {
                            Text(String(file.kind)).foregroundStyle(Self.tint(file.kind)).frame(width: 10)
                            Text(file.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer(minLength: 6)
                            if let added = file.added, let removed = file.removed {
                                lineCounts(added: added, removed: removed)
                                DiffStatBar(added: added, removed: removed)
                            } else {
                                Text(file.kind == "?" ? "untracked" : "binary").foregroundStyle(.tertiary)
                            }
                        }
                        .font(ClearMetrics.code)
                    }
                }
            }
            if !diff.isEmpty {
                ClearRow(expanded: binding("\(id)-diff"), motion: motion) {
                    Text("Diff").font(ClearMetrics.label).foregroundStyle(.secondary)
                    Text("staged + unstaged · secret files omitted").font(ClearMetrics.meta).foregroundStyle(.tertiary)
                    Spacer()
                } detail: {
                    scrolling(maxHeight: 240) {
                        Text(Self.colored(diff)).font(ClearMetrics.code).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func commitList(_ summary: DevboxClearSummary) -> some View {
        scrolling(maxHeight: 140) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(summary.commits, id: \.sha) { commit in
                    HStack(spacing: 8) {
                        Text(commit.sha).foregroundStyle(.secondary)
                        Text(commit.subject).lineLimit(1).truncationMode(.tail)
                    }
                    .font(ClearMetrics.code).textSelection(.enabled)
                }
            }
        }
    }

    private func lineCounts(added: Int, removed: Int) -> some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(.green).contentTransition(.numericText(value: Double(added))) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(.red).contentTransition(.numericText(value: Double(removed))) }
        }
        .font(ClearMetrics.meta).monospacedDigit()
    }

    // MARK: Worktree action, result, loading

    private func worktreeAction(_ preview: DevboxClearPreview) -> some View {
        HStack(spacing: 6) {
            // Same columns as a ClearRow: chevron slot, glyph, label, value.
            Color.clear.frame(width: 8)
            factLabel("Worktree", symbol: source == .keep ? "folder.fill" : "folder.badge.minus",
                      tint: source == .discard ? .red : .secondary)
            if preview.canRemove {
                Picker("Worktree", selection: Binding(get: { source }, set: { choose($0) })) {
                    ForEach(DevboxClearSourceAction.allCases) { action in Text(action.short).tag(action) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                .disabled(busy || report?.ok == true)
                Spacer(minLength: 0)
            } else {
                Text("kept · \(preview.explanation)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ClearMetrics.inset)
        .padding(.top, 2)
    }

    private func result(_ report: DevboxClearReport) -> some View {
        let tint: Color = report.ok ? .green : .orange
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: report.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                Text(report.ok ? "Cleared" : "Clear failed").font(.system(size: 13, weight: .semibold))
            }
            Text(report.summary).font(.system(size: 10.5)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                VStack(alignment: .leading, spacing: 1) {
                    Text(diagnostic.code).font(ClearMetrics.meta).foregroundStyle(.secondary)
                    if let detail = diagnostic.detail { Text(detail).font(.system(size: 10.5)).textSelection(.enabled) }
                    if let fix = diagnostic.fix { Text(fix).font(ClearMetrics.code).textSelection(.enabled) }
                }
            }
            if !report.next.isEmpty {
                ClearRow(expanded: binding("next"), motion: motion) {
                    Text("Recovery instructions").font(ClearMetrics.label)
                    Spacer()
                } detail: {
                    Text(report.next.joined(separator: "\n")).font(ClearMetrics.code).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .transition(swap)
    }

    /// Skeleton reveal: placeholder rows pulse until the first read lands.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).frame(width: ClearMetrics.labelWidth - 10, height: 9)
                    RoundedRectangle(cornerRadius: 3).frame(width: 180, height: 9)
                    Spacer()
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(0.08))
        .padding(.horizontal, ClearMetrics.inset + 14).padding(.vertical, 4)
        .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.45]) { view, phase in
            view.opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.9) }
        .transition(.opacity)
    }

    // MARK: Plumbing

    /// Critically damped, Apple's default for non-gestural UI; reduced motion
    /// drops to a short cross-fade.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }

    private var allRowIDs: [String] {
        let sources = ["primary"] + (preview?.additionalSources.indices.map { "source-\($0)" } ?? [])
        return sources.flatMap { ["\($0)-files", "\($0)-commits", "\($0)-diff"] }
    }

    private var logText: String { history.isEmpty ? preview?.log ?? "" : history }

    private var needsUnhold: Bool {
        report?.diagnostics.contains { $0.fix?.hasPrefix("devbox unhold ") == true } == true
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { open in
            if open { expanded.insert(id) } else { expanded.remove(id) }
        })
    }

    private func choose(_ action: DevboxClearSourceAction) {
        withAnimation(motion) { source = action }
    }

    private func scrolling(maxHeight: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            let next = await DevboxClient.shared.clearPreview(workspace)
            withAnimation(motion) {
                preview = next
                if !next.canRemove { source = .keep }
            }
            busy = false
        }
    }

    private func perform(recover: Bool) {
        guard let preview, !busy else { return }
        busy = true
        Task {
            if recover {
                let inspection = await DevboxClient.shared.inspectClear(workspace, releaseHold: needsUnhold)
                history += "\n\n" + inspection.log
                guard inspection.ok else {
                    withAnimation(motion) { report = inspection; _ = expanded.insert("log") }
                    busy = false
                    return
                }
            }
            let outcome = await DevboxClient.shared.clear(workspace, preview: preview, source: source)
            history += "\n\n" + outcome.log
            withAnimation(motion) {
                report = outcome
                if !outcome.ok { _ = expanded.insert("log") }
            }
            busy = false
            await store.refreshDevboxNow()
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func tint(_ kind: Character) -> Color {
        switch kind {
        case "A": .green
        case "D", "U": .red
        case "R", "C": .purple
        case "?": .blue
        default: .orange
        }
    }

    /// Unified-diff colouring, capped so a vendored-blob diff cannot stall a render.
    static func colored(_ diff: String, limit: Int = 1_500) -> AttributedString {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var out = AttributedString()
        for line in lines.prefix(limit) {
            var piece = AttributedString(line + "\n")
            if line.hasPrefix("+"), !line.hasPrefix("+++") { piece.foregroundColor = .green }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { piece.foregroundColor = .red }
            else if line.hasPrefix("@@") { piece.foregroundColor = .cyan }
            else if line.hasPrefix("Staged changes") || line.hasPrefix("Unstaged changes") { piece.font = .system(size: 10, weight: .semibold) }
            else if !line.hasPrefix(" "), !line.isEmpty { piece.foregroundColor = .secondary }  // diff/index/mode headers
            out += piece
        }
        if lines.count > limit { out += AttributedString("… \(lines.count - limit) more lines — Copy log has all of them.") }
        return out
    }
}

private enum ClearMetrics {
    static let label = Font.system(size: 11, weight: .medium)
    static let value = Font.system(size: 10.5, design: .monospaced)
    static let meta = Font.system(size: 9.5, design: .monospaced)
    static let code = Font.system(size: 10, design: .monospaced)
    static let labelWidth: CGFloat = 76
    static let inset: CGFloat = 6
}

private enum Glyph {
    case ok, work, unread
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .work: "circle.fill"
        case .unread: "questionmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .ok: .green
        case .work: .orange
        case .unread: .orange
        }
    }
}

private struct VerdictLook {
    let symbol: String
    let tint: Color
    let title: String
    private let local: String

    init(_ verdict: DevboxClearSummary.Verdict?) {
        switch verdict {
        case nil:
            (symbol, tint, title, local) = ("", .secondary, "Reading local changes…", "")
        case .clean:
            (symbol, tint, title, local) = ("checkmark.shield.fill", .green, "Safe to clear · nothing local", "")
        case .keepsWork:
            (symbol, tint, title, local) = ("checkmark.shield.fill", .green, "Safe to clear · local work stays", "")
        case .backsUp:
            (symbol, tint, title, local) = ("archivebox.fill", .green, "Safe to clear · backed up first",
                                            "Saves the whole worktree to ~/Backups/pultik-worktrees, then removes it")
        case .discards(let files):
            (symbol, tint, title, local) = ("exclamationmark.triangle.fill", .red,
                                            "Discards \(files) changed \(files == 1 ? "file" : "files")",
                                            "Modified, untracked and ignored files are deleted; the branch and its commits stay")
        case .unread:
            (symbol, tint, title, local) = ("questionmark.diamond.fill", .orange, "Safe to clear · changes unread",
                                            "Git could not read local changes, so source is kept as is")
        }
    }

    /// The runtime half is always the same promise; the source half follows the pick.
    func detail(_ action: DevboxClearSourceAction) -> String {
        guard title != "Reading local changes…" else { return "Stops the runtime and frees its ports" }
        if !local.isEmpty { return "Stops the runtime · \(local)" }
        return action == .keep
            ? "Stops the runtime and frees its ports · branch, source, guest source and data stay"
            : "Stops the runtime · removes the clean worktree; its branch stays"
    }
}

private struct VerdictCard: View {
    let look: VerdictLook
    let detail: String
    let loading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: look.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(look.tint)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(look.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(look.tint.opacity(0.18)))
    }
}

/// GitHub's five-block diffstat: green and red in proportion, grey for the rest.
private struct DiffStatBar: View {
    let added: Int
    let removed: Int

    var body: some View {
        let total = added + removed
        let scale = total > 5 ? 5.0 / Double(total) : 1.0
        let green = Int((Double(added) * scale).rounded())
        let red = min(5 - green, Int((Double(removed) * scale).rounded()))
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < green ? Color.green : index < green + red ? Color.red : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: total)
    }
}

/// One fact per line: label and its summary always visible, detail on demand.
/// Accordion: chevron turns, detail rises 4pt into place while fading in.
private struct ClearRow<Label: View, Detail: View>: View {
    @Binding var expanded: Bool
    let motion: Animation
    var expandable = true
    @ViewBuilder let label: () -> Label
    @ViewBuilder let detail: () -> Detail
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(motion) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(expandable ? 1 : 0)
                        .frame(width: 8)
                    label()
                }
                .padding(.horizontal, ClearMetrics.inset).frame(minHeight: 22)
                .contentShape(Rectangle())
                .background(hovering && expandable ? RailRowMetrics.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if expanded && expandable {
                detail()
                    .padding(.leading, ClearMetrics.inset + 14).padding(.trailing, ClearMetrics.inset)
                    .padding(.vertical, 4)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity))
            }
        }
        .clipped()
    }
}
