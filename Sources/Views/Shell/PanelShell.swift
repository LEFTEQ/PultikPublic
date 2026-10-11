import SwiftUI

/// The panel's one fixed frame (copilot shell WP3): the top bar — the search
/// with the entered module's scope chip (none on Home) and the status strip
/// that is the switcher — then the body on the opaque content sheet, then
/// the footer. The frame is `PanelMetrics.panelSize` and content never
/// resizes it; the measured chrome feeds the body's height budget only.
struct PanelShell<Field: View, Content: View, Footer: View>: View {
    /// The strip's lift: the entered module, Home at rest, none on results.
    let current: PanelModule?
    let scope: SearchScope?
    let signals: [PanelModule: ModuleSignal]
    var chatting = false
    var showsHints = true
    let onSelectModule: (PanelModule) -> Void
    @Binding var topBarHeight: CGFloat
    @Binding var footerHeight: CGFloat
    @ViewBuilder var field: () -> Field
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                SearchField(scope: scope,
                            leadingSymbol: chatting ? "sparkles" : "magnifyingglass",
                            leadingTone: chatting ? Theme.eve : Theme.ink3,
                            showsHints: showsHints) {
                    field()
                }
            } strip: {
                ModuleStrip(current: current, signals: signals, onSelect: onSelectModule)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TopBarHeightKey.self, value: proxy.size.height)
                }
            )
            content()
                .frame(maxHeight: .infinity, alignment: .top)
                // The content layer (D11): one opaque near-black sheet inset in
                // the window glass, its corners concentric with the panel's.
                .background(Theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
                .padding(.horizontal, Theme.sheetInset)
            footer()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FooterHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // One fixed frame (D4): the window takes this size and content never
        // resizes it.
        .frame(width: PanelMetrics.shared.panelSize.width, height: PanelMetrics.shared.panelSize.height)
        .onPreferenceChange(FooterHeightKey.self) { value in
            let rounded = value.rounded()
            if abs(rounded - footerHeight) >= 1 { footerHeight = rounded }
        }
        .onPreferenceChange(TopBarHeightKey.self) { value in
            let rounded = value.rounded(.up)
            if abs(rounded - topBarHeight) >= 1 { topBarHeight = rounded }
        }
        .modifier(PanelChrome())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the footer strip — measured rather than hard-coded so the column
/// budget stays right if the chrome ever grows a line.
struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A rail column that scrolls inside a height budget instead of growing.
///
/// The panel body is `.fixedSize(vertical:)` — SwiftUI proposes nil height all
/// the way down, and a `ScrollView` handed a nil proposal reports its content's
/// full height and never scrolls. (`.frame(maxHeight:)` doesn't fix it: with no
/// finite proposal there is nothing for it to clamp against.) So the content is
/// measured and the scroller given a DEFINITE height: its content's, capped at
/// `maxHeight`. Short rails still size to their content — only a rail that
/// would overrun the screen becomes a scroller.
///
/// Internal, not fileprivate: any view file that caps a column has to obey the
/// same rule. A second copy would drift into the rigid `.frame(height:)` this
/// replaced.
struct ScrollColumn<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // Content that fits must neither rubber-band nor scroll.
        .scrollBounceBehavior(.basedOnSize)
        // Quantised for the same reason as the centre column: every write
        // re-renders the panel AND resizes the window, which re-pins it.
        // Rounded UP: half a point short would leave fitting content scrollable.
        .onPreferenceChange(ContentHeightKey.self) { value in
            let rounded = value.rounded(.up)
            if abs(rounded - measured) >= 1 { measured = rounded }
        }
        // Before the first measurement lands there is nothing to cap against —
        // stay unconstrained for that one pass rather than flashing a 1pt
        // column. The window's own clamp keeps even that frame on-screen.
        .frame(height: measured > 0 ? min(measured, maxHeight) : nil)
    }
}

/// The window glass (D11, DESIGN.md §1): one Liquid Glass shape tinted toward
/// the canvas, so a red or busy wallpaper never tints the chrome and red stays
/// an accent. Always dark, and the root tint keeps system blue out of every
/// control.
struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        GlassEffectContainer {
            content
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                .glassEffect(.regular.tint(Theme.canvas.opacity(0.78)),
                             in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// The top bar's measured height, subtracted from the column budget.
struct TopBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
