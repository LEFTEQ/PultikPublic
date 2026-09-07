import AppKit
import SwiftUI

/// Native dense dev-tool language (redesign 2026-07-22): flat dark surfaces,
/// hairlines, SF Symbols, monospaced numerics — Instruments/Xcode-organizer
/// density. The warm-ink vitrinka glass is retired; system semantic colors
/// carry state, the red accent survives only for brand moments (✦ eve, quick
/// commands).
enum Theme {
    static let accent = Color(red: 1.0, green: 0.231, blue: 0.341)          // #ff3b57
    static let accentSoft = accent.opacity(0.10)
    /// Eve's color — purple, matching the session chips.
    static let eve = Color(red: 0.749, green: 0.353, blue: 0.949)           // #bf5af2
    static let eveSoft = eve.opacity(0.12)
    static let hairline = Color.white.opacity(0.08)
    static let panelRadius: CGFloat = 14
}

enum KickerActionRole {
    case button
    case link
}

/// Mono uppercase micro-label — the section header of the dense panel.
struct Kicker: View {
    let text: String
    var count: Int = 0
    var tone: Color = .secondary
    var action: (() -> Void)?
    var actionRole: KickerActionRole = .button
    var actionHelp: String?
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) {
                label(actionRole: actionRole)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .onDisappear {
                if hovering { NSCursor.arrow.set() }
            }
            .help(actionHelp ?? "Open \(text) overview")
            .accessibilityRemoveTraits(actionRole == .link ? .isButton : [])
            .accessibilityAddTraits(actionRole == .link ? .isLink : [])
        } else {
            label(actionRole: nil)
        }
    }

    private func label(actionRole: KickerActionRole?) -> some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .kerning(1.2)
                .foregroundStyle(tone)
            if count > 0 {
                Text("\(count)")
                    .kerning(0)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tone.opacity(0.15), in: Capsule())
                    .foregroundStyle(tone)
            }
            if let actionRole {
                Image(systemName: actionRole == .link ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tone)
                    .opacity(hovering ? 0.8 : 0.28)
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
    }
}

/// A collapsible right-rail section (decision D11, 2026-08-27).
///
/// The right rail carries nine tenants since the vitals dock moved in, and
/// they do not fit at rest. Rather than truncating each one or guessing an
/// order, every section folds and remembers: `collapsedRails` in
/// `settings.json` outlives the launch, so the rail reopens the way you left
/// it. The header is the whole hit target; the chevron is only the affordance.
///
/// The vitals dock deliberately does NOT adopt this — it is the one thing that
/// must be readable without a decision having been made about it first.
struct RailSection<Content: View>: View {
    let key: String
    let title: String
    var count: Int = 0
    var tone: Color = .secondary
    /// Rendered at the header's trailing edge, inside the tap target — the
    /// devbox "as of" stamp is the case this exists for.
    var accessory: AnyView?
    @ViewBuilder let content: () -> Content

    private var store: StatusStore { StatusStore.shared }
    private var collapsed: Bool { store.isRailCollapsed(key) }
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    store.setRail(key, collapsed: !collapsed)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Kicker(text: title, count: count, tone: tone)
                    // Reserves its slot at all times: a chevron that appears on
                    // hover shifts the accessory sideways and makes the whole
                    // rail twitch as the pointer travels down it.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .opacity(hovering || collapsed ? 1 : 0)
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(collapsed ? "Show \(title)" : "Hide \(title)")
            .accessibilityLabel(title)
            .accessibilityValue(collapsed ? "collapsed" : "expanded")
            .accessibilityAddTraits(.isButton)

            if !collapsed { content() }
        }
        .padding(10)
    }
}
