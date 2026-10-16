import SwiftUI

/// One cell per value, 0…1, in rows of `columns` (vt-7727 D9: a machine's
/// per-core load — 128 cores are 8 rows). The `heat` token deepens with the
/// value; an idle cell is the quiet track, so a busy core reads at a
/// glance. One Canvas: 128 cores are 128 rects, not 128 views.
struct Heatmap: View {
    let values: [Double]
    var columns = 16
    var cell: CGFloat = 10
    var gap: CGFloat = 2

    var body: some View {
        let rows = max(1, (values.count + columns - 1) / columns)
        let shown = min(columns, max(values.count, 1))
        Canvas { context, _ in
            for (index, value) in values.enumerated() {
                let rect = CGRect(x: CGFloat(index % columns) * (cell + gap),
                                  y: CGFloat(index / columns) * (cell + gap), width: cell, height: cell)
                let fill = value < 0.05 ? Theme.hairlineStrong : Theme.heat.opacity(0.25 + 0.75 * min(value, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
            }
        }
        .frame(width: CGFloat(shown) * (cell + gap) - gap, height: CGFloat(rows) * (cell + gap) - gap)
        .accessibilityLabel("\(values.count) cores, \(values.filter { $0 >= 0.8 }.count) busy")
    }
}
