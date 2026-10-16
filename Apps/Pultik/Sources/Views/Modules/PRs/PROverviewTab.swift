import SwiftUI

/// The Overview tab's story (PR workbench D8): comments, reviews and pushes
/// in order — consecutive commits fold into one push — and the state
/// changes between them as one quiet line each.
struct PRTimeline: View {
    let events: [TimelineEvent]
    let truncated: Bool
    let repo: String
    let resolver: AutolinkResolver

    /// A run of commits is one push.
    enum Item: Identifiable {
        case event(TimelineEvent)
        case push([TimelineEvent])

        var id: String {
            switch self {
            case let .event(event): event.id
            case let .push(commits): "push:" + (commits.first?.id ?? "")
            }
        }
    }

    static func items(_ events: [TimelineEvent]) -> [Item] {
        var items: [Item] = []
        for event in events {
            if case .commit = event.kind {
                if case var .push(commits)? = items.last {
                    commits.append(event)
                    items[items.count - 1] = .push(commits)
                } else {
                    items.append(.push([event]))
                }
            } else {
                items.append(.event(event))
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if truncated {
                Text("Earlier events are on GitHub — ⌘↵ opens the pull request")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            ForEach(Self.items(events)) { item in
                switch item {
                case let .event(event): row(event)
                case let .push(commits): push(commits)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ event: TimelineEvent) -> some View {
        let who = event.actor ?? "ghost"
        let when = PultikFormat.ago(event.at, now: Date())
        switch event.kind {
        case let .comment(body):
            card(who: who, when: when, chip: nil, body: body)
        case let .review(verdict, body, comments):
            card(who: who, when: when, chip: Self.chip(verdict, comments: comments), body: body)
        case let .forcePush(before, after):
            line("arrow.triangle.2.circlepath", "\(who) force-pushed \(Self.short(before)) → \(Self.short(after))", when)
        case let .merged(sha):
            line("arrow.triangle.merge", "\(who) merged \(Self.short(sha))", when)
        case .closed: line("xmark.circle", "\(who) closed it", when)
        case .reopened: line("arrow.uturn.backward.circle", "\(who) reopened it", when)
        case .readyForReview: line("eye", "\(who) marked it ready for review", when)
        case .convertedToDraft: line("pencil.and.outline", "\(who) converted it to a draft", when)
        case let .reviewRequested(reviewer): line("person.badge.plus", "\(who) asked \(reviewer) to review", when)
        case let .labeled(label): line("tag", "\(who) added \(label)", when)
        case let .unlabeled(label): line("tag.slash", "\(who) removed \(label)", when)
        case let .assigned(person): line("person", "\(who) assigned \(person)", when)
        case let .renamed(from, to): line("pencil", "\(who) renamed it from “\(from)” to “\(to)”", when)
        case let .baseChanged(from, to): line("arrow.left.arrow.right", "\(who) changed the base from \(from) to \(to)", when)
        case .commit: EmptyView()
        }
    }

    private func card(who: String, when: String, chip: Chip?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(who).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                if let chip { chip }
                Text(when).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                GFMStack(blocks: GFM.blocks(text, repo: repo, resolver: resolver), spacing: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitTile()
    }

    private func push(_ commits: [TimelineEvent]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line("arrow.up.circle", "\(commits.first?.actor ?? "ghost") pushed \(commits.count) commit\(commits.count == 1 ? "" : "s")",
                 commits.last.map { PultikFormat.ago($0.at, now: Date()) } ?? "")
            ForEach(commits) { commit in
                if case let .commit(sha, headline) = commit.kind {
                    HStack(spacing: 8) {
                        Text(Self.short(sha)).font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                        Text(headline).font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }

    private func line(_ symbol: String, _ text: String, _ when: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 14)
            Text(text).font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(2)
            Text(when).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
    }

    static func chip(_ verdict: ChangeRequest.Verdict, comments: Int) -> Chip {
        let count = comments > 0 ? " · \(comments)" : ""
        switch verdict {
        case .approved: return Chip("approved\(count)", .ok, symbol: "checkmark")
        case .changesRequested: return Chip("changes requested\(count)", .warn, symbol: "exclamationmark")
        case .dismissed: return Chip("dismissed", .dashed)
        default: return Chip("reviewed\(count)", .neutral, symbol: "text.bubble")
        }
    }

    static func short(_ sha: String?) -> String {
        sha.map { String($0.prefix(7)) } ?? "?"
    }
}

/// Where the PR stands and the one verb that lands it (D8): mergeability in
/// the host's words, auto-merge, and Merge… which opens its confirm.
struct MergeBox: View {
    let pr: ChangeRequest
    let activity: ChangeRequestActivity?
    let verbs: [PRVerb]
    let reach: (PRVerb) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let block = PRVerbCatalogue.mergeBlock(pr, activity)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol(block)).font(.system(size: 16, weight: .semibold)).foregroundStyle(tone(block))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(block)).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                if let auto = activity?.merge.autoMerge {
                    Text("Auto-merge (\(auto.rawValue)) once the requirements are met").font(Theme.Typo.meta)
                        .foregroundStyle(Theme.ink2)
                } else if let block, pr.state == .open {
                    Text(block).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: 8)
            ForEach(verbs.filter { ["updateBranch", "merge"].contains($0.id) && $0.enabled }) { verb in
                Button { reach(verb) } label: {
                    HStack(spacing: 4) {
                        Text(verb.title)
                        if let key = verb.key { KbdHint(key.uppercased()) }
                    }
                }
                .verbButtonStyle(prominent: verb.id == "merge")
                .controlSize(.small)
            }
        }
        .kitTile()
        // WP7: the state crossfades with a one-shot symbol effect.
        .animation(Theme.Motion.status(reduceMotion), value: block)
    }

    private func headline(_ block: String?) -> String {
        switch pr.state {
        case .merged: "Merged into \(pr.baseRef)"
        case .closed: "Closed without merging"
        case .open: block == nil ? "Ready to merge into \(pr.baseRef)" : "Not mergeable yet"
        }
    }

    private func symbol(_ block: String?) -> String {
        switch pr.state {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .open: block == nil ? "checkmark.circle" : "exclamationmark.circle"
        }
    }

    private func tone(_ block: String?) -> Color {
        switch pr.state {
        case .merged: Theme.ink2
        case .closed: Theme.danger
        case .open: block == nil ? Theme.ok : Theme.warn
        }
    }
}

extension View {
    /// A verb's button: the one primary in accent prominent glass, the rest neutral glass.
    @ViewBuilder
    func verbButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            buttonStyle(.glass)
        }
    }
}

/// The Overview's composer (D8, the note editor's model): markdown, a GFM
/// preview, ⌘↵ comments, Esc lets go of the keys.
struct CommentComposer: View {
    @Binding var text: String
    let repo: String
    let resolver: AutolinkResolver
    let sending: Bool
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void
    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comment").microLabel()
                Spacer(minLength: 6)
                Picker("", selection: $preview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            if preview {
                GFMStack(blocks: GFM.blocks(text.isEmpty ? "_Nothing to preview_" : text, repo: repo, resolver: resolver),
                         spacing: 6)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .font(Theme.Typo.body)
                    .scrollContentBackground(.hidden)
                    .focused(focused)
                    .frame(minHeight: 72, maxHeight: 160)
                    .padding(6)
                    .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            HStack(spacing: 8) {
                Text("Markdown · `c` opens this").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                Spacer(minLength: 6)
                if sending { ProgressView().controlSize(.mini) }
                KbdHint("⌘↵")
                Button("Comment", action: submit)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .kitTile()
    }
}

/// The Overview's right column (D8): reviewers, assignees, labels and the
/// milestone, each with its picker — the place Files keeps its tree.
struct PRMetadataColumn: View {
    let pr: ChangeRequest
    let activity: ChangeRequestActivity?
    let verbs: [PRVerb]
    let reach: (PRVerb) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Reviewers", field: .reviewers) {
                    ForEach(pr.reviews, id: \.author) { review in
                        HStack(spacing: 6) {
                            Text(review.author).font(Theme.Typo.meta).foregroundStyle(Theme.ink)
                            PRTimeline.chip(review.verdict, comments: 0)
                        }
                    }
                    ForEach(pr.requested, id: \.self) { name in
                        HStack(spacing: 6) {
                            Text(name).font(Theme.Typo.meta).foregroundStyle(Theme.ink)
                            Chip("asked", .dashed)
                        }
                    }
                    if pr.reviews.isEmpty, pr.requested.isEmpty { none }
                }
                section("Assignees", field: .assignees) {
                    ForEach(activity?.assignees ?? []) { person in
                        Text(person.login).font(Theme.Typo.meta).foregroundStyle(Theme.ink)
                    }
                    if activity?.assignees.isEmpty ?? true { none }
                }
                section("Labels", field: .labels) {
                    FlowRow(hSpacing: 4, vSpacing: 4) {
                        ForEach(activity?.labels ?? []) { label in
                            HStack(spacing: 4) {
                                Circle().fill(Color(labelHex: label.color) ?? .gray).frame(width: 7, height: 7)
                                Text(label.name).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Color.white.opacity(0.06), in: Capsule())
                        }
                    }
                    if activity?.labels.isEmpty ?? true { none }
                }
                section("Milestone", field: .milestone) {
                    if let milestone = activity?.milestone {
                        Text(milestone.title).font(Theme.Typo.meta).foregroundStyle(Theme.ink)
                    } else {
                        none
                    }
                }
            }
            .padding(14)
        }
    }

    private var none: some View {
        Text("None").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
    }

    private func section(_ title: String, field: MetadataField, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).microLabel()
                Spacer(minLength: 4)
                if let verb = verbs.first(where: { $0.action == .pick(field) }) {
                    Button { reach(verb) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil").font(.system(size: 9, weight: .semibold))
                            if let key = verb.key { Text(key.uppercased()).font(Theme.Typo.micro) }
                        }
                        .foregroundStyle(verb.enabled ? Theme.ink2 : Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!verb.enabled)
                    .help(verb.disabledReason ?? "Edit \(title.lowercased())")
                }
            }
            content()
        }
    }
}
