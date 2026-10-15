import Foundation
import Observation

/// Home's Now queue as the app holds it (copilot shell D6, WP4). Every
/// backend lane hands its fresh read to `record(_:)` — the adapter's output,
/// never a restored snapshot — and the observation ledger stamps each need's
/// episode and first-observed onset. Both Home styles draw `queue`; the
/// Handled section draws `handled`.
///
/// A failed read keeps the source's last needs on screen and clears nothing.
/// A read under another identity (account, workspace, origin) replaces its
/// feed's needs outright, so one identity's needs never show under another.
/// A cold start shows the needs the ledger left open, "as of" their last
/// observation, until each source answers again — never a blank Home.
@MainActor
@Observable
final class NowStore {
    static let shared = NowStore(directory: ObservationLedger.defaultDirectory)

    /// Coalesces ledger writes: a busy minute is one write, not nine.
    static let saveDelay: Duration = .seconds(5)

    /// The ranked queue, rebuilt on every read and every summon.
    private(set) var queue: NowQueue
    /// Needs a complete read stopped listing within the window, latest first.
    private(set) var handled: [ObservationLedger.Entry] = []
    /// While a source still shows what the last run left: the oldest of
    /// those observations — Home's "as of HH:MM".
    private(set) var restoredAsOf: Date?
    /// Nothing has answered yet and the ledger held nothing: Home draws its
    /// loading rows, never "All quiet".
    private(set) var awaitingFirstRead: Bool

    @ObservationIgnored private var ledger: ObservationLedger
    @ObservationIgnored private var needs: [NowSource: [NowNeed]]
    @ObservationIgnored private var restored: Set<NowSource>
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directory: URL, now: Date = Date()) {
        let ledger = ObservationLedger.load(from: directory)
        var seeded: [NowSource: [NowNeed]] = [:]
        for source in Set(ledger.entries.values.map(\.source)) {
            let open = ledger.open(source, now: now)
            if !open.isEmpty { seeded[source] = open }
        }
        self.directory = directory
        self.ledger = ledger
        needs = seeded
        restored = Set(seeded.keys)
        awaitingFirstRead = seeded.isEmpty
        queue = NowQueue.build(needs: [], now: now)
        rebuild(now: now)
    }

    /// One adapter pass, recorded by the lane that read it. A source shows
    /// what the ledger still holds open for it, so a partial read keeps the
    /// needs it could not see — unless they began before its horizon.
    func record(_ read: NowRead, now: Date = Date()) {
        _ = ledger.record(read, now: now)
        // One identity per feed, on screen and on disk: another account's
        // needs leave with it, unhandled, and never return on a relaunch.
        ledger.forget(read.source.feed, keeping: read.source)
        for source in needs.keys where source.feed == read.source.feed && source != read.source {
            needs[source] = nil
            restored.remove(source)
        }
        if read.coverage != .failed {
            needs[read.source] = ledger.open(read.source, now: now)
            restored.remove(read.source)
            awaitingFirstRead = false
        }
        rebuild(now: now)
        scheduleSave()
    }

    /// What the ledger still holds open for `source` — for an adapter that
    /// must not let a read clear a need it could not see (the fleet's
    /// silently hidden rows).
    func open(_ source: NowSource, now: Date = Date()) -> [NowNeed] {
        ledger.open(source, now: now)
    }

    /// A source switched off — its section hidden, Hlídač unset, nothing
    /// pinned. Its needs leave Now and the ledger unhandled: a switch is not
    /// a resolution, and a hidden source must not return on a relaunch.
    func forget(_ feed: NowFeed, now: Date = Date()) {
        let gone = needs.keys.filter { $0.feed == feed }
        // Handled-only entries count too: the section and the file change.
        guard ledger.forget(feed) || !gone.isEmpty else { return }
        for source in gone {
            needs[source] = nil
            restored.remove(source)
        }
        rebuild(now: now)
        scheduleSave()
    }

    /// A summon: ages move, the Handled window slides, and restored needs
    /// the ledger has since aged out leave.
    func refresh(now: Date = Date()) {
        ledger.evict(now: now)
        for source in restored {
            let open = ledger.open(source, now: now)
            needs[source] = open.isEmpty ? nil : open
        }
        restored = restored.filter { needs[$0] != nil }
        rebuild(now: now)
    }

    private func rebuild(now: Date) {
        let next = NowQueue.build(needs: needs.values.flatMap { $0 }, now: now)
        if next != queue { queue = next }
        let cleared = ledger.handled(now: now)
        if cleared != handled { handled = cleared }
        let asOf = ledger.entries.values
            .filter { restored.contains($0.source) && $0.isActive }
            .map(\.lastObservedAt).min()
        if asOf != restoredAsOf { restoredAsOf = asOf }
    }

    /// One write per `saveDelay`, off the main actor; the ledger is
    /// rebuildable, so a crash loses seconds of first observations at most.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self else { return }
            let snapshot = ledger
            let directory = directory
            saveTask = nil
            await Task.detached(priority: .utility) {
                do {
                    try snapshot.save(to: directory)
                } catch {
                    NSLog("pultik: now ledger save failed at %@: %@", directory.path, String(describing: error))
                }
            }.value
        }
    }
}
