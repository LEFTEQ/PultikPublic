import SwiftUI
import Timeline

/// Estate's and Backups' timelines on Semafor's estate history (vt-7781
/// WP7, vt-7727 D1, D6): every host's window, each box from the Semafor
/// that observes it (`EstateLens`), mapped off the main actor. Like CI's
/// feed (`CITimelineFeed`), the canvas's camera says what to load
/// (`setTimelineVisibility`), the window's `revision` and the estate's boxes
/// say when to feed again, and the playhead's throttled instants become
/// `/estate/map?at=` or `/estate/backups?at=` reads (`replayTimeline`). An
/// item whose Semafor word the engine does not know is never drawn: it is
/// logged once per new word and counted on the page.
@MainActor
final class EstateTimelineFeed {
    static let estate = EstateTimelineFeed(slot: .estateTimeline, lens: .estate)
    static let backups = EstateTimelineFeed(slot: .backupsTimeline, lens: .backups)

    let slot: CanvasSlot
    let lens: TimelineLens
    private weak var store: StatusStore?
    private var shown = false
    private var wanted: TimelineStage.Wanted?
    /// The inputs of the last feed, so a body re-render that changed none feeds nothing.
    private var fedKey: Trigger?
    private var mapping: Task<Void, Never>?
    private var logged: [String: Int] = [:]

    private init(slot: CanvasSlot, lens: TimelineLens) {
        (self.slot, self.lens) = (slot, lens)
    }

    /// What a new feed depends on: the windows, which Semafor observes which
    /// box (D6) and, for Backups, the live pipelines that are its rows.
    struct Trigger: Equatable {
        let revision: UInt64
        let owners: [String]
        let rows: [String]

        @MainActor init(store: StatusStore, lens: TimelineLens) {
            revision = store.timelinePages.revision
            owners = store.estateBoxes.map { "\($0.host)/\($0.box.name)" }
            rows = lens == .backups ? store.estatePipelines.map { EstateLens.backupRow(box: $0.box, surface: $0.name) } : []
        }
    }

    /// The page installs it; installing again is free.
    func install(_ store: StatusStore) {
        guard self.store !== store else { return }
        self.store = store
        let lens = lens
        TimelineStage.shared.install(TimelineStage.Hooks(
            shown: { [weak self] in self?.setShown($0) },
            wanted: { [weak self] in self?.setWanted($0) },
            replay: { [weak store] instant in
                guard let store else { return }
                Task { await store.replayTimeline(lens, at: instant) }
            }
        ), for: slot)
    }

    private func setShown(_ shown: Bool) {
        self.shown = shown
        guard let store else { return }
        if shown {
            if let wanted { setWanted(wanted) }
        } else if store.timelineVisibility?.lens == lens {
            // Hidden or another view: the 1 h edge stops (AC 10).
            store.setTimelineVisibility(nil)
        }
    }

    private func setWanted(_ wanted: TimelineStage.Wanted) {
        self.wanted = wanted
        guard shown, let store else { return }
        // Rust picks the bins' width; marks stay while Semafor's policy still draws them (the crossfade).
        let policy = TimelineDensity.of(lens, span: wanted.span)
        let density = TimelineDensity(raw: wanted.bucket == nil || policy.raw, bucketS: wanted.bucket.map { Int($0) })
        store.setTimelineVisibility(TimelineVisibility(lens: lens, range: wanted.range, density: density))
    }

    /// The windows or the estate's boxes changed: map them off the main actor and hand them to the engine.
    func refeed() {
        guard let store else { return }
        let key = Trigger(store: store, lens: lens)
        guard key != fedKey else { return }
        fedKey = key
        let observed = Dictionary(store.estateBoxes.map { ($0.box.name, $0.host) }, uniquingKeysWith: { first, _ in first })
        let boxOrder = store.estateBoxes.map(\.box.name)
        let pipelines = lens == .backups ? store.estatePipelines.map { (box: $0.box, name: $0.name) } : []
        let sources = store.timelineKeys(lens).map { EstateLensSource(host: $0.host, window: store.timelineWindow($0)) }
        let (lens, slot) = (lens, slot)
        mapping?.cancel()
        mapping = Task {
            let feed = await Task.detached(priority: .userInitiated) {
                EstateLens.feed(lens, sources: sources, observed: observed, boxOrder: boxOrder, pipelines: pipelines)
            }.value
            guard !Task.isCancelled else { return }
            self.log(feed.unknown)
            TimelineStage.shared.feed(slot, TimelineStage.Feed(estate: feed))
        }
    }

    /// A word the engine does not know is logged when it first appears (or its count grows), not every 10 s.
    private func log(_ unknown: [String: Int]) {
        let grown = unknown.filter { (logged[$0.key] ?? 0) < $0.value }
        logged = unknown
        guard !grown.isEmpty else { return }
        let words = grown.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        NSLog("pultik: %@ timeline skipped items with words the engine does not know: %@", lens.rawValue, words)
    }
}

/// A timeline's summary line: its events and lanes, what failed, and the
/// items Semafor sent in words the engine does not know (counted, never drawn).
enum EstateTimelineSummary {
    static func line(_ summary: TimelineStage.Summary, lanes noun: String) -> String {
        guard summary.jobs > 0 || summary.unknown > 0 else { return "no events read yet" }
        var parts = ["\(PultikFormat.count(Double(summary.jobs))) events", "\(summary.lanes) \(noun)"]
        if summary.running > 0 { parts.append("\(summary.running) live") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// "3 not drawn: kind 'x'" while Semafor sends a word the engine does not know.
    static func unknown(_ summary: TimelineStage.Summary) -> String? {
        guard summary.unknown > 0 else { return nil }
        return "\(summary.unknown) not drawn · unknown \(summary.unknownWords.joined(separator: ", "))"
    }
}

// MARK: - Above the Estate Timeline: the boxes at the playhead

/// Above Estate's Timeline (Semafor's map strip, D10 B): every box and its
/// apps as they were at the playhead — live it is now, dragged back it is
/// `/estate/map?at=` of the box's own Semafor — and the feed's trigger, so
/// only this strip redraws when a page lands.
struct EstateTimelineStrip: View {
    let store: StatusStore

    var body: some View {
        let replay = store.timelineReplay.flatMap { $0.lens == .estate ? $0 : nil }
        VStack(alignment: .leading, spacing: 6) {
            if let replay {
                HStack(spacing: 8) {
                    Chip("replay \(PultikFormat.clock(replay.at))", .warn, symbol: "clock.arrow.circlepath")
                    Text("the boxes as they stood at the playhead · N returns to now")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            }
            if store.estateBoxes.isEmpty {
                RailNote("No boxes read yet — Semafor answers while Estate is open")
            } else {
                FlowRow(hSpacing: 8, vSpacing: 8) {
                    ForEach(store.estateBoxes, id: \.box.name) { owned in
                        if let replay {
                            if let box = replay.maps[owned.host]?.boxList.first(where: { $0.name == owned.box.name }) {
                                EstateBoxCard(box: box, at: replay.at, last: lastRollout(owned, before: replay.at))
                            } else {
                                EstateBoxCard.unavailable(owned.box.name)
                            }
                        } else {
                            EstateBoxCard(box: owned.box, at: nil, last: lastRollout(owned, before: nil))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .onAppear { EstateTimelineFeed.estate.install(store) }
        .onChange(of: EstateTimelineFeed.Trigger(store: store, lens: .estate), initial: true) {
            EstateTimelineFeed.estate.refeed()
        }
    }

    /// The box's newest finished rollout at or before `instant` (now: nil) in the loaded history.
    private func lastRollout(_ owned: (host: String, box: SemaforEstateMap.Box), before instant: Date?) -> EstateTimelineEvent? {
        let events = store.timelineWindow(TimelineKey(host: owned.host, lens: .estate))?.events ?? []
        let limit = instant ?? .distantFuture
        return events.last { event in
            event.box == owned.box.name && event.row == "rollouts" && !event.isScheduled && !event.isLive && event.at <= limit
        }
    }
}

/// One box at the playhead: its reconciler state, the commit it runs (and
/// how far `origin/main` is ahead), the pin, the live rollout or the last
/// one, and its apps that are not synced.
private struct EstateBoxCard: View {
    let box: SemaforEstateMap.Box
    /// The replayed instant; nil: live.
    let at: Date?
    let last: EstateTimelineEvent?

    static func unavailable(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(tone: Theme.ink3, style: .ring)
                Text(name).font(Theme.Typo.title).foregroundStyle(Theme.ink)
            }
            Text("unavailable at the playhead — the replay did not load")
                .font(Theme.Typo.meta).foregroundStyle(Theme.warn).lineLimit(2)
        }
        .modifier(EstateCardChrome())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(tone: Self.tone(box.sync), style: box.sync == "rolling" ? .pulse : box.sync == "unreachable" ? .ring : .solid)
                Text(box.name).font(Theme.Typo.title).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text((box.sync ?? "unknown").uppercased()).microLabel(Self.tone(box.sync))
            }
            commitLine
            stateLine
            // The count leads; the names after it truncate.
            Text("\(Text(appCount).foregroundStyle(attention.isEmpty ? Theme.ink3 : Theme.warn))\(Text(appNames).foregroundStyle(Theme.ink2))")
                .font(Theme.Typo.meta).lineLimit(1)
        }
        .modifier(EstateCardChrome())
    }

    private var attention: [SemaforEstateMap.App] {
        box.appList.filter { $0.sync != "synced" && $0.sync != "elsewhere" }
    }

    private var appCount: String {
        "\(box.appList.count) apps" + (attention.isEmpty ? "" : " · \(attention.count) need a look")
    }

    private var appNames: String {
        attention.isEmpty ? "" : ": " + attention.map(\.name).joined(separator: ", ")
    }

    private var commitLine: some View {
        HStack(spacing: 6) {
            Text(box.applied?.sha ?? "no commit").font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
            if let ahead = box.ahead, ahead > 0 {
                Text("\(ahead) ahead").font(Theme.Typo.meta).foregroundStyle(Theme.warn)
            }
            Text(EstateMapping.subject(box.applied) ?? "").font(Theme.Typo.meta).foregroundStyle(Theme.ink3).lineLimit(1)
        }
    }

    @ViewBuilder private var stateLine: some View {
        if let pin = box.pin {
            Text("pinned to \(pin.sha ?? "?")\(pin.reason.map { " · \($0)" } ?? "")")
                .font(Theme.Typo.meta).foregroundStyle(Theme.warn).lineLimit(1)
        } else if let live = box.liveRollouts?.first {
            HStack(spacing: 5) {
                StatusDot(tone: Theme.ok, style: at == nil ? .pulse : .solid)
                Text([live.title ?? live.kind ?? "rollout", live.stage.map { "\($0)…" }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            }
        } else if let last {
            Text("last \(PultikFormat.ago(last.at, now: at ?? Date())) · \(last.title) \(Self.glyph(last.result))")
                .font(Theme.Typo.meta).foregroundStyle(last.result == "fail" ? Theme.danger : Theme.ink3).lineLimit(1)
        } else {
            Text("no rollouts in loaded history").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
        }
    }

    /// A box's reconciler state (D4: running reads `ok`, a hold or pin needs you).
    static func tone(_ sync: String?) -> Color {
        switch sync {
        case "synced", "rolling": Theme.ok
        case "pending", "held", "pinned", "seeded": Theme.warn
        case "errors": Theme.danger
        default: Theme.ink3
        }
    }

    static func glyph(_ result: String) -> String {
        switch result {
        case "ok": "✓"
        case "fail", "missed": "✕"
        case "rollback": "↺"
        default: ""
        }
    }
}

private struct EstateCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(width: 250, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(alignment: .top) { TopHighlight(radius: Theme.Radius.tile) }
    }
}

// MARK: - A mark's card

/// A mark on the Estate or Backups timeline (vt-7727 D5): the event as
/// Semafor recorded it — or, for a timer's repeat (`box|unit@k`), the run
/// it will make — read from the loaded windows.
struct EstateEventCard: View {
    let store: StatusStore
    let lens: TimelineLens
    let mark: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let event = event {
                header(event.title, sub: event.subtitle, tone: Self.tone(event.result), live: event.isLive)
                facts(Self.facts(event))
            } else if let run = repeatRun {
                header(run.schedule.unit, sub: "scheduled", tone: Theme.ink3, live: false)
                facts(Self.facts(run.schedule, at: run.at))
            } else {
                RailNote("This mark is no longer loaded")
            }
        }
        .padding(14)
    }

    private var windows: [TimelineWindow] {
        store.timelineKeys(lens).compactMap { store.timelineWindow($0) }
    }

    private var event: EstateTimelineEvent? {
        for window in windows {
            if let event = window.events.first(where: { $0.id == mark }) { return event }
        }
        return nil
    }

    /// A timer's repeat `box|unit@k`: its schedule and when that run is due.
    private var repeatRun: (schedule: EstateTimelineSchedule, at: Date)? {
        guard let at = mark.lastIndex(of: "@"), let k = Double(mark[mark.index(after: at)...]) else { return nil }
        let key = mark[..<at]
        for window in windows {
            if let schedule = window.schedules.first(where: { "\($0.box)|\($0.unit)" == key }) {
                return (schedule, schedule.nextAt.addingTimeInterval(k * TimeInterval(schedule.periodS)))
            }
        }
        return nil
    }

    private func header(_ title: String, sub: String?, tone: Color, live: Bool) -> some View {
        HStack(spacing: 8) {
            StatusDot(tone: tone, style: live ? .pulse : .solid)
            Text(title).font(Theme.Typo.detailTitle).foregroundStyle(Theme.ink).lineLimit(1)
            if let sub { Text(sub).font(Theme.Typo.body).foregroundStyle(Theme.ink2).lineLimit(1) }
            Spacer(minLength: 8)
            KbdHint("esc")
        }
    }

    private func facts(_ facts: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(facts, id: \.0) { fact in
                GridRow {
                    Text(fact.0).microLabel()
                    Text(fact.1).font(Theme.Typo.figure).foregroundStyle(Theme.ink2).textSelection(.enabled).lineLimit(3)
                }
            }
        }
        .kitTile()
    }

    static func facts(_ event: EstateTimelineEvent) -> [(String, String)] {
        var facts: [(String, String)] = [("result", event.result), ("box", event.box), ("kind", event.kind),
                                          ("at", PultikFormat.clock(event.at))]
        if let duration = event.durationS { facts.append(("took", PultikFormat.duration(duration))) }
        if let size = event.sizeBytes { facts.append(("size", PultikFormat.size(Double(size)))) }
        let optional: [(String, String?)] = [("app", event.app), ("commit", event.sha), ("repo", event.repo),
                                             ("backup", event.surface), ("pipeline", event.pipeline), ("stage", event.stage),
                                             ("where", event.location), ("note", event.note), ("command", event.command)]
        facts += optional.compactMap { label, value in value.map { (label, $0) } }
        facts.append(("id", event.id))
        return facts
    }

    static func facts(_ schedule: EstateTimelineSchedule, at: Date) -> [(String, String)] {
        [("box", schedule.box), ("runs", PultikFormat.clock(at)), ("every", PultikFormat.duration(TimeInterval(schedule.periodS))),
         ("kind", schedule.kind)] + (schedule.surface.map { [("backup", $0)] } ?? [])
    }

    static func tone(_ result: String) -> Color {
        switch result {
        case "ok", "live": Theme.ok
        case "fail", "missed": Theme.danger
        case "rollback": Theme.warn
        default: Theme.ink3
        }
    }
}
