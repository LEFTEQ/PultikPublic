import SwiftUI

/// Home (panel Home D2, 2026-10-07): the right region while the query is
/// empty and no `.` mode is open — a fixed-slot bento. Production spans the
/// top of the main column, CI/CD and Devbox share the row beneath it, and
/// Pull requests runs the full height on the right. Trouble tints a tile, it
/// never moves one; a hidden tile (its backend unreachable) gives its slot to
/// its neighbour. Below `scrollBelow` points the tiles keep their floors and
/// Home scrolls as one (a 14″ laptop at 80% height).
struct HomeView<Prod: View, PRs: View, CI: View, Devbox: View>: View {
    let showProd: Bool
    let showCI: Bool
    let showDevbox: Bool
    @ViewBuilder let prod: () -> Prod
    @ViewBuilder let prs: () -> PRs
    @ViewBuilder let ci: () -> CI
    @ViewBuilder let devbox: () -> Devbox

    static var scrollBelow: CGFloat { 640 }
    private static var lowerFloor: CGFloat { 280 }

    /// Below this the main column stacks CI/CD over Devbox (a portrait
    /// screen) rather than squeezing both into half a column each.
    private static var sideBySideFrom: CGFloat { 620 }

    var body: some View {
        GeometryReader { geo in
            let prWidth = min(480, max(340, geo.size.width * 0.38))
            let stacked = geo.size.width - prWidth - TileMetrics.gap * 3 < Self.sideBySideFrom
            if geo.size.height < Self.scrollBelow {
                ScrollView(.vertical, showsIndicators: false) {
                    layout(prWidth: prWidth, stacked: stacked, height: nil)
                }
            } else {
                layout(prWidth: prWidth, stacked: stacked, height: geo.size.height)
            }
        }
    }

    /// `height` nil = scrolling: every flexible tile takes its floor.
    private func layout(prWidth: CGFloat, stacked: Bool, height: CGFloat?) -> some View {
        let gap = TileMetrics.gap
        return HStack(alignment: .top, spacing: gap) {
            VStack(spacing: gap) {
                if showProd { prod() }
                if stacked {
                    // CI/CD keeps its natural height; Devbox takes the rest.
                    if showCI { ci().fixedSize(horizontal: false, vertical: true) }
                    if showDevbox {
                        devbox().frame(minHeight: Self.lowerFloor,
                                       maxHeight: height == nil ? Self.lowerFloor : .infinity)
                    }
                } else if showCI || showDevbox {
                    HStack(alignment: .top, spacing: gap) {
                        if showCI { ci() }
                        if showDevbox { devbox() }
                    }
                    .frame(minHeight: Self.lowerFloor,
                           maxHeight: height == nil ? Self.lowerFloor : .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .top)
            prs()
                .frame(width: prWidth)
                .frame(height: height.map { $0 - gap * 2 } ?? Self.scrollBelow - gap * 2, alignment: .top)
        }
        .padding(gap)
        .frame(height: height, alignment: .top)
    }
}
