import SwiftUI

/// A thin line over a series, 0…1 by default (vt-7727 D9: a machine's last
/// 24 h of CPU), in the `data` token with a faint fill under it. No axes:
/// the tile's caption names the span.
struct Sparkline: View {
    let values: [Double]
    var ceiling: Double = 1
    var height: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let value = min(max(values[index] / max(ceiling, .ulpOfOne), 0), 1)
                return CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(value) * (size.height - 2) - 1)
            }
            var line = Path()
            line.move(to: point(0))
            for index in values.indices.dropFirst() { line.addLine(to: point(index)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(Theme.data.opacity(0.12)))
            context.stroke(line, with: .color(Theme.data), lineWidth: 1.2)
        }
        .frame(height: height)
    }
}
