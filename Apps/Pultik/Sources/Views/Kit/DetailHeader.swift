import SwiftUI

/// A verb in a detail header: one primary (red prominent glass), the rest
/// neutral glass, each with its shortcut hint. Destructive verbs confirm in
/// their own view; ↵ never mutates.
struct DetailVerb: Identifiable {
    enum Role { case primary, normal }
    let title: String
    var symbol: String?
    /// The hint drawn beside the title (`⌘R`, `⌘↵`).
    var kbd: String?
    var role: Role = .normal
    var help: String?
    let action: () -> Void
    var id: String { title }
}

/// The selected object's header (DESIGN.md §8 DetailHeader): glyph · title
/// with an inline secondary name · status chip, a monospaced meta line, and
/// the verb row.
struct DetailHeader<Glyph: View>: View {
    let title: String
    var secondary: String?
    var status: Chip?
    var meta: Text?
    var verbs: [DetailVerb] = []
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
                        .layoutPriority(1)
                    if let secondary {
                        Text(secondary).font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    if let status { status }
                }
                if let meta {
                    meta.font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(verbs) { verb in
                    VerbButton(verb: verb)
                }
            }
        }
    }
}

/// One detail verb — `.glassProminent` in the accent for the primary, a
/// neutral vibrant capsule with an ink label for the rest. Not `.glass`:
/// it takes the panel root's accent tint, and every verb read as primary.
struct VerbButton: View {
    let verb: DetailVerb

    var body: some View {
        if verb.role == .primary {
            Button(action: verb.action) { label }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .help(verb.help ?? verb.title)
        } else {
            Button(action: verb.action) {
                label
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .vibrantControl(Capsule(), lifted: false)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(verb.help ?? verb.title)
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let symbol = verb.symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(verb.title).font(.system(size: 12, weight: .semibold))
            if let kbd = verb.kbd {
                Text(kbd)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .opacity(0.7)
            }
        }
        .controlSize(.small)
    }
}

/// One `surface` strip under the detail header: the related object with its
/// chips and a trailing `⌘↵ open` (DESIGN.md §8 ContextBand).
struct ContextBand<Content: View>: View {
    var openHint: String? = "⌘↵"
    var onOpen: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 8)
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        if let openHint { KbdHint(openHint) }
                        Text("open").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}
