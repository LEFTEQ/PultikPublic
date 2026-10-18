#if DEBUG
import Canvas
import Foundation
import QuartzCore

/// Synthetic CI history for the engine-only surface (vt-7781 WP5): the panel
/// driver's `timeline-demo` and `timeline-bench` feed it until Semafor's jobs
/// do (WP6). Seeded, so every run draws the same day.
enum TimelineDemo {
    /// Semafor's busiest recorded day: ~2,600 jobs over 40 lanes in five groups.
    static func busiest(now: Date) -> TimelineStage.Feed {
        make(now: now, hours: 24, perLane: 65, lanes: lanes)
    }

    /// A few lanes and an afternoon: enough to pan, pinch and step.
    static func small(now: Date) -> TimelineStage.Feed {
        make(now: now, hours: 6, perLane: 10, lanes: Array(lanes.prefix(6)))
    }

    /// A recorded `/ci/timeline` page (`Tests/Fixtures/semafor/build-server-ci-busiest-day.json`:
    /// 2,876 jobs on 48 lanes) mapped exactly as the CI page maps Semafor's, and its day.
    @MainActor
    static func fixture(_ path: String) throws -> (feed: TimelineStage.Feed, day: ClosedRange<Date>) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let page = try SemaforTime.decoder().decode(CITimelinePage.self, from: data)
        let mapped = CITimelineFeed.feed(jobs: page.jobs, lanes: [], bins: page.bins, width: nil)
        var feed = mapped.feed
        feed.groups = CITimelineFeed.groups(mapped.repoOf, hosted: mapped.hosted)
        return (feed, page.from ... max(page.from, page.to))
    }

    private struct Lane {
        let group, repo, key: String
        let hosted: Bool
    }

    /// Five organisations' lanes, a repository per lane glyph: 12 + 12 + 5 + 6 + 5.
    private static let lanes: [Lane] = {
        let fleet: [(String, [(String, Int)])] = [
            ("exampleapp", [("exampleapp-api", 4), ("exampleapp-web", 3), ("exampleapp-mobile", 3), ("exampleapp-infra", 2)]),
            ("example-org", [("vitrinka", 4), ("assistant-service", 3), ("toolkit", 2), ("hlidac", 1), ("semafor", 1),
                                ("pultik", 1)]),
            ("example", [("example", 3), ("example-engine", 2)]),
            ("booking", [("booking", 3), ("booking-back", 3)]),
        ]
        var out = fleet.flatMap { group, repos in
            repos.flatMap { repo, count in
                (1 ... count).map { Lane(group: group, repo: repo, key: "\(repo)-\($0)", hosted: false) }
            }
        }
        out += [("ubuntu-latest", 3), ("macos-15", 2)].flatMap { image, count in
            (1 ... count).map { Lane(group: "GitHub-hosted", repo: "exampleapp-web", key: "\(image)-\($0)", hosted: true) }
        }
        return out
    }()

    private static let names = ["build", "test", "lint", "typecheck", "e2e", "deploy", "docker", "migrate"]

    private static func make(now: Date, hours: Double, perLane: Int, lanes: [Lane]) -> TimelineStage.Feed {
        var random = SplitMix(seed: 7781)
        let span = hours * 3600
        // Weights that average 1 across every five lanes, so the day keeps its total.
        let weights = [0.6, 1.4, 1.0, 0.8, 1.2]
        var jobs: [TimelineEngine.Job] = []
        for (index, lane) in lanes.enumerated() {
            let count = Int((Double(perLane) * weights[index % weights.count]).rounded())
            for number in 0 ..< count {
                let queued = now.addingTimeInterval(-span + random.unit() * span)
                let wait = random.unit() < 0.7 ? random.unit() * 20 : 20 + random.unit() * 160
                // Log-normal-ish: most jobs a few minutes, a tail to forty.
                let run = min(2400, 30 + exp(random.unit() * 4.2 + 2.8))
                let started = queued.addingTimeInterval(wait)
                let completed = started.addingTimeInterval(run)
                let roll = random.unit()
                let result: TimelineEngine.JobResult
                if started > now {
                    result = .waiting
                } else if completed > now {
                    result = .running
                } else {
                    result = roll < 0.07 ? .failed : roll < 0.10 ? .cancelled : roll < 0.11 ? .unknown : .succeeded
                }
                jobs.append(TimelineEngine.Job(
                    id: "\(lane.key)#\(number)", lane: lane.key, repo: lane.repo,
                    name: names[Int(random.unit() * Double(names.count)) % names.count], queuedAt: queued,
                    startedAt: result == .waiting ? nil : started,
                    completedAt: result == .waiting || result == .running ? nil : completed, result: result,
                    peakMiB: lane.hosted ? nil : UInt32(800 + random.unit() * 3000),
                    reservedMiB: lane.hosted ? nil : 4096
                ))
            }
        }
        var groups: [TimelineEngine.Group] = []
        for lane in lanes {
            let row = TimelineEngine.Row(key: lane.key, label: lane.key, tint: .theme(ProjectGlyph.hue(lane.repo)))
            if groups.last?.key == lane.group {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(TimelineEngine.Group(key: lane.group, label: lane.group, rows: [row]))
            }
        }
        return TimelineStage.Feed(groups: groups, jobs: jobs.sorted { $0.queuedAt < $1.queuedAt })
    }

    /// A small seeded generator (SplitMix64): the same day every run.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func unit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}

/// When `StatusPanelView.body` evaluated (a whole-panel SwiftUI update, a
/// store poll landing), on the display link's clock: the bench tells its
/// slow frames apart from the engine's.
@MainActor
enum PanelBodyLog {
    private(set) static var marks: [CFTimeInterval] = []

    static func mark() {
        marks.append(CACurrentMediaTime())
        if marks.count > 4096 { marks.removeFirst(2048) }
    }

    static func count(in range: ClosedRange<CFTimeInterval>) -> Int {
        marks.count { range.contains($0) }
    }
}

/// `panel-drive.sh timeline-bench` (vt-7781 AC 8): a scripted pan, then a
/// pinch, driven per display frame through the gestures' own entries
/// (`applyScroll`, `applyMagnify`), hands-off. It reports the frame interval
/// (the display link's cadence: 8.33 ms only on a 120 Hz display), the
/// canvas's own cost per frame and the scenes built. It watches the canvas as
/// its frame observer, which the canvas holds weakly: `running` keeps it.
@MainActor
final class TimelineBench: CanvasFrameObserver {
    enum Phase: String, CaseIterable { case pan, pinch }

    /// The bench in flight per canvas, until its report.
    fileprivate static var running: [CanvasSlot: TimelineBench] = [:]

    private struct Samples {
        var intervals: [Double] = []
        var costs: [Double] = []
        var frames = 0
        var builds = 0
        var slow = 0
        var slowWithPanelUpdate = 0
    }

    private let slot: CanvasSlot
    private let seconds: Double
    private let done: ([String: Any]) -> Void
    private var phase = Phase.pan
    private var phaseStart: CFTimeInterval?
    private var last: CFTimeInterval?
    private var samples: [Phase: Samples] = [:]

    init(slot: CanvasSlot, seconds: Double, done: @escaping ([String: Any]) -> Void) {
        self.slot = slot
        self.seconds = seconds
        self.done = done
    }

    /// Before a frame: this frame's share of the scripted gesture.
    func willDraw(_ canvas: CanvasView, at timestamp: CFTimeInterval) {
        let start = phaseStart ?? timestamp
        phaseStart = start
        let dt = last.map { timestamp - $0 } ?? 0
        let t = timestamp - start
        switch phase {
        case .pan:
            // Back and forth each half second: 2,400 pt/s along time, 300 pt/s down the lanes.
            let direction: Double = Int(t / 0.5).isMultiple(of: 2) ? 1 : -1
            canvas.applyScroll(dx: direction * 2400 * dt, dy: direction * 300 * dt)
        case .pinch:
            // In ×16 over the first half, back out over the second.
            let direction: Double = t < seconds / 2 ? 1 : -1
            canvas.applyMagnify(factor: exp(direction * log(16) * dt / (seconds / 2)), x: Double(canvas.bounds.midX))
        }
    }

    /// After a frame: its interval, its cost and whether it built the scene.
    func didDraw(_ canvas: CanvasView, link: CADisplayLink, cost: Double, built: Bool) {
        var sample = samples[phase] ?? Samples()
        if let last {
            let interval = (link.timestamp - last) * 1000
            sample.intervals.append(interval)
            // A slow frame: did a whole-panel SwiftUI update land inside it?
            if interval > 8.34 {
                sample.slow += 1
                if PanelBodyLog.count(in: last ... link.timestamp) > 0 { sample.slowWithPanelUpdate += 1 }
            }
        }
        sample.costs.append(cost)
        sample.frames += 1
        if built { sample.builds += 1 }
        samples[phase] = sample
        last = link.timestamp
        guard let start = phaseStart, link.timestamp - start >= seconds else { return }
        if let next = Phase.allCases.drop(while: { $0 != phase }).dropFirst().first {
            phase = next
            phaseStart = nil
            return
        }
        canvas.observer = nil
        Self.running[slot] = nil
        let screen = canvas.window?.screen
        var report: [String: Any] = [
            "display": screen?.localizedName ?? "",
            "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
            "refreshMs": (link.targetTimestamp - link.timestamp) * 1000,
            "secondsPerPhase": seconds,
            "builds": samples.values.reduce(0) { $0 + $1.builds },
        ]
        for (phase, sample) in samples {
            report[phase.rawValue] = ["frames": sample.frames, "builds": sample.builds,
                                      "interval": Self.stats(sample.intervals), "cost": Self.stats(sample.costs),
                                      "slowFrames": sample.slow, "slowWithPanelUpdate": sample.slowWithPanelUpdate]
        }
        report["all"] = ["interval": Self.stats(samples.values.flatMap(\.intervals)),
                         "cost": Self.stats(samples.values.flatMap(\.costs))]
        report["canvas"] = TimelineStage.shared.debugState(slot)
        done(report)
    }

    private static func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        let pick: (Double) -> Double = { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
        let round: (Double) -> Double = { ($0 * 100).rounded() / 100 }
        return ["p50": round(pick(0.5)), "p95": round(pick(0.95)), "p99": round(pick(0.99)),
                "max": round(sorted.last ?? 0), "over8_33": sorted.filter { $0 > 8.34 }.count]
    }
}

extension CanvasView {
    /// Runs the bench on this canvas, `slot`'s; `done` gets the report, or why it could not run.
    func runBench(_ slot: CanvasSlot, seconds: Double, done: @escaping ([String: Any]) -> Void) {
        guard attached, active else {
            return done(["error": "the canvas is not drawing", "canvas": TimelineStage.shared.debugState(slot)])
        }
        let bench = TimelineBench(slot: slot, seconds: seconds, done: done)
        TimelineBench.running[slot] = bench
        observer = bench
        wake()
    }
}
#endif
