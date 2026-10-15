import Foundation
import Observation

/// The selected theme, switched live. SwiftUI reads `theme` through
/// Observation; an AppKit surface registers with `observe(_:_:)` and repaints
/// in its handler. The store never persists: its owner saves the id.
@MainActor
@Observable
public final class CodeThemeStore {
    public private(set) var theme: CodeTheme
    /// What an absent or unknown id selects: the first of the owner's
    /// defaults this catalogue holds.
    public let defaultID: String
    public let catalog: ThemeCatalog

    @ObservationIgnored private var observers: [(owner: Weak, handler: @MainActor (CodeTheme) -> Void)] = []

    /// `selectedID` when the catalogue holds it, else the first of
    /// `defaultIDs` it holds, else its first theme. An id this build lacks (a
    /// hand edit, a newer build's theme, one a public build leaves out) is
    /// never an error.
    public init(selectedID: String?, defaultIDs: [String], catalog: ThemeCatalog = .shipped) {
        let fallback = defaultIDs.lazy.compactMap(catalog.theme(id:)).first ?? catalog.themes[0]
        defaultID = fallback.id
        self.catalog = catalog
        theme = selectedID.flatMap(catalog.theme(id:)) ?? fallback
    }

    /// Switches to `id` and tells every observer. Returns false — and changes
    /// nothing — for an unknown id or the theme already shown.
    @discardableResult
    public func select(_ id: String) -> Bool {
        guard id != theme.id, let next = catalog.theme(id: id) else { return false }
        theme = next
        observers.removeAll { $0.owner.object == nil }
        for observer in observers {
            observer.handler(next)
        }
        return true
    }

    /// Calls `handler` with each newly selected theme until `owner` is gone
    /// or calls `stopObserving`. It does not call it for the current theme.
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor (CodeTheme) -> Void) {
        observers.removeAll { $0.owner.object == nil || $0.owner.object === owner }
        observers.append((Weak(owner), handler))
    }

    public func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner.object == nil || $0.owner.object === owner }
    }

    private struct Weak {
        weak var object: AnyObject?

        init(_ object: AnyObject) {
            self.object = object
        }
    }
}
