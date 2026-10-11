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
}
