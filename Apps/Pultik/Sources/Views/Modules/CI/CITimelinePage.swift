import Canvas
import SwiftUI

/// CI's Timeline on Semafor's jobs (vt-7781 WP6, vt-7727 D1, D6, D14): the
/// chip host's fleet lanes by organisation and the GitHub-hosted lanes once,
/// from the Semafor listing more of them (`StatusStore.ciTimelineJobs`).
/// The canvas's camera says what to load (`setTimelineVisibility`), the
/// window's `revision` says when to feed it again, and the playhead's
/// throttled instants become `/ci/at` reads (`replayTimeline`). Nothing here
/// runs per frame on SwiftUI state: the stage's hooks are plain calls.
@MainActor
final class CITimelineFeed {
    static let shared = CITimelineFeed()

    private weak var store: StatusStore?
    private var shown = false
    private var wanted: TimelineStage.Wanted?
    /// The inputs of the last feed, so a body re-render that changed none feeds nothing.
    private var fedKey: FeedKey?
    private var mapping: Task<Void, Never>?

    private struct FeedKey: Equatable {
        let revision: UInt64
        let host: String?
        let hosted: String?
        let lanes: Int
    }

    /// The CI page installs it; installing again is free.
    func install(_ store: StatusStore) {
        guard self.store !== store else { return }
        self.store = store
        TimelineStage.shared.install(TimelineStage.Hooks(
            shown: { [weak self] in self?.setShown($0) },
            wanted: { [weak self] in self?.setWanted($0) },
            replay: { [weak store] instant in
                guard let store else { return }
                Task { await store.replayTimeline(.ci, at: instant) }
            }
        ), for: .ciTimeline)
    }

    private func setShown(_ shown: Bool) {
        self.shown = shown
        guard let store else { return }
        if shown {
            if let wanted { setWanted(wanted) }
        } else if store.timelineVisibility?.lens == .ci {
            // Hidden or another view: the 1 h edge stops (AC 10) — unless another timeline
            // (Estate's, Backups') already took the visibility as this one went.
            store.setTimelineVisibility(nil)
        }
    }

    private func setWanted(_ wanted: TimelineStage.Wanted) {
        self.wanted = wanted
        guard shown, let store else { return }
        // Rust picks the bins' width; marks stay while Semafor's policy still draws them (the crossfade).
        let policy = TimelineDensity.of(.ci, span: wanted.span)
        let density = TimelineDensity(raw: wanted.bucket == nil || policy.raw, bucketS: wanted.bucket.map { Int($0) })
        store.setTimelineVisibility(TimelineVisibility(lens: .ci, range: wanted.range, density: density))
    }

    /// The window changed (its `revision`, the chip or the lanes): map it off
    /// the main actor and hand it to the engine.
    func refeed() {
        guard let store else { return }
        let host = store.ciSemaforHost
        let hosted = SemaforCI.hostedSource(store.semaforStates)
        let lanes = (host.flatMap { store.semaforHosts[$0]?.lanes } ?? []).filter { !$0.isHosted }
            + (hosted.flatMap { store.semaforHosts[$0]?.lanes } ?? []).filter(\.isHosted)
        let key = FeedKey(revision: store.timelinePages.revision, host: host, hosted: hosted, lanes: lanes.count)
        guard key != fedKey else { return }
        fedKey = key
        // `ciTimelineJobs`' merge, off the main actor: thousands of jobs sorted every 10 s would
        // cost a frame mid-gesture (D14: the chip's fleet jobs, the hosted source's hosted ones).
        let window = host.flatMap { store.timelineWindow(TimelineKey(host: $0, lens: .ci)) }
        let fleet = window?.jobs ?? []
        let hostedJobs = hosted.flatMap { store.timelineWindow(TimelineKey(host: $0, lens: .ci)) }?.jobs ?? fleet
        let bins = window?.ciBins ?? []
        let width = window?.bucketS.map(TimeInterval.init)
        mapping?.cancel()
        mapping = Task {
            let mapped = await Task.detached(priority: .userInitiated) {
                Self.feed(jobs: SemaforCI.timelineJobs(fleet: fleet, hosted: hostedJobs), lanes: lanes, bins: bins,
                          width: width)
            }.value
            guard !Task.isCancelled else { return }
            var feed = mapped.feed
            feed.groups = Self.groups(mapped.repoOf, hosted: mapped.hosted)
            TimelineStage.shared.feed(.ciTimeline, feed)
        }
    }

    /// Semafor's jobs as the engine takes them, and each lane's repository
    /// and whether it is GitHub-hosted (the rows, `groups`). A job's card is
    /// its run's (`RunCard`).
    nonisolated static func feed(jobs: [CITimelineJob], lanes: [SemaforCILane], bins: [CITimelineBin],
                                 width: TimeInterval?) -> (feed: TimelineStage.Feed, repoOf: [String: String], hosted: Set<String>)
    {
        var repoOf: [String: String] = [:]
        var hostedLanes: Set<String> = []
        for lane in lanes {
            repoOf[lane.lane] = lane.repo ?? repoOf[lane.lane] ?? ""
            if lane.isHosted { hostedLanes.insert(lane.lane) }
        }
        var feed = TimelineStage.Feed()
        feed.jobs.reserveCapacity(jobs.count)
        for job in jobs {
            if (repoOf[job.lane] ?? "").isEmpty { repoOf[job.lane] = job.repo }
            if job.hosted { hostedLanes.insert(job.lane) }
            feed.jobs.append(TimelineEngine.Job(
                id: job.id, lane: job.lane, repo: job.repo, name: job.name ?? job.jobId, queuedAt: job.queuedAt,
                startedAt: job.startedAt, completedAt: job.completedAt, result: result(job.result),
                peakMiB: job.peakMib.map { UInt32(clamping: $0) }, reservedMiB: job.reservedMib.map { UInt32(clamping: $0) }
            ))
            if job.runId > 0 {
                feed.cards[job.id] = DetailRef(kind: .run, id: CIRunRef(repo: job.repo, runID: Int(job.runId)).key)
            }
        }
        if let width {
            feed.bins = bins.map { bin in
                TimelineEngine.Bin(row: bin.lane, from: bin.from, width: width, count: UInt32(clamping: bin.count),
                                   failures: UInt32(clamping: bin.failures))
            }
        }
        return (feed, repoOf, hostedLanes)
    }

    /// Rows are lanes, grouped by the organisation of the lane's repository,
    /// the GitHub-hosted lanes once in their own group, last (D14); a lane's
    /// glyph is tinted by its repository.
    static func groups(_ repoOf: [String: String], hosted: Set<String>) -> [TimelineEngine.Group] {
        let hostedGroup = "GitHub-hosted"
        var byGroup: [String: [String]] = [:]
        for (lane, repo) in repoOf {
            let org = repo.split(separator: "/").first.map(String.init) ?? ""
            byGroup[hosted.contains(lane) ? hostedGroup : org.isEmpty ? "other" : org, default: []].append(lane)
        }
        let order = byGroup.keys.sorted { a, b in
            (a == hostedGroup ? 1 : 0, a.lowercased()) < (b == hostedGroup ? 1 : 0, b.lowercased())
        }
        return order.map { group in
            TimelineEngine.Group(key: group, label: group, rows: (byGroup[group] ?? []).sorted().map { lane in
                let name = repoOf[lane]?.split(separator: "/").last.map(String.init) ?? lane
                return TimelineEngine.Row(key: lane, label: lane, tint: .theme(ProjectGlyph.hue(name)))
            })
        }
    }

    /// Semafor's result words (D4: colour means status).
    nonisolated static func result(_ word: String) -> TimelineEngine.JobResult {
        switch word {
        case "succeeded", "success": .succeeded
        case "failed", "failure": .failed
        case "cancelled", "canceled", "skipped": .cancelled
        case "running": .running
        case "waiting", "queued": .waiting
        default: .unknown
        }
    }
}

/// Above CI's Timeline (vt-7727 D1): the chip host's pool card, or what the
/// playhead replays there (`/ci/at`), and the feed's trigger — the window's
/// `revision`, read here and not by the canvas, so only this strip redraws
/// when a page lands.
struct CITimelineStrip: View {
    let store: StatusStore

    var body: some View {
        let host = store.ciSemaforHost
        HStack(alignment: .center, spacing: 10) {
            if let host {
                Text(store.servers.first { $0.ref == host }?.name ?? host).microLabel()
                if let replay = store.timelineReplay, replay.lens == .ci, let at = replay.ci[host] {
                    ReplayPoolLine(at: at)
                } else if let pool = store.laneBoard.pools[host] {
                    PoolRow(pool: pool).frame(maxWidth: 420, alignment: .leading)
                } else {
                    Text("No pool read yet").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .onAppear { CITimelineFeed.shared.install(store) }
        .onChange(of: FeedTrigger(store: store), initial: true) { CITimelineFeed.shared.refeed() }
    }

    /// What a new feed depends on, as the strip observes it.
    private struct FeedTrigger: Equatable {
        let revision: UInt64
        let host: String?
        let lanes: Int

        @MainActor init(store: StatusStore) {
            revision = store.timelinePages.revision
            host = store.ciSemaforHost
            lanes = store.semaforHosts.values.reduce(0) { $0 + ($1.lanes?.count ?? 0) }
        }
    }
}

/// The pool as the playhead replays it: that instant's running and waiting
/// jobs and reserved memory on the chip host, one host's figures.
private struct ReplayPoolLine: View {
    let at: SemaforCIAt

    var body: some View {
        let running = at.lanes.reduce(0) { $0 + $1.running }
        let waiting = at.lanes.reduce(0) { $0 + $1.waiting }
        let reserved = at.lanes.reduce(0) { $0 + $1.reservedMib }
        HStack(spacing: 8) {
            Chip("replay \(PultikFormat.clock(at.at))", .warn)
            Text("\(running) running · \(waiting) waiting · \(PultikFormat.size(Double(reserved) * 1_048_576)) reserved")
                .font(Theme.Typo.figure).foregroundStyle(Theme.ink2)
        }
    }
}
