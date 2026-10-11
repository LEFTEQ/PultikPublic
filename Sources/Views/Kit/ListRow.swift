import SwiftUI

/// THE row of every module list (DESIGN.md §8 ListRow): glyph or dot · title
/// · a meta line led by the id · a trailing figure, time or chip. Hover lifts
/// onto `surfaceRaised`; selection is the neutral `selection` lift plus a
/// 2 pt accent leading edge — never a red fill, because the rows that get
/// selected are usually failures.
struct ListRow<Leading: View, Trailing: View>: View {
    let title: String
    /// Leads the meta line and never ellipsizes (`#412`, `FIX-1365`).
    var id: String?
    /// The rest of the meta line; it truncates, the id does not.
    var meta: Text?
    var titleLines = 1
    var selected = false
    var action: () -> Void = {}
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                leading()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(titleLines)
                        .multilineTextAlignment(.leading)
                    if id != nil || meta != nil {
                        HStack(spacing: 6) {
                            if let id {
                                Text(id).font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
                                    .lineLimit(1).fixedSize().layoutPriority(1)
                            }
                            if let meta {
                                meta.font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
                Spacer(minLength: 6)
                trailing()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minHeight: id != nil || meta != nil ? 38 : 28)
            .contentShape(Rectangle())
            .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension ListRow where Trailing == EmptyView {
    init(title: String, id: String? = nil, meta: Text? = nil, titleLines: Int = 1, selected: Bool = false,
         action: @escaping () -> Void = {}, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, id: id, meta: meta, titleLines: titleLines, selected: selected,
                  action: action, leading: leading, trailing: { EmptyView() })
    }
}

/// The hover band and the selection lift, shared by every selectable row.
struct RowBackground: View {
    var selected: Bool
    var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        if selected {
            shape.fill(Theme.selection)
                .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.row) }
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 6)
                }
        } else if hovering {
            shape.fill(Theme.surfaceRaised)
        }
    }
}
