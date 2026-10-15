import SwiftUI

struct MenuBarIconView: View {
    let state: AggregateState

    var body: some View {
        Image(nsImage: Self.render(state))
    }

    /// - Parameters:
    ///   - prodDots: the prod health strip, one dot per deployment in board
    ///     order (decision log D9 L0); empty until Hlídač has answered once.
    ///   - pulseOn: the phase of an unseen red dot's pulse.
    ///   - dark: the menu bar's own appearance — a coloured (non-template)
    ///     image resolves `.primary` at render time, not at display time.
    @MainActor
    static func render(_ state: AggregateState, todoCount: Int = 0,
                       alertCount: Int = 0, alertCritical: Bool = false, awake: Bool = false,
                       prodDots: [ProdGlance.Dot] = [], pulseOn: Bool = true, dark: Bool = false) -> NSImage {
        let symbol: String
        let color: Color
        let count: Int
        switch state {
        case .allClear:
            symbol = "checkmark.circle"
            color = .primary
            count = 0
        case .running(let n):
            symbol = "clock.arrow.circlepath"
            color = .orange
            count = n
        case .failed(let n):
            symbol = "xmark.circle.fill"
            color = .red
            count = n
        }

        let content = HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            // Prod health: one dot per deployment, right after the CI glyph
            // so the strip reads as part of the icon. An unseen red pulses
            // until a panel open marks it seen.
            if !prodDots.isEmpty {
                HStack(spacing: 2.5) {
                    ForEach(prodDots) { dot in
                        ProdDot(tone: dot.tone, dimmed: dot.pulsing && !pulseOn)
                    }
                }
                .padding(.leading, 2)
            }
            // Open todos ride along as a second glyph+count; the state colors
            // above stay reserved for CI, so the badge is always monochrome.
            if todoCount > 0 {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state == .allClear ? color : .primary)
                    .padding(.leading, 2)
                Text("\(todoCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(state == .allClear ? color : .primary)
            }
            // Unread eve alerts: a bell alongside the todos, monochrome like
            // them — except an unread CRITICAL, which is allowed to borrow red.
            if alertCount > 0 {
                Image(systemName: alertCritical ? "bell.badge.fill" : "bell")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(alertCritical ? AnyShapeStyle(Color.red)
                        : state == .allClear ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
                    .padding(.leading, 2)
                Text("\(alertCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(alertCritical ? AnyShapeStyle(Color.red)
                        : state == .allClear ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
            }
            // Never Sleep: a cup after everything else, monochrome and
            // countless — the lowest-precedence state on the icon
            // (spec 2026-09-10 decision 6).
            if awake {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state == .allClear ? color : .primary)
                    .padding(.leading, 2)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 1)
        .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        // Template mode when all-clear so the glyph adapts to menu bar light/dark;
        // colored states must keep their color — including the critical bell
        // and the prod dots, whose colours template rendering would flatten.
        image.isTemplate = (state == .allClear && !alertCritical && prodDots.isEmpty)
        return image
    }
}

/// One prod health dot: filled green / orange / red; blind is a hollow grey
/// ring, unmonitored a hollow green one (Booking CZ until it moves, D15).
private struct ProdDot: View {
    let tone: ProdGlance.Tone
    let dimmed: Bool

    var body: some View {
        Group {
            switch tone {
            case .green: Circle().fill(Color(red: 0.196, green: 0.843, blue: 0.294))
            case .orange: Circle().fill(Color(red: 1, green: 0.624, blue: 0.039))
            case .red: Circle().fill(Color(red: 1, green: 0.271, blue: 0.227)).opacity(dimmed ? 0.3 : 1)
            case .blind: Circle().strokeBorder(Color.gray.opacity(0.8), lineWidth: 1)
            case .hollow: Circle().strokeBorder(Color(red: 0.196, green: 0.843, blue: 0.294).opacity(0.85),
                                                lineWidth: 1)
            }
        }
        .frame(width: 5, height: 5)
    }
}
