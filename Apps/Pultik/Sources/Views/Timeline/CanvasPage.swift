import Canvas
import SwiftUI

/// A module's canvas view (vt-7727 D1, D5): CI's and Estate's Timeline and
/// Estate's Map. The header carries the module's views and the canvas's
/// keys; the canvas fills the body, ringed in the accent while entered, and
/// a mark's card slides over it. Its list has no rows, so ↑/↓ walk nothing
/// and ↵ enters the canvas.
struct CanvasPage: View {
    let store: StatusStore
    let module: PanelModule
    let slot: CanvasSlot
    let view: ModuleView?
    /// The canvas's module is the one displayed (a warm hidden body draws nothing).
    var active = false
    var entered = false
    var stack: [DetailRef] = []
    var onView: (ModuleView) -> Void = { _ in }
    var onPop: () -> Void = {}
    var card: (DetailRef) -> AnyView = { _ in AnyView(EmptyView()) }

    private var summary: TimelineStage.Summary {
        TimelineStage.shared.summaries[slot] ?? .init()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // Above each canvas what its playhead replays (vt-7727 D1): CI's pool card, the
            // estate's box cards; the map's feed and refusal line.
            switch slot {
            case .ciTimeline: CITimelineStrip(store: store)
            case .estateTimeline: EstateTimelineStrip(store: store)
            case .estateMap: EstateMapStrip(store: store)
            case .backupsTimeline: EmptyView()
            }
            if let unknown = EstateTimelineSummary.unknown(summary) {
                Text(unknown).font(Theme.Typo.meta).foregroundStyle(Theme.warn).padding(.horizontal, 8)
            }
            keys
            StackedDetail(stack: stack, onPop: onPop) {
                canvas
            } card: { ref in
                card(ref)
            }
            .padding([.horizontal, .bottom], 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var header: some View {
        if module == .ci {
            CIViewHeader(store: store, view: view, onView: onView, summary: summaryLine)
        } else {
            HStack(alignment: .center, spacing: 10) {
                Text(module.title).font(Theme.Typo.title)
                ViewBar(views: module.views, selected: view, onSelect: onView)
                Text(summaryLine).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
        }
    }

    private var summaryLine: String {
        switch slot {
        case .estateMap: return EstateMapStrip.summary(store)
        case .estateTimeline: return EstateTimelineSummary.line(summary, lanes: "boxes")
        case .backupsTimeline: return EstateTimelineSummary.line(summary, lanes: "backups")
        case .ciTimeline: break
        }
        let summary = summary
        guard summary.jobs > 0 else { return "no jobs read yet" }
        var parts = ["\(PultikFormat.count(Double(summary.jobs))) jobs", "\(summary.lanes) lanes"]
        if summary.running > 0 { parts.append("\(summary.running) running") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: " · ")
    }

    private var keys: some View {
        CanvasKeys(slot: slot, entered: entered)
            .padding(.horizontal, 8)
    }

    private var canvas: some View {
        TimelineCanvas(slot: slot, active: active)
            // Estate's Timeline → Map is the same page type: without its own
            // identity the canvas would keep the first slot's view and engine.
            .id(slot)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .focusRing(entered, radius: Theme.Radius.tile)
            // The Map reads its topology and live map on entering, never polled (D10).
            .task(id: slot == .estateMap && active) {
                if slot == .estateMap, active { await store.enterEstateMap() }
            }
    }
}

/// A canvas's keys (vt-7727 D5): ↵ to enter, then its own. The map's
/// arrows walk its cards and N fits it whole; a timeline's step outcomes
/// and N returns to now.
struct CanvasKeys: View {
    let slot: CanvasSlot
    let entered: Bool

    var body: some View {
        let map = slot == .estateMap
        HStack(spacing: 6) {
            if entered {
                hint(map ? "← → ↑ ↓" : "← →", map ? "cards" : "outcomes")
                if !map { hint("⇧← →", "every mark") }
                hint("⌥← →", "pan")
                hint("− =", "zoom")
                hint("N", map ? "fit" : "now")
                hint("↵", map ? "app card" : "card")
                hint("esc", "leave")
            } else {
                hint("↵", slot == .backupsTimeline ? "enter (no row selected)" : "enter")
                Text(map ? "pinch to zoom · two fingers to pan · click a card"
                    : "pinch to zoom · two fingers to pan · drag the axis to replay")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KbdHint(keys)
            Text(label).font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
        }
    }
}

extension CanvasPage: ModulePage {
    /// The canvas has no rows: the keys enter it instead.
    var objects: [ModuleObject] { [] }
}

/// A mark's card over the entered canvas (vt-7727 D5): a CI job as the feed
/// holds it (a job with a run opens `RunCard` instead), an estate or backup
/// event (`EstateEventCard`), or the map's app or node (`EstateMapCard`).
struct MarkCard: View {
    let store: StatusStore
    let ref: DetailRef

    var body: some View {
        switch CanvasSlot.mark(of: ref) {
        case let (.estateTimeline, mark)?: EstateEventCard(store: store, lens: .estate, mark: mark)
        case let (.backupsTimeline, mark)?: EstateEventCard(store: store, lens: .backups, mark: mark)
        case let (.estateMap, card)?: EstateMapCard(store: store, card: card)
        default: jobCard
        }
    }

    private var jobCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let named = CanvasSlot.mark(of: ref), let job = TimelineStage.shared.job(named.slot, named.mark) {
                header(job)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(facts(job), id: \.label) { fact in
                        GridRow {
                            Text(fact.label).microLabel()
                            Text(fact.value).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).textSelection(.enabled)
                        }
                    }
                }
                .kitTile()
            } else {
                RailNote("This mark is no longer loaded")
            }
        }
        .padding(14)
    }

    private func header(_ job: TimelineEngine.Job) -> some View {
        HStack(spacing: 8) {
            StatusDot(tone: tone(job.result), style: job.result == .running ? .pulse : job.result == .cancelled ? .ring : .solid)
            Text(job.name).font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
            Text(job.repo).font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 8)
            KbdHint("esc")
        }
    }

    private func facts(_ job: TimelineEngine.Job) -> [(label: String, value: String)] {
        let now = Date()
        var facts: [(label: String, value: String)] = [("result", "\(job.result)"), ("lane", job.lane),
                                                        ("queued", PultikFormat.clock(job.queuedAt))]
        if let started = job.startedAt {
            facts.append(("waited", PultikFormat.duration(started.timeIntervalSince(job.queuedAt))))
            facts.append(("ran", PultikFormat.duration((job.completedAt ?? now).timeIntervalSince(started))))
        }
        if let completed = job.completedAt { facts.append(("finished", PultikFormat.clock(completed))) }
        if let peak = job.peakMiB { facts.append(("peak", "\(peak) MiB")) }
        if let reserved = job.reservedMiB { facts.append(("reserved", "\(reserved) MiB")) }
        facts.append(("id", job.id))
        return facts
    }

    private func tone(_ result: TimelineEngine.JobResult) -> Color {
        switch result {
        case .failed: Theme.danger
        case .running, .succeeded: Theme.ok
        case .waiting: Theme.warn
        case .cancelled, .unknown: Theme.ink3
        }
    }
}
