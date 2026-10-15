import XCTest
@testable import Pultik

/// The copilot shell's routing (WP3): the `.x` grammar enters modules,
/// selection is held by object id, ⌘3 is CI, ↵ opens a detail and Esc peels
/// exactly one layer.
@MainActor
final class ModuleRouterTests: XCTestCase {
    private func intent(_ key: KeyStroke.Key, command: Bool = false, _ context: KeyContext) -> KeyIntent? {
        KeyboardCoordinator.intent(for: KeyStroke(key: key, command: command), in: context)
    }

    /// `.c failed` is CI scoped to `failed`; a palette page (`.t`) typed
    /// inside a module drops the scope and stays global.
    func testDotAliasEntersModuleAndPalettePagesStayGlobal() {
        let router = ModuleRouter()
        router.type(".c failed")
        XCTAssertEqual(router.module, .ci)
        XCTAssertEqual(router.text, "failed")
        router.type(".t groceries")
        XCTAssertNil(router.module)
        XCTAssertEqual(router.text, ".t groceries")
    }

    /// `.d` enters Devbox at once; the rest of `devbox` and the space that
    /// ends the token are swallowed, the next letter is filter text.
    func testTokenTailNeverBecomesTheFilter() {
        let router = ModuleRouter()
        router.type(".d")
        XCTAssertEqual(router.module, .devbox)
        for key in ["e", "v", "b", "o", "x", " "] {
            XCTAssertTrue(router.swallowTokenKey(key), key)
        }
        XCTAssertFalse(router.swallowTokenKey("p"))
    }

    /// `.f` lands on Mac's fans with their detail open; Mac's own token stays `.mac`.
    func testFansAliasOpensMacFans() {
        let router = ModuleRouter()
        router.type(".f")
        XCTAssertEqual(router.module, .mac)
        XCTAssertEqual(router.selection, PaletteMode.macFans)
        XCTAssertTrue(router.detailOpen)
        XCTAssertEqual(PaletteMode.alias(of: .mac), .mac)
    }

    /// `.prs` enters PRs and `.ho` lands on Home with `me` swallowed, while
    /// `.p` stays the prod page and `.h` waits for the key that says which.
    func testHomeAndPRsAliasesKeepTheOlderPrefixes() {
        XCTAssertEqual(PaletteMode.parse(".p")?.mode, .prod)
        XCTAssertNil(PaletteMode.parse(".h"), "health and home share it: the picker shows both")
        let router = ModuleRouter()
        router.type(".prs")
        XCTAssertEqual(router.module, .prs)
        router.type(".h sk")
        XCTAssertEqual(router.module, .prod)
        XCTAssertEqual(router.text, "sk")
        router.type(".ho")
        XCTAssertNil(router.module)
        XCTAssertTrue(router.swallowTokenKey("m"))
        XCTAssertTrue(router.swallowTokenKey("e"))
        XCTAssertEqual(router.text, "")
    }

    /// ←/→ on an empty field walk the strip, wrapping; with text they stay the caret's.
    func testArrowsOnAnEmptyFieldWalkTheStrip() {
        XCTAssertEqual(intent(.right, KeyContext()), .module(.prs))
        XCTAssertEqual(intent(.left, KeyContext()), .module(.mac))
        XCTAssertEqual(intent(.right, KeyContext(module: .mac)), .module(.home))
        XCTAssertEqual(intent(.left, KeyContext(module: .ci, selection: "run:1", detailOpen: true)), .module(.prs))
        XCTAssertNil(intent(.right, KeyContext(module: .ci, text: "failed")))
        XCTAssertNil(intent(.left, KeyContext(completion: true)))
    }

    /// Each module keeps its own selection by id; leaving closes the detail.
    func testSelectionIsRememberedPerModuleByID() {
        let router = ModuleRouter()
        router.enter(.ci)
        router.openDetail("run:2")
        router.enter(.prod)
        XCTAssertNil(router.selection)
        XCTAssertFalse(router.detailOpen)
        router.enter(.ci)
        XCTAssertEqual(router.selection, "run:2")
        router.leave()
        XCTAssertNil(router.module)
        XCTAssertNil(router.selection)
    }

    func testKeysSwitchModulesWalkTheListAndOpenDetails() {
        XCTAssertEqual(intent(.character("3"), command: true, KeyContext()), .module(.ci))
        var context = KeyContext(module: .ci, items: ["run:1", "run:2"])
        XCTAssertEqual(intent(.down, context), .select("run:1"))
        context.selection = "run:1"
        XCTAssertEqual(intent(.down, context), .select("run:2"))
        XCTAssertEqual(intent(.up, context), .select(nil))
        XCTAssertEqual(intent(.enter, context), .openDetail("run:1"))
        XCTAssertEqual(intent(.enter, command: true, context), .openInBrowser("run:1"))
        // A selection the filter hides is no selection: ↵ opens the first.
        context.selection = "run:9"
        XCTAssertEqual(intent(.enter, context), .openDetail("run:1"))
        XCTAssertEqual(intent(.backspace, KeyContext(module: .ci)), .widenScope)
        XCTAssertNil(intent(.backspace, KeyContext(module: .ci, text: "f")))
    }

    /// ⌘R re-runs only from a failed run's open detail in CI.
    func testCommandRRerunsOnlyAnOpenFailedRun() {
        let open = KeyContext(module: .ci, items: ["run:1"], selection: "run:1", detailOpen: true)
        XCTAssertEqual(intent(.character("r"), command: true, open), .rerunFailed("run:1"))
        XCTAssertNil(intent(.character("r"), command: true, KeyContext(module: .ci, items: ["run:1"], selection: "run:1")),
                     "a selected row whose detail is closed")
        XCTAssertNil(intent(.character("r"), command: true,
                            KeyContext(module: .ci, items: ["job:7"], selection: "job:7", detailOpen: true)),
                     "a running job is not a failed run")
        XCTAssertNil(intent(.character("r"), command: true,
                            KeyContext(module: .prs, items: ["run:1"], selection: "run:1", detailOpen: true)))
    }

    /// Text → detail → selection → module → close; never close early.
    func testEscPeelsOneLayerAtATime() {
        var context = KeyContext(module: .ci, text: "failed", selection: "run:1", detailOpen: true)
        var peeled: [EscStep] = []
        while peeled.last != .close {
            let step = KeyboardCoordinator.escape(context)
            peeled.append(step)
            switch step {
            case .clearText: context.text = ""
            case .closeDetail: context.detailOpen = false
            case .clearSelection: context.selection = nil
            case .leaveModule: context.module = nil
            default: break
            }
        }
        XCTAssertEqual(peeled, [.clearText, .closeDetail, .clearSelection, .leaveModule, .close])
        XCTAssertEqual(KeyboardCoordinator.escape(KeyContext(text: "x", eve: true, noteEditing: true)), .cancelNoteEdit)
    }

    // MARK: - Stay in Pultík (D2, D3, D11; AC 7)

    /// ⇥/⇧⇥ walk the detail's targets, ↵ on a focused badge slides its run
    /// card over the PR, Esc clears the ring, then the card — whose badge is
    /// focused again — then the detail.
    func testTabFocusesBadgesEnterPushesTheRunCardAndEscPeelsInOrder() {
        let badge = "run:gh:o/r/run/42"
        let targets = [badge, "thread:T1", "file:a.swift"]
        let detail = KeyContext(module: .prs, items: ["pr:1"], selection: "pr:1", detailOpen: true, focusTargets: targets)
        XCTAssertEqual(KeyboardCoordinator.intent(for: KeyStroke(key: .tab), in: detail), .focus(1))
        XCTAssertEqual(KeyboardCoordinator.intent(for: KeyStroke(key: .tab, shift: true), in: detail), .focus(-1))
        XCTAssertEqual(intent(.enter, detail), .openDetail("pr:1"), "no ring: ↵ is the list's")

        let router = ModuleRouter()
        router.enter(.prs, select: "pr:1", openDetail: true)
        router.setFocusTargets(targets)
        router.moveFocus(-1)
        XCTAssertEqual(router.focus, "file:a.swift", "⇧⇥ from none starts at the last")
        router.moveFocus(1)
        XCTAssertEqual(router.focus, badge, "wrapping")
        var focused = detail
        focused.focus = router.focus
        XCTAssertEqual(intent(.enter, focused), .activateFocus)
        XCTAssertEqual(intent(.esc, focused), .escape(.clearFocus))
        router.activateFocus()
        XCTAssertEqual(router.stack, [DetailRef(kind: .run, id: "gh:o/r/run/42")])
        XCTAssertNil(router.focus)

        var carded = detail
        carded.card = "gh:o/r/run/42"
        XCTAssertEqual(intent(.esc, carded), .escape(.popCard))
        XCTAssertEqual(intent(.down, carded), .cardMove(1))
        XCTAssertEqual(intent(.tab, carded), .cardColumn(1))
        XCTAssertEqual(intent(.enter, carded), .cardOpen)
        XCTAssertEqual(intent(.character("r"), command: true, carded), .rerunFailed("run:gh:o/r/run/42"))
        router.pop()
        XCTAssertTrue(router.stack.isEmpty)
        XCTAssertEqual(router.focus, badge, "the badge is refocused after the pop")
        XCTAssertEqual(intent(.esc, detail), .escape(.closeDetail))

        router.activateFocus()
        router.select("pr:2")
        XCTAssertTrue(router.stack.isEmpty, "a new selection drops the card")
        XCTAssertNil(router.focus)
    }

    /// The run card's walk: ↑/↓ inside a column, ⇥ between columns, ↵ narrows
    /// the next column from the pick.
    func testTheRunCardWalksItsColumns() {
        let router = ModuleRouter()
        router.enter(.ci, select: "run:42", openDetail: true)
        router.push(DetailRef(kind: .run, id: "gh:o/r/run/42"))
        router.setCardColumns([["job:1", "job:2"], ["step:1:1", "step:1:2"], []])
        router.moveInCard(1)
        XCTAssertEqual(router.stack.last?.picks[0], "job:1")
        router.moveInCard(1)
        XCTAssertEqual(router.stack.last?.picks[0], "job:2")
        router.openInCard()
        XCTAssertEqual(router.stack.last?.column, 1)
        router.moveCardColumn(-1)
        XCTAssertEqual(router.stack.last?.column, 0)
        router.setCardColumns([["job:1"], [], []])
        XCTAssertNil(router.stack.last?.picks[0], "a pick the card no longer draws is dropped")
    }

    /// The place is the module, filter, selection, detail, inspector and
    /// stack — never the global query — and restores exactly.
    func testThePlaceRestoresTheDetailAndItsStack() {
        let router = ModuleRouter()
        router.enter(.prs, filter: "pool", select: "pr:7", openDetail: true)
        router.push(DetailRef(kind: .run, id: "gh:o/r/run/9"))
        let place = router.place
        router.leave(keeping: "anything typed")
        XCTAssertEqual(router.place, .home, "the global query is no place")
        router.restore(place)
        XCTAssertEqual([router.module?.rawValue, router.text, router.selection], ["prs", "pool", "pr:7"])
        XCTAssertTrue(router.detailOpen)
        XCTAssertEqual(router.stack, place.stack)
        router.restore(.home)
        XCTAssertNil(router.module)
        XCTAssertTrue(router.stack.isEmpty)
    }

    /// AC 13: Settings ▸ Modules' order is the strip's — ⌘1–9 and ←/→ follow it.
    func testTheModuleOrderDrivesCommandDigitsAndArrows() {
        let order: [PanelModule] = [.home, .ci, .prs, .prod, .devbox, .work, .sessions, .estate, .mac]
        XCTAssertEqual(intent(.character("2"), command: true, KeyContext(order: order)), .module(.ci))
        XCTAssertEqual(intent(.right, KeyContext(order: order)), .module(.ci))
        XCTAssertEqual(intent(.right, KeyContext(module: .ci, order: order)), .module(.prs))
        XCTAssertEqual(PanelModule.prs.number(in: order), 3)
    }

    /// Bulk D1: ⌘-click toggles, ⇧-click marks the range from the cursor,
    /// ⇧↓/⇧↑ extend and turning back unmarks, ⌘A marks what is shown (then
    /// unmarks), unmarkable rows are passed over, and leaving drops the marks.
    func testMarksAreFindersRangesByID() {
        let items = ["fans", "finding:a", "finding:b", "finding:c", "finding:d"]
        let markable = Array(items.dropFirst())
        let router = ModuleRouter()
        router.enter(.mac, select: "finding:a", openDetail: true)
        router.toggleMark("finding:b")
        XCTAssertEqual(router.marks, ["finding:b"])
        XCTAssertEqual(router.selection, "finding:b")
        XCTAssertFalse(router.detailOpen)
        router.markRange(to: "finding:d", in: markable)
        XCTAssertEqual(router.marks, ["finding:b", "finding:c", "finding:d"])
        router.toggleMark("finding:c")
        XCTAssertEqual(router.marks, ["finding:b", "finding:d"])

        router.clearMarks()
        router.select("fans")
        router.extendMarks(1, in: items, markable: markable)
        router.extendMarks(1, in: items, markable: markable)
        XCTAssertEqual(router.marks, ["finding:a", "finding:b"])
        router.extendMarks(-1, in: items, markable: markable)
        XCTAssertEqual(router.marks, ["finding:a"])
        XCTAssertEqual(router.selection, "finding:a")

        router.markAll(["finding:c", "finding:d"])
        XCTAssertEqual(router.marks, ["finding:c", "finding:d"])
        router.markAll(["finding:c", "finding:d"])
        XCTAssertTrue(router.marks.isEmpty)

        // A hidden run card never outlives the detail marking closed (⌘↵ is the row's).
        router.openDetail("finding:a")
        router.push(DetailRef(kind: .run, id: "o/r#1"))
        router.markAll(markable)
        XCTAssertFalse(router.detailOpen)
        XCTAssertTrue(router.stack.isEmpty)
        router.enter(.devbox)
        XCTAssertTrue(router.marks.isEmpty)
    }

    // MARK: - PR workbench (D5, AC 1)

    /// ↵ on a PR opens it entered: ←/→ walk its tabs wrapping, ↑/↓ scroll,
    /// letters are verbs, and Esc leaves before it closes; outside a PR the
    /// arrows still walk the strip.
    func testEnterOpensAPREnteredAndItsKeysAreTheWorkbenchs() {
        let router = ModuleRouter()
        router.enter(.prs)
        let list = KeyContext(module: .prs, items: ["pr:1", "pr:2"], selection: "pr:1")
        XCTAssertEqual(intent(.enter, list), .openDetail("pr:1"))
        router.openDetail("pr:1", entering: true)
        XCTAssertTrue(router.entered)
        router.setTabs(["overview", "commits", "files", "checks"])
        XCTAssertEqual(router.shownTab, "overview")

        var inside = KeyContext(module: .prs, items: ["pr:1", "pr:2"], selection: "pr:1", detailOpen: true,
                                entered: true, verbKeys: ["m", "c"])
        XCTAssertEqual(intent(.right, inside), .tab(1))
        XCTAssertEqual(intent(.left, inside), .tab(-1))
        var walked: [String?] = []
        for _ in 0 ..< 4 {
            router.moveTab(1)
            walked.append(router.shownTab)
        }
        XCTAssertEqual(walked, ["commits", "files", "checks", "overview"], "wrapping")
        router.moveTab(-1)
        XCTAssertEqual(router.shownTab, "checks")

        XCTAssertEqual(intent(.down, inside), .scroll(.step(1)))
        XCTAssertEqual(intent(.up, inside), .scroll(.step(-1)))
        XCTAssertEqual(KeyboardCoordinator.intent(for: KeyStroke(key: .down, shift: true), in: inside), .scroll(.page(1)))
        XCTAssertEqual(intent(.up, command: true, inside), .scroll(.edge(-1)))
        XCTAssertEqual(intent(.character("m"), inside), .verb("m"))
        XCTAssertEqual(intent(.character("x"), inside), .ignore, "a letter with no verb never filters the list")
        XCTAssertEqual(intent(.character(" "), inside), .scroll(.page(1)))
        XCTAssertEqual(intent(.backspace, inside), .ignore)
        XCTAssertEqual(intent(.character("k"), command: true, inside), .verbMenu)
        XCTAssertEqual(intent(.enter, command: true, inside), .openInBrowser("pr:1"))

        // Esc: the ring, then the workbench, then the detail.
        inside.focus = "file:a.swift"
        XCTAssertEqual(intent(.esc, inside), .escape(.clearFocus))
        inside.focus = nil
        XCTAssertEqual(intent(.esc, inside), .escape(.leaveDetail))
        router.leaveDetail()
        XCTAssertFalse(router.entered)
        XCTAssertTrue(router.detailOpen, "the PR stays shown beside the list")

        // Left, letters filter and the arrows walk the strip and the list again.
        let left = KeyContext(module: .prs, items: ["pr:1", "pr:2"], selection: "pr:1", detailOpen: true)
        XCTAssertNil(intent(.character("m"), left))
        XCTAssertEqual(intent(.down, left), .select("pr:2"))
        XCTAssertEqual(intent(.right, left), .module(.ci))
        XCTAssertEqual(intent(.esc, left), .escape(.closeDetail))
        router.select("pr:2")
        XCTAssertEqual(router.shownTab, "checks", "the tab stays while the list is walked")
        router.closeDetail()
        router.openDetail("pr:2", entering: true)
        XCTAssertEqual(router.shownTab, "overview", "a detail opened from closed starts on its first tab")
    }

    /// Only a workbench enters, and a click opens without entering; the place
    /// keeps the workbench and its tab.
    func testOnlyWorkbenchesEnterAndThePlaceKeepsTheTab() {
        let router = ModuleRouter()
        router.enter(.ci)
        router.openDetail("run:1", entering: true)
        XCTAssertFalse(router.entered, "a CI run has no tabs")
        router.enter(.prs)
        router.openDetail("pr:1")
        XCTAssertFalse(router.entered, "a click opens without entering")
        router.enterDetail()
        router.setTabs(["overview", "commits", "files", "checks"])
        router.selectTab("files")
        let place = router.place
        router.leave()
        router.restore(place)
        XCTAssertTrue(router.entered)
        XCTAssertEqual(router.shownTab, "files")
        XCTAssertNil(intent(.character("k"), command: true, KeyContext(module: .ci, selection: "run:1", detailOpen: true)))
    }

    /// AC 9: `m` reaches the merge confirm, which names the method and the
    /// branch; inside it only ↵ merges, no letter reaches another verb, Esc
    /// cancels. Outside it ↵ never mutates.
    func testMOpensTheMergeConfirmAndOnlyEnterInsideItMerges() {
        let pr = ChangeRequest(ref: ChangeRequestRef(repo: "o/r", number: 7), title: "Pool", url: "", body: "", state: .open,
                               isDraft: false, author: "ana", createdAt: Date(), updatedAt: Date(), mergedAt: nil,
                               baseRef: "main", headRef: "feat/pool", baseSHA: "b", headSHA: "h", additions: 1, deletions: 0,
                               changedFiles: 1, mergeable: .mergeable, decision: nil, reviews: [], requested: [],
                               threads: [], checks: [], threadsTruncated: false, checksTruncated: false)
        let activity = ChangeRequestActivity(
            nodeID: "PR_1", updatedAt: Date(), headSHA: "h", viewer: "lukas", timeline: [], timelineTruncated: false,
            labels: [], assignees: [], milestone: nil, requestedReviewers: [], requestedTeams: [],
            merge: MergeOptions(methods: [.merge, .squash], preferred: .squash, autoMergeAllowed: true, autoMerge: nil,
                                deleteBranchOnMerge: false, state: .clean, headRefID: "REF", settled: true),
            rights: ViewerRights(canUpdate: true, canMergeAsAdmin: false, canUpdateBranch: false, canDeleteHeadRef: false,
                                 canEnableAutoMerge: true, canDisableAutoMerge: false),
            pendingReview: nil, suggestedReviewers: [])
        let verbs = PRVerbCatalogue.verbs(pr, activity: activity)
        XCTAssertEqual(verbs.first { $0.key == "m" }?.action, .merge)
        XCTAssertEqual(PRVerbCatalogue.keys(verbs), ["m", "a", "r", "c", "e", "l"])
        XCTAssertEqual(PRVerbCatalogue.mergeTitle(.squash, base: pr.baseRef), "Squash and merge into main")
        XCTAssertEqual(verbs.first { $0.id == "close" }?.action, .confirm(.close), "close confirms too")
        XCTAssertNil(PRVerbCatalogue.keys(PRVerbCatalogue.verbs(pr, activity: nil)).first { $0 == "m" },
                     "no merge letter before GitHub says what it allows")

        let inside = KeyContext(module: .prs, items: ["pr:7"], selection: "pr:7", detailOpen: true, entered: true,
                                verbKeys: PRVerbCatalogue.keys(verbs))
        XCTAssertEqual(intent(.character("m"), inside), .verb("m"))
        XCTAssertEqual(intent(.enter, inside), .ignore, "↵ outside the confirm never merges")
        var confirm = inside
        confirm.verbConfirm = true
        XCTAssertEqual(intent(.enter, confirm), .submitComposer, "↵ inside the confirm merges")
        XCTAssertEqual(intent(.character("m"), confirm), .ignore)
        XCTAssertEqual(intent(.character("c"), confirm), .ignore)
        XCTAssertEqual(intent(.esc, confirm), .escape(.closeComposer))
    }

    /// Bulk D1: ⇧-arrows and ⌘A mark only where the list has bulk verbs;
    /// with the bulk pane up ↵ reaches for its first verb, never a detail,
    /// ⇥ walks its verbs, and Esc drops the marks before the filter.
    func testBulkKeysMarkFocusAndPeelBeforeTheFilter() {
        let shiftDown = KeyStroke(key: .down, shift: true)
        let plain = KeyContext(module: .mac, items: ["finding:a"], selection: "finding:a")
        XCTAssertEqual(KeyboardCoordinator.intent(for: shiftDown, in: plain), .select("finding:a"))
        XCTAssertNil(intent(.character("a"), command: true, plain))

        var marking = plain
        marking.markable = ["finding:a"]
        XCTAssertEqual(KeyboardCoordinator.intent(for: shiftDown, in: marking), .extendMarks(1))
        XCTAssertEqual(intent(.character("a"), command: true, marking), .markAll)

        var pane = marking
        pane.text = "agent"
        pane.bulk = true
        pane.focusTargets = ["bulk:stop"]
        XCTAssertEqual(intent(.enter, pane), .focus(1))
        XCTAssertEqual(intent(.tab, pane), .focus(1))
        XCTAssertEqual(intent(.esc, pane), .escape(.clearMarks))
        pane.focus = "bulk:stop"
        XCTAssertEqual(intent(.enter, pane), .activateFocus)
        XCTAssertEqual(intent(.esc, pane), .escape(.clearFocus))
        pane.focus = nil
        pane.bulkConfirm = true
        XCTAssertEqual(intent(.esc, pane), .escape(.cancelConfirm))

        let router = ModuleRouter()
        router.enter(.mac)
        router.toggleMark("finding:a")
        router.confirm("stop")
        router.clearMarks()
        XCTAssertNil(router.confirming)
    }
}
