import SwiftUI

extension View {
    /// The scroller of a workbench tab (PR workbench D5): while `active` —
    /// the shown tab of the entered detail — it applies each ↑/↓ the keys
    /// ask for (`ModuleRouter.scrollRequest`) once.
    func workbenchScroll(active: Bool) -> some View {
        modifier(WorkbenchScroll(active: active))
    }
}

private struct WorkbenchScroll: ViewModifier {
    let active: Bool
    @Environment(ModuleRouter.self) private var router
    /// False while the workbench is staged off screen (focus D23).
    @Environment(\.bodyShown) private var onScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .top)
    /// Written on every scrolled frame, so it must not redraw the tab.
    @State private var tracker = Tracker()

    /// One ↑/↓: about three lines of body text.
    static let step: CGFloat = 56

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                tracker.geometry = geometry
            }
            // Heard on screen only: ↑/↓ re-runs no scroller of a staged workbench.
            .onChange(of: Heard(onScreen, router.scrollRequest)) { old, heard in
                guard active, let request = heard.taken(after: old), let geometry = tracker.geometry else { return }
                let y = Self.target(request.amount, geometry)
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.14)) { position.scrollTo(y: y) }
            }
    }

    static func target(_ amount: ScrollAmount, _ geometry: ScrollGeometry) -> CGFloat {
        let bottom = max(0, geometry.contentSize.height - geometry.containerSize.height)
        let y = geometry.contentOffset.y
        let next = switch amount {
        case let .step(sign): y + CGFloat(sign) * step
        case let .page(sign): y + CGFloat(sign) * max(step, geometry.containerSize.height - 48)
        case let .edge(sign): sign > 0 ? bottom : 0
        }
        return min(max(0, next), bottom)
    }

    private final class Tracker {
        var geometry: ScrollGeometry?
    }
}
