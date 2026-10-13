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
    /// The row's object id where it can be marked (bulk D1): marked, it
    /// wears the accent's tint under the lift — marking is selection too.
    var mark: String?
    @Environment(\.rowMarks) private var marks

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        let marked = mark.map(marks.marked.contains) ?? false
        if selected {
            shape.fill(Theme.selection)
                .background { if marked { shape.fill(Self.markTint) } }
                .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.row) }
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 6)
                }
        } else if marked {
            shape.fill(Self.markTint)
        } else if hovering {
            shape.fill(Theme.surfaceRaised)
        }
    }

    static let markTint = Theme.accent.opacity(0.12)
}

/// A module's marks as its rows read them (bulk actions D1): which rows are
/// marked and can be, how each fares in the module's batch, and the check's
/// toggle. Empty — no checks — outside an entered module with bulk verbs.
struct RowMarks {
    var marked: Set<String> = []
    var markable: Set<String> = []
    var states: [String: BulkRowState] = [:]
    var toggle: ((String) -> Void)?
}

private struct RowMarksEnvironmentKey: EnvironmentKey {
    static let defaultValue = RowMarks()
}

extension EnvironmentValues {
    var rowMarks: RowMarks {
        get { self[RowMarksEnvironmentKey.self] }
        set { self[RowMarksEnvironmentKey.self] = newValue }
    }
}

/// A row's leading glyph, or its mark (bulk D1): the check takes the glyph's
/// place while the row is hovered or marked — on every markable row once
/// any is — and a batch's spinner or outcome while it has one. A click on
/// the check marks without opening the row.
struct MarkSlot<Glyph: View>: View {
    let id: String
    var hovering = false
    var size: CGFloat = 11
    @ViewBuilder var glyph: () -> Glyph
    @Environment(\.rowMarks) private var marks

    var body: some View {
        let marked = marks.marked.contains(id)
        if let state = marks.states[id] {
            BulkStateGlyph(state: state)
                .font(.system(size: size))
        } else if let toggle = marks.toggle, marks.markable.contains(id), marked || hovering || !marks.marked.isEmpty {
            Button { toggle(id) } label: {
                Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: size))
                    .foregroundStyle(marked ? Theme.accent : Theme.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(marked ? "Unmark" : "Mark for a bulk verb (⌘-click the row does the same)")
            .accessibilityLabel(marked ? "Unmark" : "Mark")
        } else {
            glyph()
        }
    }
}
