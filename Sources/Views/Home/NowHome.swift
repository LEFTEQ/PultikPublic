import SwiftUI

/// What both Home styles draw: the queue, the rows the keyboard walks (with
/// a resolved selection's tombstone held in place), the Handled section and
/// the selection. Built by the panel; the views only format it.
struct NowHomeModel {
    let queue: NowQueue
    let rows: [NowHomeRow]
    let handled: [ObservationLedger.Entry]
    let selectedID: String?
    let expanded: Set<String>
    var ci: CIThroughput?
    /// Restored needs still show: their oldest observation.
    var asOf: Date?
    /// Nothing has answered and nothing was restored.
    var awaiting = false
}

/// Home as the Now Line (copilot shell D6-D, the default `homeStyle`; board
/// card 77430): the hero strip, then every need a bar running into now on
/// the rolling 24 h (D12, the last half hour magnified, D13) in four lanes,
/// beside the ranked list at the same height; Handled below the lanes
/// (D14). ↑/↓ walk exactly `model.rows`; ↵ opens the row's object in its
/// module, or expands a fold.
struct NowLineView: View {
    let model: NowHomeModel
    let onActivate: (NowHomeRow) -> Void

    static let laneColumn: CGFloat = 108

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            GeometryReader { geo in
                let trackWidth = min(640, max(360, (geo.size.width - Self.laneColumn) * 0.44))
                VStack(spacing: TileMetrics.gap) {
                    NowHero(queue: model.queue, now: now, ci: model.ci, asOf: model.asOf,
                            compact: geo.size.width < 1100)
                    VStack(spacing: 0) {
                        header(now: now)
                        axis(now: now, trackWidth: trackWidth)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        NowRowList(model: model) { item, first, rank in
                            NowLineRow(item: item, first: first, rank: rank, now: now, trackWidth: trackWidth,
                                       summary: model.queue.summary(item.row.lane),
                                       selected: model.selectedID == item.id,
                                       expanded: model.expanded.contains(item.row.key)) { onActivate(item) }
                        } empty: {
                            NowEmptyRow(awaiting: model.awaiting, now: now)
                                .padding(.leading, Self.laneColumn)
                        }
                    }
                    .kitTile(padding: 10)
                }
                .padding(TileMetrics.gap)
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 10) {
            Text("The Now Line").microLabel(Theme.ink)
            Text("rolling 24 h · \(PultikFormat.clock(now.addingTimeInterval(-NowAxis.window))) → \(PultikFormat.clock(now)) · last 30 min ×\(Int(NowAxis.magnification))")
                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 8)
            Text("● began · ○ observed · ‹ before the window · ◇ deadline")
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
            if let asOf = model.asOf {
                Text(PultikFormat.asOf(asOf)).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private func axis(now: Date, trackWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.laneColumn, height: 22)
            NowAxisHeader(now: now).frame(width: trackWidth)
            HStack(spacing: 10) {
                Text("Ranked").microLabel().padding(.leading, 70)
                Spacer(minLength: 8)
                Text("Age").microLabel().frame(width: 58, alignment: .trailing)
                Text("Verb").microLabel().frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 6)
        }
    }
}

/// One Now Line row: its lane's label on the lane's first row, the track,
/// and the ranked row — one hover band and one selection lift across both.
private struct NowLineRow: View {
    let item: NowHomeRow
    let first: Bool
    let rank: String?
    let now: Date
    let trackWidth: CGFloat
    let summary: NowLaneSummary
    let selected: Bool
    let expanded: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            laneLabel.frame(width: NowLineView.laneColumn, height: 44, alignment: .topLeading)
            Button(action: action) {
                HStack(spacing: 0) {
                    NowTrack(incident: item.row.lead, lane: item.row.lane, now: now)
                        .frame(width: trackWidth)
                        .opacity(item.isTombstone ? 0.35 : 1)
                    NowRankedRow(item: item, rank: rank, now: now, selected: selected, expanded: expanded)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .background { RowBackground(selected: selected, hovering: hovering) }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .overlay(alignment: .top) {
            if first { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }

    @ViewBuilder
    private var laneLabel: some View {
        if first {
            VStack(alignment: .leading, spacing: 2) {
                // Two lines rather than an ellipsis: "WAITING / ON YOU".
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: summary.lane.symbol).font(.system(size: 9, weight: .semibold))
                    Text(summary.lane.title).font(Theme.Typo.micro).tracking(1.4).textCase(.uppercase)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(summary.lane.tone)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text("\(summary.incidents)").font(Theme.Typo.statCompact).foregroundStyle(summary.lane.tone)
                    if summary.folded > 0 {
                        Text("+\(summary.folded) folded").font(Theme.Typo.meta).monospacedDigit()
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.leading, 6)
        } else {
            // Holds the column: a frame on an empty view lays out nothing,
            // and every track must start at the same x.
            Color.clear
        }
    }
}

/// Home as Now first (copilot shell D6-A, the Settings alternative; board
/// card 77431): the ranked Now table — lane, need, a compact track, age,
/// verb — over the module tiles. Same queue, same rows, same keys.
struct NowFirstView<Tiles: View>: View {
    let model: NowHomeModel
    let onActivate: (NowHomeRow) -> Void
    @ViewBuilder let tiles: () -> Tiles

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            GeometryReader { geo in
                VStack(spacing: TileMetrics.gap) {
                    VStack(spacing: 0) {
                        header(now: now)
                        columns
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        NowRowList(model: model) { item, _, rank in
                            NowFirstRow(item: item, rank: rank, now: now,
                                        trackWidth: geo.size.width > 1300 ? 220 : 160,
                                        selected: model.selectedID == item.id,
                                        expanded: model.expanded.contains(item.row.key)) { onActivate(item) }
                        } empty: {
                            NowEmptyRow(awaiting: model.awaiting, now: now)
                        }
                    }
                    .kitTile(padding: 10)
                    .frame(height: max(280, geo.size.height * 0.56))
                    tiles()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(TileMetrics.gap)
            }
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Text("Now").microLabel(Theme.ink)
            Chip("\(model.queue.incidentCount)")
            Text("ranked by urgency, then severity, then time waited · related signals grouped")
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 8)
            ForEach(NowLane.allCases, id: \.self) { lane in
                let count = model.queue.summary(lane).incidents
                HStack(spacing: 4) {
                    Circle().fill(count > 0 ? lane.tone : Theme.idle).frame(width: 6, height: 6)
                    Text("\(lane.title) \(count)").font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                }
            }
            Text(PultikFormat.asOf(model.asOf ?? now)).font(Theme.Typo.meta).monospacedDigit()
                .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private var columns: some View {
        HStack(spacing: 10) {
            Text("#").microLabel().frame(width: 30, alignment: .trailing)
            Text("Lane").microLabel().frame(width: 112, alignment: .leading)
            Text("Need").microLabel()
            Spacer(minLength: 8)
            Text("Age").microLabel().frame(width: 58, alignment: .trailing)
            Text("Verb").microLabel().frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }
}

private struct NowFirstRow: View {
    let item: NowHomeRow
    let rank: String?
    let now: Date
    let trackWidth: CGFloat
    let selected: Bool
    let expanded: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NowRankedRow(item: item, rank: rank, now: now, selected: selected, expanded: expanded, laneTag: true,
                         trackWidth: trackWidth)
                .contentShape(Rectangle())
                .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The scrolling list both styles share: rows in drawn order, each carrying
/// the id the keyboard selects by, scrolled into view as the arrows move;
/// the Handled section below.
private struct NowRowList<Row: View, Empty: View>: View {
    let model: NowHomeModel
    @ViewBuilder let row: (_ item: NowHomeRow, _ firstOfLane: Bool, _ rank: String?) -> Row
    @ViewBuilder let empty: () -> Empty

    var body: some View {
        let ranks = NowQueue.ranks(model.rows)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.rows.isEmpty { empty() }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, item in
                        row(item, index == 0 || model.rows[index - 1].row.lane != item.row.lane, ranks[item.id])
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
}

/// Nothing to rank: one "All quiet" line with its time — or, before the
/// first read of a cold start with nothing restored, the rows' geometry.
private struct NowEmptyRow: View {
    let awaiting: Bool
    let now: Date

    var body: some View {
        if awaiting {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(width: [320, 260, 290][index], height: 12)
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
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
    }
}
