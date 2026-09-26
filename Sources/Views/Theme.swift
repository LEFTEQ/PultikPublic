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

/// A capsule count on a rail row's trailing edge — open questions, open
/// items, a held lease. Tone is the caller's; the shape is shared.
struct RailBadge: Identifiable {
    let text: String
    let tone: Color
    var help: String = ""
    var id: String { text + help }
}

/// THE row of the left column (2026-09-14): one grammar for a task, a
/// listener, a board and a devbox workspace, so the column reads as one list
/// rather than three apps. Dot · title · trailing meta, an optional second
/// line in mono, badges at the edge; hover lifts the row onto the same slab
/// every rail row in the panel uses. Devbox cards extend it with their
/// disclosure and verbs but keep these metrics (`RailRowMetrics`).
struct RailRow: View {
    enum Dot {
        case filled(Color)
        case hollow
    }

    let dot: Dot
    let title: String
    /// Second line — project · reason, activity, "last seen". Mono, tertiary.
    var subtitle: String? = nil
    var subtitleTone: Color? = nil
    /// Trailing text on the title line — a project, an age. Mono, tertiary.
    var meta: String? = nil
    var badges: [RailBadge] = []
    var help: String = ""
    var accessibilityLabel: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RailRowMetrics.dotGap) {
            dotView
                .frame(width: RailRowMetrics.dotSize, height: RailRowMetrics.dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(RailRowMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(RailRowMetrics.metaFont)
                        .foregroundStyle(subtitleTone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if let meta {
                Text(meta)
                    .font(RailRowMetrics.metaFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ForEach(badges) { badge in
                Text(badge.text)
                    .font(RailRowMetrics.metaFont)
                    .monospacedDigit()
                    .foregroundStyle(badge.tone)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(badge.tone.opacity(0.12), in: Capsule())
                    .help(badge.help)
            }
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, RailRowMetrics.verticalInset)
        .background(hovering ? RailRowMetrics.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: RailRowMetrics.radius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel ?? [title, subtitle, meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var dotView: some View {
        switch dot {
        case let .filled(tone): Circle().fill(tone)
        case .hollow: Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
        }
    }
}

/// The numbers behind `RailRow`, shared with the devbox card so a workspace
/// line and a board line sit on the same grid.
enum RailRowMetrics {
    static let titleFont = Font.system(size: 10.5)
    static let metaFont = Font.system(size: 9, design: .monospaced)
    static let dotSize: CGFloat = 6
    static let dotGap: CGFloat = 6
    static let inset: CGFloat = 8
    static let verticalInset: CGFloat = 4
    static let radius: CGFloat = 6
    static let hoverFill = Color.primary.opacity(0.06)
    /// Content under a row's title (a card's detail) starts under the title,
    /// not under the dot.
    static let indent: CGFloat = dotSize + dotGap
}

/// A rail.s quiet aside — "no session is listening", "no match", "+3 more" —
/// in the row meta voice and on the row grid.
struct RailNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(RailRowMetrics.metaFont)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.vertical, 2)
    }
}

/// The rail-flavoured search field: magnifier + plain text on a soft slab,
/// the same slab the rail rows hover onto (RailViews). `.roundedBorder` was
/// the second Aqua control in the left column.
struct RailSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
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
