import SwiftUI

// The small parts every module draws with (DESIGN.md §8). Each mirrors the
// mock kit's class of the same name; tokens come from `Theme`, never literals.

extension View {
    /// `micro`: uppercase monospaced micro-label, vitrinka's nav voice.
    func microLabel(_ tone: Color = Theme.ink3) -> some View {
        font(Theme.Typo.micro)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(tone)
            .lineLimit(1)
    }

    /// A control floating on the window glass (DESIGN.md §1): a vibrant fill,
    /// never a second glass, with a specular rim, an inner shadow along the
    /// lower edge and a soft drop shadow onto the content below.
    func vibrantControl<S: InsettableShape>(_ shape: S, fill: Double = 0.08, lifted: Bool = true) -> some View {
        background {
            shape.fill(Color.white.opacity(fill)
                .shadow(.inner(color: .black.opacity(0.3), radius: 2.5, y: -2)))
                .overlay(SpecularRim(shape: shape))
                .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 13, y: 10)
        }
    }

    /// A content tile: a quiet `surface` fill with a 1 pt top highlight —
    /// not glass and not a stroked box.
    func kitTile(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.tile) }
    }
}

/// The 1 pt light catching the top edge of a raised surface.
struct TopHighlight: View {
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                         startPoint: .top, endPoint: .center),
                          lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// The specular rim: bright at the top-leading edge, nearly gone across the
/// middle, a faint return at the bottom-trailing edge.
struct SpecularRim<S: InsettableShape>: View {
    let shape: S
    var body: some View {
        shape.strokeBorder(
            LinearGradient(stops: [
                .init(color: .white.opacity(0.55), location: 0),
                .init(color: .white.opacity(0.03), location: 0.5),
                .init(color: .white.opacity(0.16), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
        .allowsHitTesting(false)
    }
}

/// `⌘R`, `↵`, `⌘1` in micro type on a hairline border.
struct KbdHint: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.kbd).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .fixedSize()
    }
}

/// A 7 pt status dot. Colour is never the only signal: a ring is blind, a
/// pulse is alive, a spinner is running.
struct StatusDot: View {
    enum Style { case solid, ring, pulse, spin }
    let tone: Color
    var style: Style = .solid
    var size: CGFloat = 7
    /// Pulse and spin only on a displayed body of a presented panel: a hidden
    /// warm body's repeating effect re-renders the panel every frame (`animates`).
    @Environment(\.animates) private var animates

    var body: some View {
        switch style {
        case .solid:
            Circle().fill(tone).frame(width: size, height: size)
        case .ring:
            Circle().strokeBorder(tone, lineWidth: 1.5).frame(width: size, height: size)
        case .pulse:
            Image(systemName: "circle.fill")
                .font(.system(size: size))
                .foregroundStyle(tone)
                .symbolEffect(.pulse, options: .repeating, isActive: animates)
                .frame(width: size, height: size)
        case .spin:
            if animates {
                ProgressView().controlSize(.mini).tint(tone).frame(width: size + 3, height: size + 3)
            } else {
                Circle().trim(from: 0, to: 0.75).stroke(tone, lineWidth: 1.5)
                    .frame(width: size, height: size).frame(width: size + 3, height: size + 3)
            }
        }
    }
}

/// A 20 pt capsule (DESIGN.md §8 Chip). `failing` and `passing` are the
/// check chips: the failing check leads in danger with an ✗; passing checks
/// stay neutral with a 5 pt ok dot.
struct Chip: View {
    enum Variant { case neutral, ok, warn, danger, eve, dashed, selected, failing, passing }
    let text: String
    var variant: Variant = .neutral
    var symbol: String? = nil

    init(_ text: String, _ variant: Variant = .neutral, symbol: String? = nil) {
        self.text = text
        self.variant = variant
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            if variant == .passing {
                Circle().fill(Theme.ok).frame(width: 5, height: 5)
            } else if variant == .failing {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(Theme.Typo.meta).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(fill, in: Capsule())
        .overlay {
            switch variant {
            case .dashed:
                Capsule().strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            case .failing:
                Capsule().strokeBorder(Theme.danger.opacity(0.55), lineWidth: 1)
            default:
                EmptyView()
            }
        }
        .fixedSize()
    }

    private var tone: Color {
        switch variant {
        case .neutral, .passing, .dashed: Theme.ink2
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .danger, .failing: Theme.danger
        case .eve: Theme.eve
        case .selected: Theme.accent
        }
    }

    private var fill: Color {
        switch variant {
        case .neutral, .passing: Color.white.opacity(0.06)
        case .dashed: .clear
        case .selected: Theme.accentSoft
        case .failing: Theme.danger.opacity(0.14)
        default: tone.opacity(0.14)
        }
    }
}

/// A project's identity square: gradient fill, white symbol at half size.
/// The hue lives in the glyph only — never on text, dots or bars.
struct ProjectGlyph: View {
    let project: String
    var symbol: String = "square.grid.2x2.fill"
    var size: CGFloat = 20

    static func hue(_ project: String) -> Color {
        switch project.lowercased() {
        case let p where p.hasPrefix("exampleapp"): Color(hex: 0xE8703A)
        case let p where p.hasPrefix("eve"): Color(hex: 0xBF5AF2)
        case let p where p.hasPrefix("vitrinka"): Color(hex: 0xD84A62)
        case let p where p.hasPrefix("booking"): Color(hex: 0xBB8A33)
        case let p where p.hasPrefix("example"): Color(hex: 0x3AA06B)
        case let p where p.hasPrefix("pultik"): Color(hex: 0xA0705A)
        case let p where p.hasPrefix("toolkit"): Color(hex: 0xB5916B)
        case let p where p.hasPrefix("build-server"): Color(hex: 0x6B625B)
        case let p where p.hasPrefix("forge"): Color(hex: 0x8A7A3C)
        default: Color(hex: 0x6B625B)
        }
    }

    var body: some View {
        let hue = Self.hue(project)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [hue.opacity(0.95), hue.opacity(0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// A tile with its micro kicker and trailing caption (DESIGN.md §8 Tile).
struct Tile<Content: View>: View {
    var kicker: String?
    var caption: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kicker != nil || caption != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let kicker { Text(kicker).microLabel() }
                    Spacer(minLength: 8)
                    if let caption {
                        Text(caption).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
            }
            content()
        }
        .kitTile()
    }
}

/// The one number a tile leads with: micro label, 44 pt rounded figure and
/// unit, a delta line coloured only when it is a verdict.
struct HeroStat: View {
    var label: String?
    let value: String
    var unit: String?
    var delta: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).microLabel() }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(Theme.Typo.hero)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                if let unit {
                    Text(unit).font(Theme.Typo.heroUnit).foregroundStyle(Theme.ink2)
                }
            }
            if let delta { delta.font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2) }
        }
    }
}

/// 3–5 stat cells separated by hairlines.
struct StatStrip: View {
    struct Cell: Identifiable {
        let label: String
        let value: String
        var tone: Color = Theme.ink
        var caption: String?
        var id: String { label }
    }

    let cells: [Cell]
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if index > 0 {
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: compact ? 34 : 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.label).microLabel()
                    Text(cell.value)
                        .font(compact ? Theme.Typo.statCompact : Theme.Typo.stat)
                        .foregroundStyle(cell.tone)
                        .lineLimit(1)
                    if let caption = cell.caption, !compact {
                        Text(caption).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// A bare 4 pt meter for a dense row (vt-7727 D9: cpu · ram · disk per
/// machine): `MeterBar`'s track and thresholds without its label line. An
/// unknown value draws the empty track, never a zero.
struct MicroMeter: View {
    let fraction: Double?
    var width: CGFloat = 34

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.hairlineStrong)
            if let fraction {
                Capsule().fill(MeterBar.tone(fraction))
                    .frame(width: max(2, width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: width, height: 4)
        .accessibilityValue(fraction.map { PultikFormat.percent($0) } ?? "unknown")
    }
}

/// Label · value on one line over a 4 pt capsule track; the fill takes its
/// colour from the threshold (< 70 % ok, < 90 % warn, else danger).
struct MeterBar: View {
    let label: String
    let value: String
    let fraction: Double
    var floor: Double?

    static func tone(_ fraction: Double) -> Color {
        fraction < 0.7 ? Theme.ok : fraction < 0.9 ? Theme.warn : Theme.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The value never wraps under its label (`475/645 GB` at 1240 pt);
            // a tight cell truncates the label instead.
            HStack(alignment: .firstTextBaseline) {
                Text(label).microLabel().lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Self.tone(fraction))
                    .lineLimit(1).fixedSize().layoutPriority(1)
            }
            GeometryReader { proxy in
                let clamped = min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairlineStrong)
                    Capsule().fill(Self.tone(fraction)).frame(width: proxy.size.width * clamped)
                    if let floor {
                        Rectangle().fill(Theme.ink2).frame(width: 1, height: 6)
                            .offset(x: proxy.size.width * min(max(floor, 0), 1))
                    }
                }
            }
            .frame(height: 4)
        }
    }
}
