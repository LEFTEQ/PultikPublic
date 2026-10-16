import SwiftUI

/// Draws `GFMBlock`s with the Kit's tokens (stay in Pultík D8): links in
/// `ink`, underlined, never the system blue; code in a `canvasDeep` well;
/// GitHub alerts as a tinted rule. Links open through the panel's
/// `openURL`, so `pultik://` references stay inside Pultík.
struct GFMBlockView: View {
    let block: GFMBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(Self.styled(text))
                .font(level <= 1 ? .system(size: 17, weight: .semibold) : level == 2 ? .system(size: 15, weight: .semibold)
                    : Theme.Typo.title)
                .foregroundStyle(Theme.ink)
                .padding(.top, level <= 2 ? 4 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(text):
            Text(Self.styled(text))
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .quote(blocks):
            GFMStack(blocks: blocks)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hairlineStrong).frame(width: 2) }
                .foregroundStyle(Theme.ink2)
        case let .alert(kind, blocks):
            VStack(alignment: .leading, spacing: 6) {
                Label(kind.rawValue.capitalized, systemImage: Self.symbol(kind))
                    .font(Theme.Typo.title)
                    .foregroundStyle(Self.tone(kind))
                GFMStack(blocks: blocks)
            }
            .padding(.leading, 10)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(Self.tone(kind)).frame(width: 2) }
        case let .code(language, code):
            VStack(alignment: .leading, spacing: 4) {
                if let language { Text(language).microLabel() }
                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(Theme.Typo.code)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
                .scrollIndicators(.never)
                .background(Theme.canvasDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Theme.ok : Theme.ink3)
                            } else {
                                Text(verbatim: ordered ? "\(start + index)." : "•").foregroundStyle(Theme.ink3)
                            }
                        }
                        .font(Theme.Typo.body)
                        .frame(minWidth: 14, alignment: .trailing)
                        GFMStack(blocks: item.blocks, spacing: 4)
                    }
                }
            }
        case let .table(table):
            GFMTableView(table: table)
        case let .image(url, alt):
            GFMImage(url: url, alt: alt)
        case let .details(summary, blocks):
            GFMDetails(summary: summary, blocks: blocks)
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 2)
        }
    }

    /// Links in `ink`, underlined (DESIGN.md §9: never system blue).
    static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link != nil {
            text[run.range].foregroundColor = Theme.ink
            text[run.range].underlineStyle = Text.LineStyle.single
        }
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = Theme.Typo.code
            text[run.range].backgroundColor = Theme.canvasDeep
        }
        return text
    }

    static func tone(_ alert: GFMAlert) -> Color {
        switch alert {
        case .note: Theme.data
        case .tip: Theme.ok
        case .important: Theme.eve
        case .warning: Theme.warn
        case .caution: Theme.danger
        }
    }

    static func symbol(_ alert: GFMAlert) -> String {
        switch alert {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }
}

/// Blocks stacked at the description's rhythm.
struct GFMStack: View {
    let blocks: [GFMBlock]
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in GFMBlockView(block: block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GFMTableView: View {
    let table: GFMTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        Text(GFMBlockView.styled(cell)).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                            .gridColumnAlignment(alignment(index))
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(GFMBlockView.styled(cell)).font(Theme.Typo.body).foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A remote image, at most 360 pt tall; its alt text when it does not load
/// (a private repo's attachment needs a browser session).
private struct GFMImage: View {
    let url: URL?
    let alt: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit().frame(maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            default:
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(Theme.ink3)
                    Text(alt.isEmpty ? "image" : alt).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                    LinkGlyph(url: url, label: "Open the image")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GFMDetails: View {
    let summary: AttributedString
    let blocks: [GFMBlock]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.16)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3).frame(width: 12)
                    Text(GFMBlockView.styled(summary)).font(Theme.Typo.body).foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { GFMStack(blocks: blocks).padding(.leading, 18) }
        }
    }
}
