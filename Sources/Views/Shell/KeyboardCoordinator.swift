import Foundation
#if !SWIFT_PACKAGE
import AppKit
#endif

/// A keystroke as the coordinator reads it — AppKit-free, so the routing
/// table is pinned in Foundation (`Tests/ModuleRouterTests.swift`).
struct KeyStroke: Equatable {
    enum Key: Equatable {
        case up, down, left, right, enter, tab, esc, backspace
        /// Typed text, or a ⌘ chord's key (`3`, `i`, `v`, `c`).
        case character(String)
    }

    let key: Key
    var command = false
    var shift = false
}

/// The panel as the keyboard sees it at the moment of a keystroke.
struct KeyContext {
    /// The search field owns the keys (or a debug-driver key addressed to it).
    var fieldFocused = true
    /// Another text view (a note editor) holds focus: it keeps its editing
    /// keys, never Esc.
    var textViewFocused = false
    var module: PanelModule?
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
}

/// One peel of Esc (copilot shell layered Esc): note edit → expanded note →
/// eve → the field's text (completion, path card, filter) → detail →
/// selection → page → module → Home → close. It never closes the panel
/// while a layer remains.
enum EscStep: String, Equatable {
    case cancelNoteEdit, foldNote, dismissEve, clearText, closeDetail, clearSelection, closePage, leaveModule, close
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
    /// Consumed, nothing to do: ⇥ on a row with nothing to triage.
    case ignore
}

/// The panel's key routing (copilot shell WP3). One app-wide monitor
/// (`PaletteKeyRouter`, claimed per summon) sees every keyDown before the
/// search field's editor does; `intent(for:in:)` is the routing table and
/// the panel performs what it returns.
enum KeyboardCoordinator {
    static func intent(for stroke: KeyStroke, in context: KeyContext) -> KeyIntent? {
        // A note editor keeps its editing keys; Esc still peels a layer.
        if context.textViewFocused, stroke.key != .esc { return nil }
        let index = context.selection.flatMap { context.items.firstIndex(of: $0) }
        switch stroke.key {
        case let .character(key) where stroke.command:
            if let digit = Int(key), let module = PanelModule.numbered(digit) { return .module(module) }
            switch key {
            case "i": return context.module == nil ? nil : .toggleInspector
            case "r":
                guard context.module == .ci, context.detailOpen, let id = context.selection, id.hasPrefix("run:")
                else { return nil }
                return .rerunFailed(id)
            case "v": return context.fieldFocused ? .paste : nil
            case "c":
                guard !context.noteEditing, let id = context.selection, id.hasPrefix("note:") else { return nil }
                return .copyNote(id)
            default: return nil
            }
        case let .character(key):
            // `.ho` lands on Home, which is no entered module: its `me` is still swallowed.
            guard context.fieldFocused, context.module != nil || !context.pendingToken.isEmpty, context.text.isEmpty
            else { return nil }
            let tail = context.pendingToken.first.map { key.lowercased() == String($0) } ?? false
            return tail || key == " " ? .swallowToken(key) : nil
        case .left, .right:
            // An empty field has no caret to move: ←/→ walk the strip, wrapping.
            // With text (or a picker, path card or page up) they stay the field's.
            guard context.fieldFocused, context.text.isEmpty, !stroke.command, !stroke.shift,
                  !context.pathCard, !context.completion, !context.page, !context.eve, !context.noteEditing
            else { return nil }
            return .module((context.module ?? .home).neighbour(stroke.key == .right ? 1 : -1))
        case .down:
            guard !context.items.isEmpty else { return nil }
            return .select(context.items[index.map { min($0 + 1, context.items.count - 1) } ?? 0])
        case .up:
            // Past the top the field takes ↵ back.
            guard let index else { return nil }
            return .select(index == 0 ? nil : context.items[index - 1])
        case .tab:
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
        case .backspace:
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
        if context.noteExpanded { return .foldNote }
        if context.eve { return .dismissEve }
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
        case 123, 124 where !flags.contains(.option) && !flags.contains(.control):
            key = event.keyCode == 123 ? .left : .right
        case 36, 76: key = .enter
        case 48: key = .tab
        case 53: key = .esc
        case 51: key = .backspace
        default:
            if command {
                guard let chord = Self.chordKeys[event.keyCode] else { return nil }
                key = .character(chord)
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
        34: "i", 9: "v", 8: "c",
    ]
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
