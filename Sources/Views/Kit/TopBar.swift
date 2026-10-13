import SwiftUI

/// The decided top bar (DESIGN.md §8 TopBar, the mock kit's `topbar.html`):
/// the full-width search with the app badge at its right, then the module
/// strip that is the switcher. Identical in every module except the current
/// chip and the search state.
struct TopBar<Search: View, Strip: View>: View {
    @ViewBuilder var search: () -> Search
    @ViewBuilder var strip: () -> Strip

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                search()
                AppBadge()
            }
            strip()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// Pultík's mark at the search field's right: the one red square.
struct AppBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.accent.gradient)
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: "command").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)
            .accessibilityLabel("Pultík")
    }
}

/// What the search is narrowed to: a module's glyph and name with an ×.
/// Backspace on an empty field removes it (the caller's key handling).
struct SearchScope {
    let title: String
    let symbol: String
    let onRemove: () -> Void
}

/// The 36 pt vibrant search capsule (DESIGN.md §8 SearchField). Always
/// focused, so a neutral hairline and never a red ring; the red lives on the
/// caret (the root tint) and the scope chip. The caller passes its own
/// `TextField`, which keeps its focus and key routing.
struct SearchField<Field: View>: View {
    var scope: SearchScope?
    var leadingSymbol = "magnifyingglass"
    var leadingTone = Theme.ink3
    /// The trailing result count (`3 runs`).
    var count: String?
    /// Trailing hints; nil hides them (while a row is selected, say).
    var showsHints = true
    @ViewBuilder var field: () -> Field

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(leadingTone)
            if let scope {
                Button(action: scope.onRemove) {
                    HStack(spacing: 4) {
                        Image(systemName: scope.symbol).font(.system(size: 10, weight: .semibold))
                        Text(scope.title).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.7)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.accentSoft, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Leave \(scope.title) (⌫ on an empty field)")
            }
            field()
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            if let count {
                Text(count).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).fixedSize()
            }
            if showsHints {
                Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 16)
                HStack(spacing: 4) {
                    Text("modules").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    KbdHint("⌘1–9")
                }
                .fixedSize()
                KbdHint("esc")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .vibrantControl(Capsule(), fill: 0.07)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// A module chip's live signal (DESIGN.md §8 ModuleStrip). `alarm` washes the
/// chip in danger and widens it to say why — the one chip that may be red.
struct ModuleSignal: Equatable {
    /// A prod deployment's dot; hollow is blind or unmonitored, so the state
    /// never rides on colour alone.
    struct Dot: Equatable {
        let tone: Color
        var hollow = false
    }

    enum Kind: Equatable {
        case none
        /// A counted pill: `4`.
        case pill(String)
        /// Words with an optional leading symbol: `✗ 3 failed`, `30 stale`.
        case text(String, symbol: String?)
        /// One dot per item: the prod deployments.
        case dots([Dot])
    }

    var kind: Kind = .none
    var tone: Color = Theme.ink2
    var alarm: String?
    var help: String?

    static let none = ModuleSignal()
}

/// The status strip IS the switcher (D5-A): nine vibrant capsules sharing the
/// row's width, each with its glyph, name and live signal. The current module
/// is a neutral lift with a 2 pt accent leading edge and an accent glyph.
struct ModuleStrip: View {
    let current: PanelModule?
    let signals: [PanelModule: ModuleSignal]
    let onSelect: (PanelModule) -> Void
    /// Settings ▸ Modules' order (stay in Pultík D4): the strip and ⌘1–9.
    var order: [PanelModule] = PanelModule.allCases
    @Namespace private var lift

    var body: some View {
        // Named chips while every chip still draws whole (an alarm may
        // truncate); short of that — nine signals at 1240 pt — the chips
        // other than the current one keep their glyph and signal only.
        ViewThatFits(in: .horizontal) {
            row(named: true)
            row(named: false)
        }
        .frame(height: 34)
        .animation(.snappy(duration: 0.22), value: current)
    }

    private func row(named: Bool) -> some View {
        StripLayout(spacing: 6) {
            ForEach(order) { module in
                ModuleChip(module: module, number: module.number(in: order), signal: signals[module] ?? .none,
                           isCurrent: module == current, showsTitle: named || module == current, lift: lift) {
                    onSelect(module)
                }
            }
        }
    }
}

private struct ModuleChip: View {
    let module: PanelModule
    let number: Int
    let signal: ModuleSignal
    let isCurrent: Bool
    let showsTitle: Bool
    let lift: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: module.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.ink2)
                if showsTitle {
                    Text(module.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                signalView
                if let alarm = signal.alarm {
                    Text(alarm)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
            .background {
                ZStack {
                    if signal.alarm != nil {
                        Capsule().fill(Theme.danger.opacity(0.16))
                        Capsule().strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1)
                    } else {
                        Capsule().fill(Color.white.opacity(hovering ? 0.09 : 0.06))
                    }
                    if isCurrent {
                        Capsule().fill(Theme.selection)
                            .overlay(SpecularRim(shape: Capsule()))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accent).frame(width: 2).padding(.vertical, 8).padding(.leading, 5)
                            }
                            .matchedGeometryEffect(id: "lift", in: lift)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(signal.help ?? "\(module.title) — ⌘\(number)")
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var signalView: some View {
        switch signal.kind {
        case .none:
            EmptyView()
        case let .pill(text):
            Text(text)
                .font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(signal.tone)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(signal.tone.opacity(0.16), in: Capsule())
                .fixedSize()
        case let .text(text, symbol):
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
                Text(text).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(signal.tone)
            .fixedSize()
        case let .dots(dots):
            HStack(spacing: 3) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                    StatusDot(tone: dot.tone, style: dot.hollow ? .ring : .solid)
                }
            }
            .fixedSize()
        }
    }
}

/// Lays the chips out at their ideal widths and shares what is left equally,
/// so the row is always full. Short of room, the chips that can shrink (an
/// alarm's words truncate) give it up first; a chip's title and signal are
/// fixed, so squeezing past that would spill them over the next capsule.
struct StripLayout: Layout {
    var spacing: CGFloat = 6

    /// Its ideal width is the least row that still draws every chip whole —
    /// what `ModuleStrip`'s `ViewThatFits` asks before dropping titles.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let least = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? least.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)),
                      height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let slack = zip(ideals, subviews).map { ideal, subview in
            max(0, ideal - subview.sizeThatFits(ProposedViewSize(width: 0, height: bounds.height)).width)
        }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let natural = ideals.reduce(0, +)
        let room = bounds.width - gaps
        let extra = (room - natural) / CGFloat(subviews.count)
        let shortfall = min(1, (natural - room) / max(slack.reduce(0, +), 1))
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = extra >= 0 ? ideals[index] + extra : ideals[index] - slack[index] * shortfall
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
