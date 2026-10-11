import Foundation
import Observation

/// Where the panel is (copilot shell D5, D9): the entered module and its
/// filter, the selected object, and whether its detail and the ⌘I inspector
/// are open. The search is global until a module is entered — Home while
/// nothing is typed, results once something is — then it becomes the
/// module's scope chip and the field filters inside it; ⌫ on an empty field
/// widens back to global. Foundation-only: `Tests/ModuleRouterTests.swift`
/// drives it without a view.
///
/// Selection is always an object id, never an index, so a refresh that
/// re-ranks or re-filters a list never moves the cursor onto another row;
/// each module remembers its last selection for its next visit.
@MainActor
@Observable
final class ModuleRouter {
    /// What a change of the field's text means (`route(_:in:)`).
    enum Route: Equatable {
        /// It stays the global query, or the entered module's filter.
        case text(String)
        /// A `.x` alias: enter `module` with the rest as its filter. `rest`
        /// is the unread tail of the mode's name (`i` after `.c`); `opens`
        /// is the object the alias lands on with its detail (`.f`, Mac's fans).
        case enter(PanelModule, filter: String, rest: String, opens: String? = nil)
        /// `.` or `/` typed into a module: commands and palette pages are
        /// global, so the scope drops and the text goes with it.
        case global(String)
    }

    /// The entered module; nil while the search is global. Home is the
    /// global search at rest, never an entered scope.
    private(set) var module: PanelModule?
    /// The field: the global query, or the entered module's filter.
    private(set) var text = ""
    /// The highlighted object in the list on screen; nil = the field owns ↵.
    private(set) var selection: String?
    /// ↵ opened the selected object's detail (D4-B). Never a mutation.
    private(set) var detailOpen = false
    /// ⌘I: the detail's context sections move into a trailing inspector.
    private(set) var inspectorOpen = false
    /// The rest of a `.x` token's mode name: `.c` enters CI at once, so the
    /// `i` of `.ci` — and the space that ends the token — must not become
    /// CI's filter. The keyboard swallows them (`swallowTokenKey`).
    private(set) var pendingToken = ""
    private var remembered: [PanelModule: String] = [:]

    init() {}

    /// The dot grammar, pure: a `.x` alias enters its module from anywhere;
    /// inside a module a leading `.` or `/` returns to the global search.
    nonisolated static func route(_ text: String, in module: PanelModule?) -> Route {
        if let parsed = PaletteMode.parse(text), let target = parsed.mode.module {
            return .enter(target, filter: parsed.filter,
                          rest: parsed.filter.isEmpty ? String(parsed.mode.rawValue.dropFirst(parsed.token.count)) : "",
                          opens: parsed.mode.opens)
        }
        if module != nil, text.hasPrefix(".") || text.hasPrefix("/") { return .global(text) }
        return .text(text)
    }

    /// The field's text changed — typed, pasted, or set by a page or the
    /// debug driver; `.c failed` lands in CI with `failed`.
    func type(_ new: String) {
        switch Self.route(new, in: module) {
        case let .text(value):
            text = value
            pendingToken = ""
        case let .enter(target, filter, rest, opens):
            enter(target, filter: filter, select: opens, openDetail: opens != nil)
            pendingToken = rest
        case let .global(value):
            leave(keeping: value)
        }
    }

    /// Consumes the next character of the pending token (or the space that
    /// ends it) while the filter is still empty. False: it is filter text.
    func swallowTokenKey(_ character: String) -> Bool {
        // `.ho` lands on Home, which is no entered module, with `me` still to come.
        guard module != nil || !pendingToken.isEmpty, text.isEmpty else { return false }
        if let next = pendingToken.first, character.lowercased() == String(next) {
            pendingToken.removeFirst()
            return true
        }
        pendingToken = ""
        return character == " "
    }

    /// Enters `target` (⌘1–9, a strip click, a `.x` alias, a page link).
    /// Home is the global search at rest, so entering it leaves instead.
    func enter(_ target: PanelModule, filter: String = "", select id: String? = nil, openDetail: Bool = false) {
        guard target != .home else {
            leave()
            return
        }
        remember()
        module = target
        text = filter
        pendingToken = ""
        selection = id ?? remembered[target]
        detailOpen = openDetail && selection != nil
    }

    /// Back to the global search — Home once nothing is typed.
    func leave(keeping text: String = "") {
        remember()
        module = nil
        self.text = text
        pendingToken = ""
        selection = nil
        detailOpen = false
    }

    /// Moves the highlight; nil hands ↵ back to the field and closes the detail.
    func select(_ id: String?) {
        selection = id
        if id == nil { detailOpen = false }
    }

    func openDetail(_ id: String) {
        selection = id
        detailOpen = true
    }

    func closeDetail() {
        detailOpen = false
    }

    func toggleInspector() {
        inspectorOpen.toggle()
    }

    /// A fresh summon opens on Home. Remembered selections and the inspector
    /// are the operator's own state and survive.
    func reset() {
        leave()
    }

    private func remember() {
        guard let module else { return }
        remembered[module] = selection
    }
}
