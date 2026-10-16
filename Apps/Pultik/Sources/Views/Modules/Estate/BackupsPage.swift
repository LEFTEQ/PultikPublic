import SwiftUI

/// Estate's Backups view (vt-7727 D1, S8): one card per box with its
/// verdict — Semafor's own rules (`BackupVerdict`): stop, wait or go — then
/// the Backups timeline (vt-7781 WP7: a row per surface, stacked by box),
/// then the Pipelines table, every surface of `/estate/backups` with each
/// place's freshness (local · Storage Box · S3 · vault · restore proof),
/// the last good write and the next run. Each box comes from the Semafor
/// that observes it (D6). A row opens the pipeline's places in full. The
/// timeline's playhead replays the box cards (`/estate/backups?at=` of each
/// box's Semafor); the table stays live.
struct BackupsPage: View {
    let store: StatusStore
    let filter: String
    var selectedID: String?
    var view: ModuleView? = .backups
    /// The page is the displayed one: its canvas draws (a warm hidden body draws nothing).
    var active = false
    /// ↵ entered the timeline (no row selected): its keys, its marks' cards.
    var entered = false
    var stack: [DetailRef] = []
    var onView: (ModuleView) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onPop: () -> Void = {}
    var card: (DetailRef) -> AnyView = { _ in AnyView(EmptyView()) }
    var now = Date()

    static let timelineHeight: CGFloat = 300

    static func objectID(_ pipeline: SemaforBackups.Pipeline) -> String { "backup:\(pipeline.id)" }

    private var text: String { filter.trimmingCharacters(in: .whitespaces) }

    /// Boxes in the estate's order, then any box only the backups name.
    private var boxes: [String] {
        var order = store.estateBoxes.map(\.box.name)
        for pipeline in store.estatePipelines where !order.contains(pipeline.box) { order.append(pipeline.box) }
        return order
    }

    /// Per box, worst verdict first, then by name — as drawn.
    var pipelines: [SemaforBackups.Pipeline] {
        let all = store.estatePipelines.filter { pipeline in
            text.isEmpty || [pipeline.box, pipeline.name, pipeline.cadence].contains {
                $0?.localizedCaseInsensitiveContains(text) == true
            }
        }
        return boxes.flatMap { box in
            all.filter { $0.box == box }.sorted { a, b in
                let (va, vb) = (BackupVerdict.of(a, now: now), BackupVerdict.of(b, now: now))
                return va != vb ? va > vb : a.name < b.name
            }
        }
    }

    var body: some View {
        let rows = pipelines
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 10) {
                header(rows)
                if store.estatePipelines.isEmpty {
                    RailNote(store.semaforStates.allSatisfy { $0.state.backups == nil }
                             ? "No backups read yet — Semafor answers while Estate is open"
                             : "Semafor reports no backup pipelines")
                } else {
                    boxCards
                    timeline
                    PipelinesTable(pipelines: rows, selectedID: selectedID, now: now, onOpen: onOpen)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { EstateTimelineFeed.backups.install(store) }
        .onChange(of: EstateTimelineFeed.Trigger(store: store, lens: .backups), initial: true) {
            EstateTimelineFeed.backups.refeed()
        }
    }

    /// The box cards, live — or, while the playhead replays, as each box's
    /// Semafor answered `/estate/backups?at=` (ages from that instant).
    @ViewBuilder private var boxCards: some View {
        let replay = store.timelineReplay.flatMap { $0.lens == .backups ? $0 : nil }
        if let replay {
            HStack(spacing: 8) {
                Chip("replay \(PultikFormat.clock(replay.at))", .warn, symbol: "clock.arrow.circlepath")
                Text("the boxes' backups as they stood at the playhead · the table stays live")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
        }
        FlowRow(hSpacing: 8, vSpacing: 8) {
            ForEach(boxes, id: \.self) { box in
                if let replay {
                    if let host = backupsHost(box), let replayed = replay.backups[host] {
                        BoxCard(box: box, pipelines: replayed.pipelineList.filter { $0.box == box }, now: replay.at,
                                replayed: true)
                    } else {
                        BoxCard.unavailable(box)
                    }
                } else {
                    BoxCard(box: box, pipelines: store.estatePipelines.filter { $0.box == box }, now: now)
                }
            }
        }
    }

    /// The Semafor a box's backups come from (D6): the one observing the box,
    /// else the first whose live backups list it (as `estatePipelines` draws it).
    private func backupsHost(_ box: String) -> String? {
        store.semaforHost(forBox: box)
            ?? store.semaforStates.first { $0.state.backups?.pipelineList.contains { $0.box == box } == true }?.host
    }

    /// The Backups timeline (vt-7781 WP7): every backup and restore run per
    /// surface, the schedule ahead; ↵ enters it while no row is selected.
    private var timeline: some View {
        let summary = TimelineStage.shared.summaries[.backupsTimeline] ?? .init()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Timeline").microLabel()
                Text(EstateTimelineSummary.line(summary, lanes: "backups"))
                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
                if let unknown = EstateTimelineSummary.unknown(summary) {
                    Text(unknown).font(Theme.Typo.meta).foregroundStyle(Theme.warn).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            CanvasKeys(slot: .backupsTimeline, entered: entered)
            StackedDetail(stack: entered ? stack : [], onPop: onPop) {
                TimelineCanvas(slot: .backupsTimeline, active: active)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .focusRing(entered, radius: Theme.Radius.tile)
            } card: { ref in
                card(ref)
            }
            .frame(height: Self.timelineHeight)
        }
    }

    private func header(_ rows: [SemaforBackups.Pipeline]) -> some View {
        let look = rows.filter { BackupVerdict.of($0, now: now) != .go }.count
        return HStack(alignment: .center, spacing: 10) {
            Text("Estate").font(Theme.Typo.title)
            ViewBar(views: PanelModule.estate.views, selected: view, onSelect: onView)
            Text("\(rows.count) pipelines\(look > 0 ? " · \(look) need a look" : "")")
                .font(Theme.Typo.figure).foregroundStyle(look > 0 ? Theme.warn : Theme.ink2)
            Spacer(minLength: 4)
            if let asOf = store.estateAsOf {
                Text("Semafor \(PultikFormat.asOf(asOf))").font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            }
        }
    }
}

extension BackupVerdict {
    var tone: Color {
        switch self {
        case .go: Theme.ok
        case .wait: Theme.warn
        case .stop: Theme.danger
        }
    }

    var title: String {
        switch self {
        case .go: "go"
        case .wait: "wait"
        case .stop: "stop"
        }
    }
}

/// A place's freshness as one cell: a dot in its state's tone and its age;
/// `none` is a quiet dash — no copy is expected there.
struct BackupPlaceCell: View {
    let place: SemaforBackups.Place?

    var body: some View {
        let state = place?.state ?? "none"
        HStack(spacing: 5) {
            if state == "none" {
                Text("—").foregroundStyle(Theme.ink3)
            } else {
                StatusDot(tone: Self.tone(state))
                Text(place?.ageS.map { PultikFormat.age($0) } ?? state)
                    .foregroundStyle(state == "fresh" ? Theme.ink2 : Self.tone(state))
            }
        }
        .font(Theme.Typo.meta).monospacedDigit().lineLimit(1)
        .help([place?.location, place?.unit, place?.detail].compactMap { $0 }.joined(separator: " · "))
    }

    static func tone(_ state: String) -> Color {
        switch state {
        case "stale": Theme.danger
        case "near": Theme.warn
        case "fresh": Theme.ok
        default: Theme.ink3
        }
    }
}

/// One box: its verdict, how many pipelines need a look, the newest good
/// write — live, or as they stood at the playhead (`replayed`, `now` its instant).
struct BoxCard: View {
    let box: String
    let pipelines: [SemaforBackups.Pipeline]
    let now: Date
    var replayed = false

    /// A box whose Semafor did not answer the replay: never live data as the past.
    static func unavailable(_ box: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(tone: Theme.ink3, style: .ring)
                Text(box).font(Theme.Typo.title).foregroundStyle(Theme.ink)
            }
            Text("unavailable at the playhead").font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            Text("the replay did not load").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.tile) }
    }

    var body: some View {
        let verdict = BackupVerdict.box(pipelines, now: now)
        let look = pipelines.filter { BackupVerdict.of($0, now: now) != .go }.count
        let newest = pipelines.compactMap { SemaforTime.date($0.lastOkAt) }.max()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(tone: verdict.tone)
                Text(box).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                Text(verdict.title.uppercased()).microLabel(verdict.tone)
            }
            Text("\(pipelines.count) pipelines\(look > 0 ? " · \(look) need a look" : "")")
                .font(Theme.Typo.meta).foregroundStyle(look > 0 ? verdict.tone : Theme.ink2)
            Text(newest.map { "newest good \(PultikFormat.age(now.timeIntervalSince($0))) \(replayed ? "before" : "ago")" }
                ?? "no good write")
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.tile) }
    }
}

/// Every pipeline with each place's freshness: box · name · cadence, the
/// five places, the last good write and the next run.
struct PipelinesTable: View {
    let pipelines: [SemaforBackups.Pipeline]
    var selectedID: String?
    let now: Date
    let onOpen: (String) -> Void

    static let placeWidth: CGFloat = 96
    static let width: CGFloat = 250 + placeWidth * CGFloat(BackupPlace.allCases.count) + 70 + 70 + 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Pipeline").microLabel().frame(width: 250, alignment: .leading)
                ForEach(BackupPlace.allCases, id: \.self) { place in
                    Text(place.title).microLabel().frame(width: Self.placeWidth, alignment: .leading)
                }
                Text("Last good").microLabel().frame(width: 70, alignment: .trailing)
                Text("Next").microLabel().frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            ForEach(pipelines, id: \.id) { pipeline in
                PipelineRow(pipeline: pipeline, selected: selectedID == BackupsPage.objectID(pipeline), now: now) {
                    onOpen(BackupsPage.objectID(pipeline))
                }
                .id(BackupsPage.objectID(pipeline))
            }
        }
        .frame(minWidth: Self.width, alignment: .leading)
    }
}

private struct PipelineRow: View {
    let pipeline: SemaforBackups.Pipeline
    let selected: Bool
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let verdict = BackupVerdict.of(pipeline, now: now)
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    StatusDot(tone: verdict.tone)
                    Text(pipeline.box).font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    Text(pipeline.name).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(1)
                    if let cadence = pipeline.cadence {
                        Text(cadence).font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                .frame(width: 250, alignment: .leading)
                ForEach(BackupPlace.allCases, id: \.self) { place in
                    BackupPlaceCell(place: pipeline.place(place)).frame(width: PipelinesTable.placeWidth, alignment: .leading)
                }
                Text(SemaforTime.date(pipeline.lastOkAt).map { PultikFormat.age(now.timeIntervalSince($0)) } ?? "never")
                    .font(Theme.Typo.figure).foregroundStyle(pipeline.lastOkAt == nil ? Theme.danger : Theme.ink2)
                    .frame(width: 70, alignment: .trailing)
                Text(SemaforTime.date(pipeline.schedule?.nextAt).map { "in \(PultikFormat.age(max(0, $0.timeIntervalSince(now))))" } ?? "—")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background { RowBackground(selected: selected, hovering: hovering) }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension BackupsPage: ModulePage {
    var listWidth: CGFloat { 560 }
    var minListWidth: CGFloat { PipelinesTable.width + 32 }

    var objects: [ModuleObject] {
        pipelines.map { pipeline in
            let verdict = BackupVerdict.of(pipeline, now: now)
            var facts = [ModuleObject.Fact(label: "box", value: pipeline.box)]
            if let cadence = pipeline.cadence { facts.append(.init(label: "cadence", value: cadence)) }
            if let budget = pipeline.maxAgeS, budget > 0 { facts.append(.init(label: "budget", value: PultikFormat.duration(budget))) }
            if let size = pipeline.sizeBytes { facts.append(.init(label: "size", value: PultikFormat.size(size))) }
            if let unit = pipeline.schedule?.unit { facts.append(.init(label: "unit", value: unit)) }
            return ModuleObject(id: Self.objectID(pipeline), title: pipeline.name, label: pipeline.box,
                                status: Chip(verdict.title, verdict == .go ? .ok : verdict == .wait ? .warn : .danger),
                                meta: pipeline.cadence, symbol: "externaldrive", facts: facts)
        }
    }

    /// Each place in full: its freshness, where it lives, the unit that
    /// writes it, whether it is encrypted.
    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let pipeline = store.estatePipelines.first(where: { Self.objectID($0) == object.id }) {
            Tile(kicker: "Places") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(BackupPlace.allCases, id: \.self) { kind in
                        let place = pipeline.place(kind)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(kind.title).microLabel().frame(width: 90, alignment: .leading)
                            BackupPlaceCell(place: place).frame(width: 80, alignment: .leading)
                            Text([place?.location, place?.unit, place?.encrypted == true ? "encrypted" : nil, place?.detail]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
