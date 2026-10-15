import SwiftUI

/// What Home draws: the queue, the rows the keyboard walks (with a resolved
/// selection's tombstone held in place), the Handled section and the
/// selection. Built by the panel; the views only format it.
struct NowHomeModel {
    let queue: NowQueue
    let rows: [NowHomeRow]
    let handled: [ObservationLedger.Entry]
    let selectedID: String?
    let expanded: Set<String>
    /// Restored needs still show: their oldest observation.
    var asOf: Date?
    /// Nothing has answered and nothing was restored.
    var awaiting = false
}

/// The glances beside Now (vt-7727 D8), in their one order: two to a row.
enum HomeWidget: String, CaseIterable, Identifiable {
    case prod, prs, ci, devbox, estate, mac

    var id: String { rawValue }
}

/// Home (vt-7727 D8, the operator's pick): the full-height Now column on the
/// left, the widgets two to a row beside it. ↑/↓ walk exactly `model.rows`;
/// ↵ opens the row's object in its module, or expands a fold. The widgets
/// are glances: a click opens their module, the keyboard never enters them.
struct HomeView<Widget: View>: View {
    let model: NowHomeModel
    let widgets: [HomeWidget]
    let onActivate: (NowHomeRow) -> Void
    @ViewBuilder let widget: (HomeWidget) -> Widget

    var body: some View {
        HStack(alignment: .top, spacing: TileMetrics.gap) {
            NowColumn(model: model, onActivate: onActivate)
                .frame(width: NowColumn.width)
            HomeWidgetGrid(widgets: widgets, widget: widget)
        }
        .padding(TileMetrics.gap)
    }
}

/// Now as the PR list draws PRs (D7): lanes as headings, one 28 pt line per
/// need, folds as "+27 sessions waiting · …", Handled below. A fixed 590 pt
/// holds every lane of a folded ~100-need queue at 1600 × 985 (D8).
struct NowColumn: View {
    static let width: CGFloat = 590

    let model: NowHomeModel
    let onActivate: (NowHomeRow) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            VStack(spacing: 0) {
                header(now: now)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.rows.isEmpty { NowEmptyRow(awaiting: model.awaiting, now: now) }
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, item in
                                VStack(spacing: 0) {
                                    if index == 0 || model.rows[index - 1].row.lane != item.row.lane {
                                        NowLaneHeading(summary: model.queue.summary(item.row.lane))
                                    }
                                    NowLine(item: item, now: now, selected: model.selectedID == item.id,
                                            expanded: model.expanded.contains(item.row.key)) { onActivate(item) }
                                }
                                .id(item.id)
                            }
                            NowHandledSection(entries: model.handled)
                        }
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .kitTile(padding: 10)
        }
    }

    /// "NOW 90 · ● 7 ● 56 ● 3 ● 24 · 17:36": the incident count, each lane's
    /// count by its tone, and the snapshot's age while restored needs show.
    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Text("Now").microLabel(Theme.ink)
            Chip("\(model.queue.incidentCount)")
            Spacer(minLength: 8)
            ForEach(NowLane.allCases, id: \.self) { lane in
                let count = model.queue.summary(lane).incidents
                HStack(spacing: 4) {
                    Circle().fill(count > 0 ? lane.tone : Theme.idle).frame(width: 6, height: 6)
                    Text(verbatim: "\(count)").font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                }
                .help("\(lane.title): \(count)")
            }
            Text(PultikFormat.asOf(model.asOf ?? now)).font(Theme.Typo.meta).monospacedDigit()
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

/// Nothing to rank: one "All quiet" line with its time — or, before the
/// first read of a cold start with nothing restored, the lines' geometry.
private struct NowEmptyRow: View {
    let awaiting: Bool
    let now: Date

    var body: some View {
        if awaiting {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(width: [320, 260, 290, 240][index], height: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .accessibilityLabel("Waiting for the first reads")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("All quiet").font(Theme.Typo.body).foregroundStyle(Theme.ink)
                Text(PultikFormat.asOf(now)).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: NowLine.height)
            .padding(.top, 8)
        }
    }
}

/// The widgets two to a row, every row the same height, filling the space
/// beside Now. A cell narrower than `compactWidth` (297 pt at a 1240 pt
/// panel) tells its tile to drop its secondary columns (D8).
struct HomeWidgetGrid<Widget: View>: View {
    static var compactWidth: CGFloat { 360 }

    let widgets: [HomeWidget]
    @ViewBuilder let widget: (HomeWidget) -> Widget

    var body: some View {
        GeometryReader { geo in
            let cell = (geo.size.width - TileMetrics.gap) / 2
            let starts = Array(stride(from: 0, to: widgets.count, by: 2))
            // Every row the same height whatever its tiles hold: a tile's
            // content scrolls or clips inside its cell, never grows the row.
            let height = max(0, (geo.size.height - TileMetrics.gap * CGFloat(max(starts.count - 1, 0)))
                / CGFloat(max(starts.count, 1)))
            VStack(spacing: TileMetrics.gap) {
                ForEach(starts, id: \.self) { start in
                    HStack(spacing: TileMetrics.gap) {
                        ForEach(widgets[start..<min(start + 2, widgets.count)]) { item in
                            widget(item)
                                .frame(width: cell, height: height, alignment: .top)
                                .clipShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
                        }
                        if start + 1 == widgets.count { Color.clear.frame(width: cell, height: height) }
                    }
                }
            }
            .environment(\.tileCompact, cell < Self.compactWidth)
        }
    }
}

private struct TileCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A Home widget's cell is narrower than `HomeWidgetGrid.compactWidth`:
    /// the tile keeps its primary figures and drops its secondary columns.
    var tileCompact: Bool {
        get { self[TileCompactKey.self] }
        set { self[TileCompactKey.self] = newValue }
    }
}
