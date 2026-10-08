import SwiftUI

/// The whole Mac's memory as one square: a tile per process family sized by
/// its footprint (`Treemap.squarify`), filled by the worst finding among its
/// processes — red, amber, a faint blue for info, neutral gray when healthy.
/// Labels shrink with the tile — "name ×count · size", then two lines, then
/// the name alone, then nothing; the hover always carries the full reading.
struct MacHealthTreemap: View {
    let families: [MacHealth.Family]
    let side: CGFloat

    /// The gap between tiles, so neighbours of one color stay two tiles.
    private static let gap: CGFloat = 1.5

    var body: some View {
        let rects = Treemap.squarify(families.map(\.memMb), in: CGRect(x: 0, y: 0, width: side, height: side))
        ZStack(alignment: .topLeading) {
            ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                let rect = rects[index]
                if rect.width > 0, rect.height > 0 {
                    MacHealthTile(family: family, size: CGSize(width: max(0, rect.width - Self.gap),
                                                               height: max(0, rect.height - Self.gap)))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }
}

private struct MacHealthTile: View {
    let family: MacHealth.Family
    let size: CGSize
    @State private var hovering = false

    private var fill: Color {
        switch family.health {
        case .red: .red.opacity(0.5)
        case .amber: .orange.opacity(0.32)
        case .info: .blue.opacity(0.22)
        case .ok: .primary.opacity(0.09)
        }
    }

    private var name: String {
        family.count > 1 ? "\(family.name) ×\(family.count)" : family.name
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 2.5)
                .strokeBorder(.white.opacity(hovering ? 0.35 : 0), lineWidth: 1))
            .overlay(alignment: .topLeading) { label }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
    }

    @ViewBuilder
    private var label: some View {
        if size.width >= 34, size.height >= 15 {
            let memory = MacHealthFormat.memory(mb: family.memMb)
            Group {
                if size.height >= 30 {
                    ViewThatFits(in: .horizontal) {
                        text(MacHealthFormat.tile(family))
                        VStack(alignment: .leading, spacing: 0) {
                            text(name)
                            text(memory, secondary: true)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            text(family.name, fixed: false)
                            // A clipped size reads worse than none: the hover has it.
                            ViewThatFits(in: .horizontal) {
                                text(memory, secondary: true)
                                Color.clear.frame(width: 0, height: 0)
                            }
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        text(MacHealthFormat.tile(family))
                        text(name)
                        text(family.name, fixed: false)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
    }

    /// `fixed` keeps a candidate at its natural width so `ViewThatFits` can
    /// reject it; the last resort is the one allowed to truncate.
    @ViewBuilder
    private func text(_ string: String, secondary: Bool = false, fixed: Bool = true) -> some View {
        let label = Text(string)
            .font(.system(size: 9, weight: secondary ? .regular : .medium, design: .monospaced))
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
        if fixed {
            label.fixedSize()
        } else {
            label.truncationMode(.middle)
        }
    }

    private var help: String {
        var parts = [name, MacHealthFormat.memory(mb: family.memMb), MacHealthFormat.cpu(family.cpuPct)]
        if family.flagged > 0 { parts.append("\(family.flagged) flagged") }
        return parts.joined(separator: " · ")
    }
}
