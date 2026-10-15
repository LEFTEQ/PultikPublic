import SwiftUI

/// Home's Production widget (vt-7727 D8): one dense line per deployment —
/// its verdict, tier and the day's counts, its check chips while it is not
/// green. Same cards, same verdicts as the rail: they only format
/// `ProdGlance`, and a blind deployment still reads "blind since HH:MM",
/// never hidden and never green. A card opens `.h <key>`.
struct ProdTile: View {
    let glance: ProdGlance
    let configIssues: [String]
    /// The Mac's own Sentry sweep, until Hlídač answers once — empty after.
    let sentryIssues: [ProdIssue]
    let isResolved: (ProdIssue) -> Bool
    let now: Date
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TileHeader(title: "Production", count: glance.attention, tone: glance.headingTone,
                       caption: glance.cards.isEmpty ? "Hlídač" : "\(glance.cards.count) deployments · 24h",
                       action: { onOpen("") },
                       actionHelp: "Every deployment × check — .h")
            if !configIssues.isEmpty {
                ProdConfigIssues(issues: configIssues)
            }
            if glance.cards.isEmpty, let waiting = glance.waiting {
                HStack(spacing: RailRowMetrics.dotGap) {
                    ProdToneDot(tone: .blind)
                    Text(waiting)
                        .font(RailRowMetrics.titleFont)
                        .foregroundStyle(.orange)
                }
                .help("The prod board reads Hlídač's digest; nothing has answered yet.")
            }
            if !glance.cards.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(glance.cards) { card in
                            ProdCardView(card: card, now: now, action: { onOpen(card.key) }, dense: true)
                        }
                        if !sentryIssues.isEmpty {
                            ProdRail(issues: sentryIssues, isResolved: isResolved)
                        }
                    }
                }
            } else if !sentryIssues.isEmpty {
                ProdRail(issues: sentryIssues, isResolved: isResolved)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .tileSurface()
    }
}
