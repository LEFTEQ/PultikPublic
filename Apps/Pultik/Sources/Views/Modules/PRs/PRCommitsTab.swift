import SwiftUI

/// The workbench's Commits tab (PR workbench WP5): `base..head` from the
/// mirror's log, oldest first — no API request. ⇥ walks the commits and ↵
/// (or a click) scopes Files changed to the one ringed.
struct PRCommitsTab: View {
    let commits: [ChangeCommit]?
    let failure: String?
    let active: Bool
    /// The commit Files changed is scoped to, if any.
    let scoped: String?
    let open: (ChangeCommit) -> Void
    @Environment(ModuleRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func focusTargets(_ commits: [ChangeCommit]?) -> [String] {
        commits?.map { "commit:\($0.sha)" } ?? []
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let commits {
                        Text(commits.count == 1 ? "1 commit" : "\(commits.count) commits").microLabel()
                            .padding(.bottom, 6)
                        ForEach(commits) { commit in
                            row(commit)
                                .focusRing(router.focus == "commit:\(commit.sha)", radius: Theme.Radius.row)
                                .id("commit:\(commit.sha)")
                        }
                    } else if let failure {
                        Text(verbatim: "Commits not loaded — \(failure)").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                    } else {
                        SkeletonBars(widths: [0.6, 0.45, 0.7])
                    }
                }
                .padding(14)
            }
            .workbenchScroll(active: active)
            .onChange(of: router.focus) { _, focus in
                guard active, let focus, focus.hasPrefix("commit:") else { return }
                withAnimation(Theme.Motion.focus(reduceMotion)) { scroller.scrollTo(focus, anchor: .center) }
            }
        }
        .onChange(of: router.activated) { _, target in
            guard active, let target, target.hasPrefix("commit:"),
                  let commit = commits?.first(where: { "commit:\($0.sha)" == target }) else { return }
            router.consumeActivation()
            open(commit)
        }
    }

    private func row(_ commit: ChangeCommit) -> some View {
        Button { open(commit) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(commit.sha.prefix(7))).font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(verbatim: "\(commit.author) · \(PultikFormat.ago(commit.date, now: Date())) · \(commit.files) file\(commit.files == 1 ? "" : "s")")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 8)
                Text(verbatim: "+\(commit.additions)").font(Theme.Typo.figure).foregroundStyle(Theme.ok)
                Text(verbatim: "−\(commit.deletions)").font(Theme.Typo.figure).foregroundStyle(Theme.danger)
                if scoped == commit.sha { Chip("in Files", .selected) }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("↵ shows this commit's changes")
    }
}
