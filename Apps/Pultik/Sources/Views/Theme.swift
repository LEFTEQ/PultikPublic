import AppKit
import SwiftUI

/// The D11 tokens (copilot shell, 2026-10-08): Apple's macOS 26 language,
/// vitrinka's palette, Switcheroo's density. `DESIGN.md` beside this file is
/// the reference — one meaning per colour; views consume these and never
/// retype a literal.
enum Theme {
    // Content layer
    static let canvas = Color(hex: 0x141213)
    static let canvasDeep = Color(hex: 0x0F0E0F)
    static let surface = Color(hex: 0x1D1A1B)
    static let surfaceRaised = Color(hex: 0x252122)
    static let hairline = Color(hex: 0x292526)
    static let hairlineStrong = Color(hex: 0x363132)
    // Text
    static let ink = Color(hex: 0xF0EAE4)
    static let ink2 = Color(hex: 0xA8A099)
    static let ink3 = Color(hex: 0x8C857F)
    // Selection edge, focus, primary action, brand — never a status.
    static let accent = Color(hex: 0xFF3B57)
    static let accentSoft = accent.opacity(0.12)
    /// The selected row's neutral lift (vitrinka's sidebar grey).
    static let selection = Color.white.opacity(0.085)
    // Status
    static let ok = Color(hex: 0x53C07E)
    static let warn = Color(hex: 0xF5B83D)
    static let danger = Color(hex: 0xFF6369)
    static let idle = ink3
    /// Eve and agent identity: glyphs and the eve chip only.
    static let eve = Color(hex: 0xBF5AF2)
    static let eveSoft = eve.opacity(0.12)
    // Charts
    static let data = Color(hex: 0xD6C7B6)
    static let dataMuted = Color(hex: 0x6B625B)
    static let heat = Color(hex: 0xE8703A)

    static let panelRadius: CGFloat = 26
    /// The content sheet's inset inside the window glass.
    static let sheetInset: CGFloat = 8

    /// Type scale (DESIGN.md §3). Not `Type`: `Theme.Type` is the metatype.
    enum Typo {
        static let hero = Font.system(size: 44, weight: .bold, design: .rounded).monospacedDigit()
        static let heroUnit = Font.title3.weight(.medium)
        static let stat = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
        static let statCompact = Font.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()
        static let detailTitle = Font.system(size: 20, weight: .semibold)
        static let title = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let meta = Font.system(size: 11)
        /// Uppercase via `.microLabel()`, which also sets the tracking.
        static let micro = Font.system(size: 10, weight: .semibold, design: .monospaced)
        static let figure = Font.system(size: 12, design: .monospaced)
        static let code = Font.system(size: 11.5, design: .monospaced)
    }

    /// Corner radii (DESIGN.md §4): concentric, `inner = outer − inset`.
    enum Radius {
        static let sheet: CGFloat = 18
        static let tile: CGFloat = 14
        static let row: CGFloat = 8
        static let kbd: CGFloat = 4
    }

    /// Motion (stay in Pultík, DESIGN.md §10): every animated change takes a
    /// token, and each token degrades to a short crossfade under Reduce
    /// Motion — `Theme.Motion.status(reduce)`, never a raw curve in a view.
    /// Entering springs a little, leaving is faster and flat (asymmetric
    /// push and pop); status changes crossfade with a one-shot symbol effect.
    enum Motion {
        /// A badge, chip or dot changing state.
        static func status(_ reduce: Bool) -> Animation {
            reduce ? fade : .easeInOut(duration: 0.22)
        }

        /// A card sliding up over its detail.
        static func push(_ reduce: Bool) -> Animation {
            reduce ? fade : .spring(duration: 0.34, bounce: 0.12)
        }

        /// A card sliding away: shorter, no overshoot.
        static func pop(_ reduce: Bool) -> Animation {
            reduce ? fade : .spring(duration: 0.24, bounce: 0)
        }

        /// The ⇥ focus ring moving.
        static func focus(_ reduce: Bool) -> Animation {
            reduce ? fade : .snappy(duration: 0.14)
        }

        /// A module body swapping in after the strip's keys settle.
        static func swap(_ reduce: Bool) -> Animation {
            reduce ? fade : .snappy(duration: 0.18)
        }

        static let fade = Animation.easeInOut(duration: 0.15)

        /// A workbench tab (PR workbench WP7): it slides in its travel
        /// direction while the underline glides; a crossfade under Reduce Motion.
        static func tab(_ reduce: Bool) -> Animation {
            reduce ? fade : .spring(duration: 0.28, bounce: 0.06)
        }

        /// How far a tab travels as it leaves or arrives.
        static func tabShift(_ reduce: Bool) -> CGFloat {
            reduce ? 0 : 28
        }

        /// A disclosure opening or folding: a tree folder, resolved threads.
        static func disclosure(_ reduce: Bool) -> Animation {
            reduce ? fade : .snappy(duration: 0.18)
        }

        /// A verb's outcome: up from the bottom edge, out the same way.
        static func toast(_ reduce: Bool) -> AnyTransition {
            reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity)
        }

        /// The card's own entrance and exit: up from the bottom edge, out
        /// the same way; a crossfade under Reduce Motion.
        static func card(_ reduce: Bool) -> AnyTransition {
            reduce ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

extension Color {
    /// `0xRRGGBB` in sRGB — the form DESIGN.md writes tokens in.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// The numbers behind a tile — a Home tile or a glance — so both sit on one
/// rhythm (Switcheroo's `arcadeTile`: radius 16, 14pt padding, no stroke).
enum TileMetrics {
    static let radius: CGFloat = 16
    static let padding: CGFloat = 14
    /// Between tiles, and between a tile and the panel's edge.
    static let gap: CGFloat = 10
    static let fill = Color.white.opacity(0.055)
    static let titleFont = Font.system(size: 12, weight: .semibold)
    static let captionFont = Font.system(size: 10.5).monospacedDigit()
    /// The one big number a tile leads with.
    static let heroFont = Font.system(size: 28, weight: .bold, design: .rounded).monospacedDigit()
    static let heroUnitFont = Font.system(size: 11)
}

extension View {
    /// A tile: a quiet fill on the panel's glass. Not a second glass layer —
    /// glass on glass reads muddy, and the panel is already the one material.
    func tileSurface(padding: CGFloat = TileMetrics.padding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TileMetrics.fill,
                        in: RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
    }
}

/// A tile's heading row (Switcheroo's `ArcadeTileHeader`): the title, and a
/// quiet caption on the trailing edge. The title is a `Kicker`, so a tile
/// that opens a page keeps the same hit target and hover affordance.
struct TileHeader: View {
    let title: String
    var count: Int = 0
    var tone: Color = .secondary
    var caption: String?
    var captionTone: Color = .secondary
    var action: (() -> Void)?
    var actionRole: KickerActionRole = .button
    var actionHelp: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Kicker(text: title, count: count, tone: tone, action: action,
                   actionRole: actionRole, actionHelp: actionHelp)
            Spacer(minLength: 0)
            if let caption {
                Text(caption)
                    .font(TileMetrics.captionFont)
                    .foregroundStyle(captionTone)
                    .lineLimit(1)
            }
        }
    }
}

enum KickerActionRole {
    case button
    case link
}

/// The section title of the panel: sentence case, SF Pro semibold, primary
/// unless a tone says something needs you (D6, 2026-10-07 — the uppercase
/// mono micro-label retired).
struct Kicker: View {
    let text: String
    var count: Int = 0
    /// The count is a floor (a capped read): it draws `5+`.
    var countIsFloor = false
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(TileMetrics.titleFont)
                .foregroundStyle(titleTone)
                .lineLimit(1)
            if count > 0 {
                Text(verbatim: countIsFloor ? "\(count)+" : "\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(countTone.opacity(0.16), in: Capsule())
                    .foregroundStyle(countTone)
            }
            if let actionRole {
                Image(systemName: actionRole == .link ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 0.9 : 0.35)
            }
        }
    }

    /// A quiet title reads primary; an attention tone (orange, red) colours
    /// the title itself, the way the old kicker did.
    private var titleTone: Color { tone == .secondary ? .primary : tone }
    private var countTone: Color { tone == .secondary ? .secondary : tone }
}

/// A capsule count on a rail row's trailing edge — open questions, open
/// items, a held lease. Tone is the caller's; the shape is shared.
struct RailBadge: Identifiable {
    let text: String
    let tone: Color
    var help: String = ""
    var id: String { text + help }
}

/// THE row of the rails (2026-09-14; the left column it began in retired
/// with WP8): one grammar for a task, a
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
    /// The keyboard's selection in a module list: the Kit's neutral lift.
    var selected = false
    /// The row's object id where a bulk verb can take it (bulk D1): its dot
    /// gives way to the mark's check.
    var mark: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.rowMarks) private var marks

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RailRowMetrics.dotGap) {
            MarkSlot(id: mark ?? "", hovering: hovering, size: 9) { dotView }
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
        .background {
            if selected || mark.map(marks.marked.contains) == true {
                RowBackground(selected: selected, mark: mark)
            } else {
                RoundedRectangle(cornerRadius: RailRowMetrics.radius)
                    .fill(hovering ? RailRowMetrics.hoverFill : .clear)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel ?? [title, subtitle, meta].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
    static let titleFont = Font.system(size: 11)
    /// SF Pro with tabular digits (D6): numbers still line up, words read
    /// as words.
    static let metaFont = Font.system(size: 10).monospacedDigit()
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
/// an Aqua control on the rails' glass.
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
                .padding(.horizontal, RailRowMetrics.inset)
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
        // A Kit tile on the rows' own inset: a rail's rows keep their padding.
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .kitTile(padding: 0)
    }
}
