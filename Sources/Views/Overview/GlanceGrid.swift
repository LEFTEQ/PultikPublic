import SwiftUI

/// The left column's one grid (panel Home D5, 2026-10-07). Every glance row
/// is a name and up to three value cells on the same tracks, so a number in
/// the Estate glance starts where the number in the Devbox glance above it
/// starts. A cell is its reading over a thin bar tinted by load; column
/// heads sit once per glance, over the tracks. Sized for the 300 pt column:
/// a 280 pt tile, 4 pt tile padding, the rows' own 8 pt inset.
enum GlanceGrid {
    static let name: CGFloat = 64
    static let cell: CGFloat = 56
    static let spacing: CGFloat = 8

    /// A glance's surface: the tile fill, padded so rows keep the hover slab
    /// they share with `RailRow` (`RailRowMetrics.inset`).
    static func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().glanceTile()
    }

    /// Calm reads green, warm orange, hot red — the bar's colour.
    static func barTone(_ fraction: Double) -> Color {
        switch LoadTier(percent: fraction * 100) {
        case .calm: .green
        case .warm: .orange
        case .hot: .red
        }
    }
}

/// One value on the grid. `fraction` draws the bar (and tints a warm or hot
/// reading); `tone` overrides the text's colour when the caller knows better
/// (memory by kernel pressure, a fan by its own range).
struct GlanceCell {
    var text: String
    var fraction: Double?
    var tick: Double?
    var tone: Color?
    /// The bar's colour when load-by-fraction would mislead (memory by
    /// kernel pressure).
    var barTone: Color?
    var help: String?
    /// A cell that opens something (a count opening its filtered page).
    var action: (() -> Void)?

    init(_ text: String, fraction: Double? = nil, tick: Double? = nil, tone: Color? = nil,
         barTone: Color? = nil, help: String? = nil, action: (() -> Void)? = nil) {
        self.action = action
        self.text = text
        self.fraction = fraction
        self.tick = tick
        self.tone = tone
        self.barTone = barTone
        self.help = help
    }
}

/// The column heads of one glance, over the value tracks.
struct GlanceHeads: View {
    let titles: [String]

    var body: some View {
        HStack(spacing: GlanceGrid.spacing) {
            Color.clear.frame(width: GlanceGrid.name, height: 1)
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .lineLimit(1)
                    .frame(width: GlanceGrid.cell, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, RailRowMetrics.inset)
        .accessibilityHidden(true)
    }
}

/// A name (and a quiet detail under it — "96 cores") and its cells.
struct GlanceRow: View {
    let name: String
    var detail: String?
    let cells: [GlanceCell]
    var help: String?

    var body: some View {
        HStack(alignment: .top, spacing: GlanceGrid.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .frame(width: GlanceGrid.name, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Group {
                    if let action = cell.action {
                        Button(action: action) { GlanceValue(cell: cell).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    } else {
                        GlanceValue(cell: cell)
                    }
                }
                .frame(width: GlanceGrid.cell, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RailRowMetrics.inset)
        .padding(.vertical, 2)
        .help(help ?? "")
    }
}

/// A reading over its bar.
struct GlanceValue: View {
    let cell: GlanceCell

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cell.text)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(textTone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let fraction = cell.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill((cell.barTone ?? GlanceGrid.barTone(fraction)).opacity(0.85))
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        if let tick = cell.tick {
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 1.5, height: 7)
                                .offset(x: proxy.size.width * min(max(tick, 0), 1) - 0.75)
                        }
                    }
                }
                .frame(height: 3)
            }
        }
        .help(cell.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.text)
    }

    private var textTone: Color {
        if let tone = cell.tone { return tone }
        guard let fraction = cell.fraction else { return .primary }
        return LoadTier(percent: fraction * 100) == .calm ? .primary : GlanceGrid.barTone(fraction)
    }
}

/// "215/251G", "1.5/1.7T" — `formatSize` without the space and the B, to
/// fit a grid cell.
func compactSize(used: Double, total: Double) -> String {
    formatSize(used: used, total: total)
        .replacingOccurrences(of: " GB", with: "G")
        .replacingOccurrences(of: " TB", with: "T")
}

extension View {
    /// `GlanceGrid.tile` as a modifier, for a glance that sizes itself.
    func glanceTile() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TileMetrics.fill,
                        in: RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
    }
}
