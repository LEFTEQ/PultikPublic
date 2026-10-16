import SwiftUI

/// A detail's tab bar (DESIGN.md §8 DetailTabs; PR workbench D5): titles with
/// their counts, the shown one in `ink` over a gliding 2 pt accent underline
/// (the accent is selection), a hairline under the row. While the detail is
/// entered the trailing hints say ←/→ walk the tabs and Esc leaves.
struct DetailTabs: View {
    struct Tab: Identifiable, Equatable {
        let id: String
        let title: String
        var count: Int?
        /// The count is a verdict (failing checks): it reads in `danger`.
        var alarming = false
    }

    let tabs: [Tab]
    let selected: String?
    var entered = false
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                button(tab)
            }
            Spacer(minLength: 8)
            if entered {
                HStack(spacing: 5) {
                    KbdHint("← →")
                    Text("tabs").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    KbdHint("esc")
                    Text("list").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(Theme.Motion.focus(reduceMotion), value: entered)
    }

    private func button(_ tab: Tab) -> some View {
        let shown = tab.id == (selected ?? tabs.first?.id)
        return Button { select(tab.id) } label: {
            HStack(spacing: 5) {
                Text(tab.title)
                    .font(shown ? Theme.Typo.title : Theme.Typo.body)
                    .foregroundStyle(shown ? Theme.ink : Theme.ink2)
                if let count = tab.count {
                    Text(verbatim: PultikFormat.count(Double(count)))
                        .font(Theme.Typo.meta).monospacedDigit()
                        .foregroundStyle(tab.alarming ? Theme.danger : Theme.ink3)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if shown {
                    Capsule().fill(Theme.accent).frame(height: 2)
                        .matchedGeometryEffect(id: "underline", in: underline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}
