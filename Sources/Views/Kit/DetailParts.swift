import SwiftUI

// The small parts module details share (extracted from the PRs and CI
// details, WP5–WP6). Tokens from `Theme`, never literals.

/// A folded group's one line: its glyph, its count, a chevron.
struct DisclosureLine<Glyph: View>: View {
    let text: String
    @Binding var open: Bool
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                glyph().frame(width: 14)
                Text(verbatim: text).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.ink3)
                Spacer()
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `arrow.up.right` in ink: every link (DESIGN.md §9, never blue).
struct LinkGlyph: View {
    let url: URL?
    /// What VoiceOver reads: the destination, never "arrow".
    let label: String

    var body: some View {
        if let url {
            Button { OverviewURL.open(url) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(label) — \(url.absoluteString)")
            .accessibilityLabel(label)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

/// Loading at the real row geometry (DESIGN.md §7).
struct SkeletonBars: View {
    let widths: [CGFloat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceRaised)
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: 12)
            }
        }
    }
}
