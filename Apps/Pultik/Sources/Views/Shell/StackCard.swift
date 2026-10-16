import SwiftUI

/// The detail stack (stay in Pultík D2): each card slides up over the
/// detail below it, which stays dimmed behind with its header and badges
/// peeking, so depth reads at a glance and every nested object — PR → run →
/// job — uses one grammar. Esc (or a click on the dimmed layer) slides the
/// top card away. The card takes the detail's full width.
struct StackedDetail<Base: View, Card: View>: View {
    let stack: [DetailRef]
    var onPop: () -> Void
    @ViewBuilder var base: () -> Base
    @ViewBuilder var card: (DetailRef) -> Card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The detail's header and its run badges stay visible above the card.
    static var peek: CGFloat { 92 }
    /// Each deeper card sits this much lower than the one beneath it.
    static var step: CGFloat { 14 }

    var body: some View {
        ZStack(alignment: .top) {
            base()
                .opacity(stack.isEmpty ? 1 : 0.42)
                .allowsHitTesting(stack.isEmpty)
                .overlay {
                    if !stack.isEmpty {
                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: onPop)
                            .accessibilityLabel("Close the card")
                    }
                }
            ForEach(Array(stack.enumerated()), id: \.element) { index, ref in
                let top = index == stack.count - 1
                card(ref)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.canvas, in: UnevenRoundedRectangle(
                        topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet, style: .continuous))
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet,
                                               style: .continuous)
                            .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 20, y: -6)
                    .padding(.top, Self.peek + CGFloat(index) * Self.step)
                    .opacity(top ? 1 : 0.55)
                    .allowsHitTesting(top)
                    .transition(Theme.Motion.card(reduceMotion))
                    .zIndex(Double(index + 1))
            }
        }
        .clipped()
    }
}

extension View {
    /// The ⇥ focus ring (D3): a 2 pt accent ring around the focused target —
    /// the accent is selection (DESIGN.md §2), never an error.
    func focusRing(_ focused: Bool, radius: CGFloat = Theme.Radius.row) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        }
    }
}
