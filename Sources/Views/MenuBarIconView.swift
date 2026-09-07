import SwiftUI

struct MenuBarIconView: View {
    let state: AggregateState

    var body: some View {
        Image(nsImage: Self.render(state))
    }

    @MainActor
    static func render(_ state: AggregateState, todoCount: Int = 0,
                       alertCount: Int = 0, alertCritical: Bool = false) -> NSImage {
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
        }
        .foregroundStyle(color)
        .padding(.horizontal, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        // Template mode when all-clear so the glyph adapts to menu bar light/dark;
        // colored states must keep their color — including the critical bell,
        // whose red would be flattened away by template rendering.
        image.isTemplate = (state == .allClear && !alertCritical)
        return image
    }
}
