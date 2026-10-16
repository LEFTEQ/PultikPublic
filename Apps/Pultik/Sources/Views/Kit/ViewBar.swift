import SwiftUI

/// A module's views as one segmented row in its header (vt-7727 D1, D5):
/// the shown view lifted, the rest quiet, ⇥ named on the trailing edge. A
/// click shows a view; the keys are `KeyboardCoordinator`'s `.view` intent.
struct ViewBar: View {
    let views: [ModuleView]
    let selected: ModuleView?
    var onSelect: (ModuleView) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(views, id: \.self) { view in
                    let shown = view == selected
                    Button { onSelect(view) } label: {
                        Text(view.title)
                            .font(.system(size: 11.5, weight: shown ? .semibold : .regular))
                            .foregroundStyle(shown ? Theme.ink : Theme.ink2)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background { if shown { Capsule().fill(Color.white.opacity(0.1)) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(shown ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.04), in: Capsule())
            KbdHint("⇥")
                .help("⇥ / ⇧⇥ switch the view")
        }
        .fixedSize()
    }
}
