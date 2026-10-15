import Foundation
#if !SWIFT_PACKAGE
import AppKit
#endif

/// A keystroke as the coordinator reads it — AppKit-free, so the routing
/// table is pinned in Foundation (`Tests/ModuleRouterTests.swift`).
struct KeyStroke: Equatable {
    enum Key: Equatable {
        case up, down, left, right, enter, tab, esc, backspace
        /// F12: code navigation (⇧ for references).
        case f12
        /// Typed text, or a ⌘ chord's key (`3`, `i`, `v`, `c`).
        case character(String)
    }

    let key: Key
    var command = false
    var shift = false
    /// An ⌥ chord the panel owns (⌥Z); other ⌥ keys stay the system's.
    var option = false
}

/// The panel as the keyboard sees it at the moment of a keystroke.
struct KeyContext {
    /// The search field owns the keys (or a debug-driver key addressed to it).
    var fieldFocused = true
    /// Another text view (a note editor) holds focus: it keeps its editing
    /// keys, never Esc.
    var textViewFocused = false
    var module: PanelModule?
    /// The strip's order (Settings ▸ Modules): ⌘1–9 and ←/→ follow it.
    var order: [PanelModule] = PanelModule.allCases
    var text = ""
    /// The unread tail of a `.x` alias (`ModuleRouter.pendingToken`).
    var pendingToken = ""
    /// The list on screen, object ids in drawn order: a module's objects,
    /// Home's PR rows, or the palette's results.
    var items: [String] = []
    var selection: String?
    /// The selected object's detail is drawn.
    var detailOpen = false
    var pathCard = false
    /// Slash verbs or the mode picker are listed: ⇥ completes the first.
    var completion = false
    /// `.notes` with text: ⌘↵ saves it even when it matches a note.
    var notesDraft = false
    /// The todos tab or a project page replaces the list.
    var page = false
    var eve = false
    var noteEditing = false
    var noteExpanded = false
    /// The detail's ⇥ targets on its top layer, and the one focused (D3).
    var focusTargets: [String] = []
    var focus: String?
    /// The top card on the detail (D2), by its object key: its keys are the
    /// card's, and ⌘R re-runs a failed run card's failed jobs.
    var card: String?
    /// The rows a bulk verb can take, in drawn order (bulk actions D1):
    /// ⇧↑/⇧↓ and ⌘A mark them. Empty = the list has no bulk verb.
    var markable: [String] = []
    /// The bulk pane holds the detail's place — marks, or a batch on screen.
    /// Its verbs are the ⇥ targets; ↵ only ever focuses or activates one.
    var bulk = false
    /// A destructive bulk verb's confirm is open in the pane.
    var bulkConfirm = false
    /// ↵ entered the shown detail (PR workbench D5): ←/→ are its tabs, ↑/↓
    /// scroll it and `verbKeys` are its verbs.
    var entered = false
    var verbKeys: Set<String> = []
    /// A code canvas is the shown tab (⌥Z wraps it), and holds a selection (⌘C).
    var codeShown = false
    var codeSelection = false
    /// A workbench composer (a comment, a review comment) is open: ⌘↵
    /// submits it and Esc closes it before anything else peels.
    var composing = false
    /// A verb's confirm (merge, close) is open: only ↵ inside it runs the
    /// verb, Esc cancels it, and no letter reaches another verb (D5).
    var verbConfirm = false
}

/// One peel of Esc (copilot shell layered Esc): note edit → expanded note →
/// eve → the detail's focus ring → the top card (stay in Pultík D3) → the
/// entered workbench (PR workbench D5) → the bulk confirm → the marks and the
/// bulk pane (bulk actions D1) → the field's text (completion, path card,
/// filter) → detail → selection → page → module → Home → close. It never
/// closes the panel while a layer remains.
enum EscStep: String, Equatable {
    case cancelNoteEdit, closeComposer, blurText, foldNote, dismissEve, clearFocus, popCard, leaveDetail, cancelConfirm,
         clearMarks, clearText, closeDetail, clearSelection, closePage, leaveModule, close
}

/// What a keystroke means; the panel performs it.
enum KeyIntent: Equatable {
    /// ⌘1–9.
    case module(PanelModule)
    /// ↑/↓ moved the highlight; nil hands ↵ back to the field.
    case select(String?)
    /// ↵ in a module: the object's detail. Never a mutation.
    case openDetail(String)
    /// ↵ on a global row: Home's and search's PRs open their PRs detail,
    /// palette rows keep their own ↵.
    case activate(String)
    /// ⌘↵: the object's page in the real browser (D7).
    case openInBrowser(String)
    case toggleInspector
    /// ⌘R on a failed run's open detail in CI: Re-run failed, after the run
    /// is read again (WP6). The one CI mutation.
    case rerunFailed(String)
    /// ⌫ on an empty filter removes the scope.
    case widenScope
    case escape(EscStep)
    /// ↵ (or its ⌘/⌥/⇧ chord) on the path card.
    case runPathVerb
    case cyclePathVerb(Int)
    /// ⇥ on a global, PRs or Sessions row: resolved ↔ unresolved.
    case triage(String)
    /// ⇥ completes the first slash verb or mode.
    case complete
    case createNote
    /// ⌘V: the panel splices multi-line text or lets the field paste.
    case paste
    case copyNote(String)
    /// A key typed into an entered module's empty filter: the tail of its
    /// `.x` token (`i` after `.c`) or the space that ends it is swallowed.
    case swallowToken(String)
    /// ⇥ / ⇧⇥ in a detail: the next target on its top layer (D3).
    case focus(Int)
    /// ↵ on the focused target: a run badge pushes its card.
    case activateFocus
    /// The top card's keys (D11): ↑/↓ in its column, ⇥ between columns, ↵
    /// narrows the next column. Never a mutation.
    case cardMove(Int)
    case cardColumn(Int)
    case cardOpen
    /// ⇧↑ (−1) / ⇧↓ (+1): the cursor moves and marks the rows it passes (bulk D1).
    case extendMarks(Int)
    /// ⌘A in a list with bulk verbs: every markable row shown.
    case markAll
    /// ←/→ inside an entered workbench: the next tab, wrapping (PR workbench D5).
    case tab(Int)
    /// ⇥ (+1) / ⇧⇥ (−1) in a module with views: its next view, wrapping (vt-7727 D5).
    case view(Int)
    /// ↑/↓ inside an entered workbench scroll its tab.
    case scroll(ScrollAmount)
    /// A letter inside an entered workbench: its verb. The workbench
    /// confirms what mutates; a letter never merges on its own.
    case verb(String)
    /// ⌘K on a workbench: every verb with its key.
    case verbMenu
    /// ⌥Z on a code canvas: long lines wrap ↔ run past the edge (D9).
    case toggleWrap
    /// ⌘C with code selected on the canvas.
    case copyCode
    /// ⌘↵ in an open workbench composer.
    case submitComposer
    /// ⌘B beside a code canvas: the side column (tree, search, references) folds.
    case toggleSideColumn
    /// ⌘⇧F beside a code canvas: the side column's code search (D3).
    case codeSearch
    /// F12 / ⇧F12 on the canvas's word: its definition, or its references (D2).
    case codeNavigation(references: Bool)
    /// Consumed, nothing to do: ⇥ on a row with nothing to triage.
    case ignore
}

/// The panel's key routing (copilot shell WP3). One app-wide monitor
/// (`PaletteKeyRouter`, claimed per summon) sees every keyDown before the
/// search field's editor does; `intent(for:in:)` is the routing table and
/// the panel performs what it returns.
enum KeyboardCoordinator {
    static func intent(for stroke: KeyStroke, in context: KeyContext) -> KeyIntent? {
        // A note editor or composer keeps its editing keys; Esc still peels
        // a layer, and ⌘↵ submits a composer.
        if context.composing, stroke.key == .enter, stroke.command { return .submitComposer }
        if context.textViewFocused, stroke.key != .esc { return nil }
        if context.verbConfirm, stroke.key != .esc {
            return stroke.key == .enter && !stroke.command ? .submitComposer : .ignore
        }
        let index = context.selection.flatMap { context.items.firstIndex(of: $0) }
        switch stroke.key {
        case let .character(key) where stroke.command:
            if let digit = Int(key), let module = PanelModule.numbered(digit, in: context.order) { return .module(module) }
            switch key {
            case "i": return context.module == nil ? nil : .toggleInspector
            case "r":
                if let card = context.card { return .rerunFailed("run:" + card) }
                guard context.module == .ci, context.detailOpen, let id = context.selection, id.hasPrefix("run:")
                else { return nil }
                return .rerunFailed(id)
            case "v": return context.fieldFocused ? .paste : nil
            // Inside a PR the list's marks are out of reach. A list without
            // bulk verbs leaves ⌘A to the field: select all.
            case "a": return context.entered ? .ignore : context.markable.isEmpty ? nil : .markAll
            case "c":
                if context.codeSelection { return .copyCode }
                guard !context.noteEditing, let id = context.selection, id.hasPrefix("note:") else { return nil }
                return .copyNote(id)
            case "k":
                let workbench = context.module.map(ModuleRouter.workbenches.contains) ?? false
                return workbench && context.detailOpen && context.card == nil ? .verbMenu : nil
            case "b": return context.codeShown ? .toggleSideColumn : nil
            case "f": return context.codeShown && stroke.shift ? .codeSearch : nil
            default: return nil
            }
        case let .character(key) where stroke.option:
            return key == "z" && context.codeShown ? .toggleWrap : nil
        // Inside a PR letters are its verbs and never refilter the list
        // under it (D5); space pages. A letter with no verb is swallowed.
        case let .character(key) where context.entered && context.fieldFocused:
            if key == " " { return .scroll(.page(stroke.shift ? -1 : 1)) }
            return context.verbKeys.contains(key) ? .verb(key) : .ignore
        case let .character(key):
            // `.ho` lands on Home, which is no entered module: its `me` is still swallowed.
            guard context.fieldFocused, context.module != nil || !context.pendingToken.isEmpty, context.text.isEmpty
            else { return nil }
            let tail = context.pendingToken.first.map { key.lowercased() == String($0) } ?? false
            return tail || key == " " ? .swallowToken(key) : nil
        case .left where context.entered && context.card == nil, .right where context.entered && context.card == nil:
            return .tab(stroke.key == .right ? 1 : -1)
        case .left, .right:
            // An empty field has no caret to move: ←/→ walk the strip, wrapping.
            // With text (or a picker, path card or page up) they stay the field's.
            guard context.fieldFocused, context.text.isEmpty, !stroke.command, !stroke.shift,
                  !context.pathCard, !context.completion, !context.page, !context.eve, !context.noteEditing
            else { return nil }
            return .module((context.module ?? .home).neighbour(stroke.key == .right ? 1 : -1, in: context.order))
        case .down where context.card != nil:
            return .cardMove(1)
        case .up where context.card != nil:
            return .cardMove(-1)
        case .down where context.entered, .up where context.entered:
            let sign = stroke.key == .down ? 1 : -1
            return .scroll(stroke.command ? .edge(sign) : stroke.shift ? .page(sign) : .step(sign))
        // ⇧ with an arrow marks as it moves; a list without bulk verbs keeps plain arrows.
        case .down where stroke.shift && !context.markable.isEmpty && !context.items.isEmpty:
            return .extendMarks(1)
        case .up where stroke.shift && !context.markable.isEmpty && !context.items.isEmpty:
            return .extendMarks(-1)
        case .down:
            guard !context.items.isEmpty else { return nil }
            return .select(context.items[index.map { min($0 + 1, context.items.count - 1) } ?? 0])
        case .up:
            // Past the top the field takes ↵ back.
            guard let index else { return nil }
            return .select(index == 0 ? nil : context.items[index - 1])
        case .tab:
            if context.card != nil { return .cardColumn(stroke.shift ? -1 : 1) }
            if context.detailOpen || context.bulk, !context.focusTargets.isEmpty { return .focus(stroke.shift ? -1 : 1) }
            // A module's views (D5): what ⇥ means in it once no detail ring
            // or card claims it; a view's rows have nothing to triage.
            if let module = context.module, !module.views.isEmpty, !context.entered {
                return .view(stroke.shift ? -1 : 1)
            }
            if context.pathCard, context.selection == nil { return .cyclePathVerb(stroke.shift ? -1 : 1) }
            if let id = context.selection {
                // A module's other rows have nothing to triage, and ⇥ must not
                // move focus out of the field.
                let triageable = context.module.map(triages) ?? true
                return triageable ? .triage(id) : .ignore
            }
            return context.completion ? .complete : nil
        case .enter:
            // ↵ belongs to a note edit (and ⌘↵ to its Save).
            if context.noteEditing { return nil }
            if !stroke.command, context.card != nil { return .cardOpen }
            if !stroke.command, context.detailOpen || context.bulk, context.focus != nil { return .activateFocus }
            // The bulk pane holds the detail's place: ↵ reaches for its first
            // verb, never a row's detail under it, and never runs a verb.
            if !stroke.command, context.bulk {
                return context.focusTargets.isEmpty ? .ignore : .focus(1)
            }
            // Inside a PR with nothing ringed ↵ has nothing to open.
            if !stroke.command, context.entered { return .ignore }
            if stroke.command, context.notesDraft { return .createNote }
            if context.pathCard, context.selection == nil { return .runPathVerb }
            if let index {
                let id = context.items[index]
                if stroke.command { return .openInBrowser(id) }
                return context.module == nil ? .activate(id) : .openDetail(id)
            }
            // A module with nothing highlighted opens its first object.
            if context.module != nil, !stroke.command, let first = context.items.first { return .openDetail(first) }
            return nil
        case .esc:
            return .escape(escape(context))
        case .f12:
            return context.codeShown ? .codeNavigation(references: stroke.shift) : nil
        case .backspace:
            // Inside a PR ⌫ would edit a filter the keys no longer reach.
            if context.entered { return .ignore }
            let widens = context.fieldFocused && context.module != nil && context.text.isEmpty && !stroke.command
            return widens ? .widenScope : nil
        }
    }

    /// Modules whose rows ⇥ triages (`ResolvedStore`: dimmed now, hidden on
    /// the next summon) — the lists that hide resolved ids, as before.
    static func triages(_ module: PanelModule) -> Bool {
        module == .prs || module == .sessions
    }

    /// The next layer Esc peels.
    static func escape(_ context: KeyContext) -> EscStep {
        if context.noteEditing { return .cancelNoteEdit }
        if context.composing || context.verbConfirm { return .closeComposer }
        // Another field (the tree's filter) gives the keys back to the search.
        if context.textViewFocused { return .blurText }
        if context.noteExpanded { return .foldNote }
        if context.eve { return .dismissEve }
        if context.focus != nil { return .clearFocus }
        if context.card != nil { return .popCard }
        if context.entered { return .leaveDetail }
        // A confirm closes first; marks peel before the filter that may have narrowed them.
        if context.bulk, context.bulkConfirm { return .cancelConfirm }
        if context.bulk { return .clearMarks }
        if !context.text.isEmpty || context.pathCard { return .clearText }
        if context.detailOpen { return .closeDetail }
        if context.selection != nil { return .clearSelection }
        if context.page { return .closePage }
        if context.module != nil { return .leaveModule }
        return .close
    }
}

// The AppKit glue. `tools/test-foundation.sh` builds this file under SwiftPM
// (which defines SWIFT_PACKAGE) without the panel types it reaches.
#if !SWIFT_PACKAGE
extension KeyStroke {
    /// ⌘ chords read the physical key, so ⌘1–9 work on a Czech layout
    /// (whose top row types `+ěščřžýáí`); typed text reads what it types.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key: Key
        switch event.keyCode {
        case 125: key = .down
        case 126: key = .up
        // Plain ←/→ only: ⌥ and ⌃ arrows stay the field's and the system's.
        case 123 where !flags.contains(.option) && !flags.contains(.control),
             124 where !flags.contains(.option) && !flags.contains(.control):
            key = event.keyCode == 123 ? .left : .right
        case 36, 76: key = .enter
        case 111: key = .f12
        case 48: key = .tab
        case 53: key = .esc
        case 51: key = .backspace
        default:
            if command {
                guard let chord = Self.chordKeys[event.keyCode] else { return nil }
                key = .character(chord)
            } else if flags.contains(.option), let chord = Self.optionKeys[event.keyCode] {
                self.init(key: .character(chord), shift: flags.contains(.shift), option: true)
                return
            } else {
                guard let typed = event.characters, typed.count == 1,
                      !flags.contains(.control), !flags.contains(.option) else { return nil }
                key = .character(typed)
            }
        }
        self.init(key: key, command: command, shift: flags.contains(.shift))
    }

    /// ANSI key codes of the chords the panel owns.
    private static let chordKeys: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        34: "i", 9: "v", 8: "c", 15: "r", 0: "a", 40: "k", 11: "b", 3: "f",
    ]

    /// ANSI key codes of the ⌥ chords the panel owns (⌥Z: wrap).
    private static let optionKeys: [UInt16: String] = [6: "z"]
}

extension KeyboardCoordinator {
    /// Takes the app-wide monitor for this summon (`PaletteKeyRouter`'s
    /// claim/resign contract: the newest owner wins, a stale resign is a
    /// no-op). `context` is read per keystroke; `perform` returns false to
    /// let the event through to the field.
    @MainActor
    static func claim(_ token: UUID, context: @escaping () -> KeyContext,
                      perform: @escaping (KeyIntent, NSEvent) -> Bool)
    {
        PaletteKeyRouter.shared.claim(token) { event in
            handle(event, synthetic: false, context: context(), perform: perform)
        }
    }

    @MainActor
    static func resign(_ token: UUID) {
        PaletteKeyRouter.shared.resign(token)
    }

    /// One keyDown. The monitor is app-wide: Settings and other windows keep
    /// their keys, and a PanelDriver event is addressed to the panel by
    /// construction (`synthetic`).
    @MainActor
    static func handle(_ event: NSEvent, synthetic: Bool, context: KeyContext,
                       perform: (KeyIntent, NSEvent) -> Bool) -> NSEvent?
    {
        guard synthetic || NSApp.keyWindow is StatusPanel else { return event }
        guard let stroke = KeyStroke(event), let intent = intent(for: stroke, in: context) else { return event }
        return perform(intent, event) ? nil : event
    }
}
#endif
