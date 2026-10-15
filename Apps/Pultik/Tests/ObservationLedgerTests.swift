import XCTest
@testable import Pultik

/// The Now observation ledger (copilot shell D14): first-observed onsets and
/// the Handled section, cleared only by complete reads.
final class ObservationLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let github = NowSource(feed: .githubStalePRs, identity: "github.com/example")

    private func need(_ id: String, onset: NowOnset? = nil) -> NowNeed {
        NowNeed(needID: id, incidentKey: id, kind: .stalePR, lane: .drifting, severity: .normal,
                onset: onset ?? .exact(t0), title: id, verb: .open("Inspect PR"),
                target: NowTarget(module: .prs, objectID: id))
    }

    private func read(_ ids: [String], _ coverage: NowCoverage = .complete, source: NowSource? = nil,
                      finished: [String: Date] = [:], observedAt: Date? = nil) -> NowRead {
        NowRead(source: source ?? github, coverage: coverage,
                needs: ids.map { need($0, onset: observedAt.map(NowOnset.observed)) }, finished: finished)
    }

    private func minutes(_ count: Double) -> Date { t0.addingTimeInterval(count * 60) }

    /// AC4: a complete read that no longer lists a need moves it to Handled
    /// at that poll — or at the source's terminal instant when given; a need
    /// that returns starts a new episode.
    func testCompleteReadMovesAGoneNeedToHandledWithItsClearedTime() throws {
        var ledger = ObservationLedger()
        _ = ledger.record(read(["pr:1", "pr:2", "pr:3"]), now: t0)
        let active = ledger.record(read(["pr:1"], finished: ["pr:3": minutes(4)]), now: minutes(5))

        XCTAssertEqual(active.map(\.needID), ["pr:1"])
        let handled = ledger.handled(now: minutes(5))
        XCTAssertEqual(handled.map(\.need.needID), ["pr:2", "pr:3"])
        XCTAssertEqual(handled.map(\.clearedAt), [minutes(5), minutes(4)])
        XCTAssertEqual(handled.map(\.clearedBy), [.noLongerObserved, .source])

        let back = ledger.record(read(["pr:1", "pr:2"]), now: minutes(9))
        XCTAssertEqual(back.map(\.episodeID), ["pr:1#1", "pr:2#2"])
        XCTAssertEqual(ledger.handled(now: minutes(9)).map(\.need.needID), ["pr:3"])
    }

    /// AC4: a failed or truncated read never finishes anything.
    func testFailedOrPartialReadNeverClears() {
        var ledger = ObservationLedger()
        _ = ledger.record(read(["pr:1", "pr:2"]), now: t0)
        _ = ledger.record(read(["pr:2"], .partial), now: minutes(1))
        _ = ledger.record(read([], .failed), now: minutes(2))
        XCTAssertTrue(ledger.handled(now: minutes(2)).isEmpty)

        _ = ledger.record(read(["pr:2"]), now: minutes(3))
        XCTAssertEqual(ledger.handled(now: minutes(3)).map(\.need.needID), ["pr:1"])
    }

    /// AC4: past 24 h an entry is forgotten; past the cap, cleared entries
    /// go first, then the least recently seen.
    func testEntriesPastTheWindowOrTheCapEvict() {
        var ledger = ObservationLedger(cap: 3)
        _ = ledger.record(read(["pr:1", "pr:2"]), now: t0)
        _ = ledger.record(read(["pr:1"]), now: minutes(1))
        XCTAssertEqual(ledger.handled(now: minutes(1)).count, 1)
        XCTAssertTrue(ledger.handled(now: minutes(1 + 24 * 60 + 1)).isEmpty)

        _ = ledger.record(read(["pr:1", "pr:3", "pr:4"]), now: minutes(2))
        XCTAssertEqual(Set(ledger.entries.values.map(\.need.needID)), ["pr:1", "pr:3", "pr:4"])

        _ = ledger.record(read(["pr:9"], .partial), now: minutes(24 * 60 + 3))
        XCTAssertEqual(ledger.entries.values.map(\.need.needID), ["pr:9"])
    }

    /// A hollow first-observed onset survives a relaunch; a corrupt file
    /// starts empty instead of failing.
    func testObservedOnsetSurvivesReloadFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "now-ledger-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(ObservationLedger.load(from: directory).entries.isEmpty)

        var ledger = ObservationLedger()
        _ = ledger.record(read(["pr:1"], observedAt: t0), now: t0)
        try ledger.save(to: directory)

        var reloaded = ObservationLedger.load(from: directory)
        XCTAssertEqual(reloaded, ledger)
        let again = reloaded.record(read(["pr:1"], observedAt: minutes(30)), now: minutes(30))
        XCTAssertEqual(again.first?.onset, .observed(t0))
        XCTAssertEqual(again.first?.episodeID, "pr:1#1")

        try Data("{not json".utf8).write(to: directory.appending(path: ObservationLedger.fileName))
        XCTAssertTrue(ObservationLedger.load(from: directory).entries.isEmpty)
    }

    /// One account's complete read never clears or re-dates another's need,
    /// even under the same need id.
    func testIdentitiesNeverMix() {
        let other = NowSource(feed: .githubStalePRs, identity: "github.com/someone-else")
        var ledger = ObservationLedger()
        _ = ledger.record(read(["pr:1"], observedAt: t0), now: t0)
        _ = ledger.record(read([], source: other), now: minutes(1))
        XCTAssertTrue(ledger.handled(now: minutes(1)).isEmpty)

        let theirs = ledger.record(read(["pr:1"], source: other, observedAt: minutes(2)), now: minutes(2))
        XCTAssertEqual(theirs.first?.onset, .observed(minutes(2)))
        XCTAssertEqual(ledger.entries.count, 2)
    }

    /// A partial read leaves what it could not see open; forgetting a feed —
    /// a hidden source, another account — drops it without handling it.
    func testPartialReadKeepsTheUnseenOpenAndForgettingHandlesNothing() {
        let other = NowSource(feed: .githubStalePRs, identity: "github.com/someone-else")
        var ledger = ObservationLedger()
        _ = ledger.record(read(["pr:1", "pr:2"]), now: t0)
        _ = ledger.record(read(["pr:1"], .partial), now: minutes(1))
        XCTAssertEqual(Set(ledger.open(github).map(\.needID)), ["pr:1", "pr:2"])
        // Past its feed's horizon (eve: the 24 h window) a need is out of
        // view — on a read, a summon or a relaunch — and still unhandled.
        let eve = NowSource(feed: .eveNotifications, identity: "eve.test/a1")
        _ = ledger.record(read(["eve:1"], .partial, source: eve), now: t0)
        XCTAssertEqual(ledger.open(eve, now: minutes(2)).map(\.needID), ["eve:1"])
        XCTAssertEqual(ledger.open(eve, now: minutes(25 * 60)), [])
        XCTAssertTrue(ledger.handled(now: minutes(2)).isEmpty)

        _ = ledger.record(read(["pr:9"], source: other), now: minutes(2))
        ledger.forget(.githubStalePRs, keeping: other)
        XCTAssertEqual(ledger.open(github), [])
        XCTAssertEqual(ledger.open(other).map(\.needID), ["pr:9"])
        ledger.forget(.githubStalePRs)
        XCTAssertEqual(ledger.entries.values.map(\.source), [eve])
        XCTAssertTrue(ledger.handled(now: minutes(3)).isEmpty)
    }
}
