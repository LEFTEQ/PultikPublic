import SwiftUI

/// Home's Production tile (panel Home D2/D7, 2026-10-07): the prod board
/// given room — every deployment card in a grid (3 + 2 on a wide panel) with
/// taller 24 h bars. Same cards, same verdicts as the rail: they only format
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

    private let columns = [GridItem(.adaptive(minimum: 236), spacing: 8, alignment: .top)]

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
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(glance.cards) { card in
                        ProdCardView(card: card, now: now, barHeight: 22) { onOpen(card.key) }
                    }
                }
            }
            if !sentryIssues.isEmpty {
                ProdRail(issues: sentryIssues, isResolved: isResolved)
            }
        }
        .tileSurface()
    }
}
