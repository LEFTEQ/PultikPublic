import Foundation

/// One PR verb as the workbench offers it (PR workbench D4, D5): its title,
/// letter, group in the verb bar and what reaching it does. Merge and close
/// always open a confirm — only ↵ inside it runs them.
struct PRVerb: Identifiable, Equatable {
    enum Group: String { case merge, review, more }

    enum Action: Equatable {
        /// Runs at once: nothing to confirm or type.
        case run(ChangeRequestVerb)
        /// A confirm names it; only ↵ inside runs it.
        case confirm(ChangeRequestVerb)
        /// The merge confirm, with its method and delete-branch choice.
        case merge
        /// The review sheet, its verdict preset.
        case review(ReviewEvent)
        /// The Overview composer.
        case comment
        /// Title and description.
        case edit
        case pick(MetadataField)
    }

    let id: String
    let title: String
    let symbol: String
    var key: String?
    let group: Group
    let action: Action
    /// Why it cannot run now; nil = it can.
    var disabledReason: String?

    var enabled: Bool { disabledReason == nil }
}

enum MetadataField: String, CaseIterable, Equatable {
    case reviewers, assignees, labels, milestone
}

/// Every verb a PR offers, read by the verb bar, ⌘K and the letters alike.
/// Foundation-only: `Tests/ModuleRouterTests.swift` pins the letters and
/// the confirms.
enum PRVerbCatalogue {
    static func verbs(_ pr: ChangeRequest, activity: ChangeRequestActivity?) -> [PRVerb] {
        let open = pr.state == .open
        let loading = activity == nil ? "Reading what GitHub allows…" : nil
        let rights = activity?.rights
        let canUpdate = rights?.canUpdate == true
        let own = activity.map { $0.viewer == pr.author } ?? false
        let edits = loading ?? (canUpdate ? nil : "You cannot edit this pull request")
        var verbs: [PRVerb] = [
            PRVerb(id: "merge", title: "Merge…", symbol: "arrow.triangle.merge", key: "m", group: .merge,
                   action: .merge, disabledReason: mergeBlock(pr, activity)),
        ]
        if let merge = activity?.merge {
            if merge.autoMerge == nil {
                verbs.append(PRVerb(id: "autoMerge", title: "Enable auto-merge", symbol: "clock.arrow.circlepath",
                                    group: .merge, action: .run(.enableAutoMerge(merge.preferred ?? merge.methods.first ?? .merge)),
                                    disabledReason: !open || pr.isDraft ? "Only an open, ready pull request"
                                        : !merge.autoMergeAllowed ? "The repository does not allow auto-merge"
                                        : rights?.canEnableAutoMerge == true ? nil : "GitHub does not offer auto-merge here"))
            } else {
                verbs.append(PRVerb(id: "autoMergeOff", title: "Disable auto-merge", symbol: "clock.badge.xmark",
                                    group: .merge, action: .run(.disableAutoMerge),
                                    disabledReason: rights?.canDisableAutoMerge == true ? nil : "You cannot disable it"))
            }
            verbs.append(PRVerb(id: "updateBranch", title: "Update branch", symbol: "arrow.down.to.line", group: .merge,
                                action: .run(.updateBranch(rebase: false, expectedHead: pr.headSHA)),
                                disabledReason: !open ? "Only an open pull request"
                                    : rights?.canUpdateBranch == true ? nil : "The branch is current or not yours to update"))
        }
        verbs.append(open
            ? PRVerb(id: "close", title: "Close…", symbol: "xmark.circle", group: .merge, action: .confirm(.close),
                     disabledReason: edits)
            : PRVerb(id: "reopen", title: "Reopen", symbol: "arrow.uturn.backward.circle", group: .merge,
                     action: .run(.reopen), disabledReason: pr.state == .merged ? "A merged pull request stays merged" : edits))
        if open {
            verbs.append(pr.isDraft
                ? PRVerb(id: "ready", title: "Ready for review", symbol: "eye", group: .merge, action: .run(.markReady),
                         disabledReason: edits)
                : PRVerb(id: "draft", title: "Convert to draft", symbol: "pencil.and.outline", group: .merge,
                         action: .run(.convertToDraft), disabledReason: edits))
        }
        if pr.state == .merged, activity?.merge.headRefID != nil {
            verbs.append(PRVerb(id: "deleteBranch", title: "Delete branch", symbol: "trash", group: .merge,
                                action: .confirm(.deleteBranch),
                                disabledReason: rights?.canDeleteHeadRef == true ? nil : "You cannot delete this branch"))
        }
        let reviewBlock = loading ?? (own ? "You cannot review your own pull request" : !open ? "Only an open pull request" : nil)
        verbs += [
            PRVerb(id: "approve", title: "Approve…", symbol: "checkmark.circle", key: "a", group: .review,
                   action: .review(.approve), disabledReason: reviewBlock),
            PRVerb(id: "requestChanges", title: "Request changes…", symbol: "exclamationmark.bubble", key: "r",
                   group: .review, action: .review(.requestChanges), disabledReason: reviewBlock),
            PRVerb(id: "reviewComment", title: "Comment review…", symbol: "text.bubble", group: .review,
                   action: .review(.comment), disabledReason: loading),
        ]
        if let pending = activity?.pendingReview {
            verbs.append(PRVerb(id: "discardReview",
                                title: "Discard pending review (\(pending.comments.count))",
                                symbol: "trash", group: .review, action: .confirm(.discardPendingReview)))
        }
        verbs += [
            PRVerb(id: "comment", title: "Comment", symbol: "bubble.left", key: "c", group: .more, action: .comment),
            PRVerb(id: "edit", title: "Edit title and description…", symbol: "pencil", key: "e", group: .more,
                   action: .edit, disabledReason: edits),
            PRVerb(id: "labels", title: "Labels…", symbol: "tag", key: "l", group: .more, action: .pick(.labels),
                   disabledReason: edits),
            PRVerb(id: "assignees", title: "Assignees…", symbol: "person", group: .more, action: .pick(.assignees),
                   disabledReason: edits),
            PRVerb(id: "reviewers", title: "Reviewers…", symbol: "person.2", group: .more, action: .pick(.reviewers),
                   disabledReason: edits),
            PRVerb(id: "milestone", title: "Milestone…", symbol: "flag", group: .more, action: .pick(.milestone),
                   disabledReason: edits),
        ]
        return verbs
    }

    /// The letters the workbench takes while entered: the enabled verbs'.
    static func keys(_ verbs: [PRVerb]) -> Set<String> {
        Set(verbs.compactMap { $0.enabled ? $0.key : nil })
    }

    /// `Squash and merge into main` — what the confirm says ↵ will do.
    static func mergeTitle(_ method: MergeMethod, base: String) -> String {
        switch method {
        case .merge: "Merge into \(base)"
        case .squash: "Squash and merge into \(base)"
        case .rebase: "Rebase and merge into \(base)"
        }
    }

    /// Why GitHub would refuse a merge now; nil = it would take it.
    static func mergeBlock(_ pr: ChangeRequest, _ activity: ChangeRequestActivity?) -> String? {
        guard pr.state == .open else { return pr.state == .merged ? "Already merged" : "Closed" }
        if pr.isDraft { return "A draft — mark it ready first" }
        guard let activity else { return "Reading what GitHub allows…" }
        let admin = activity.rights.canMergeAsAdmin
        guard activity.rights.canUpdate || admin else { return "You cannot merge into this repository" }
        switch activity.merge.state {
        case .clean, .unstable, .hasHooks: return nil
        case .blocked: return admin ? nil : "Blocked by the branch rules"
        case .behind: return "Behind \(pr.baseRef) — update the branch"
        case .dirty: return "Conflicts with \(pr.baseRef)"
        case .draft: return "A draft — mark it ready first"
        case .unknown: return "GitHub is still working out mergeability"
        }
    }
}
