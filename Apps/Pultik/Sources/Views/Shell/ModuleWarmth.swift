import Foundation
import Observation

/// Which module bodies are mounted (stay in Pultík D4): the strip's lift
/// moves with every key, but the body swaps only once the keys settle, so
/// walking ←/→ past five modules builds only the one it stops on. The last
/// three modules shown stay mounted, and so do the operator's keep-hot ones
/// (Settings ▸ Modules) once a summon settles — switching to any of them is
/// a flip, never a build. While the panel is hidden only the displayed body
/// stays: nothing renders off screen. Home is the global search's body.
/// Foundation-only.
@MainActor
@Observable
final class ModuleWarmth {
    static let recentLimit = 3
    /// How long the keys must rest before a cold module is built: the first
    /// key from rest, and while a walk is under way (keys under `walkGap`
    /// apart) — a tapped walk is slower than key repeat.
    static let settle: Duration = .milliseconds(220)
    static let walkSettle: Duration = .milliseconds(320)
    static let walkGap: TimeInterval = 0.5
    /// How long after a summon the keep-hot bodies are built.
    static let prebuild: Duration = .milliseconds(450)

    /// The body drawn: a module, or `.home` for the global search.
    private(set) var displayed: PanelModule = .home
    /// The last bodies shown, most recent last, the displayed one included.
    private(set) var recent: [PanelModule] = [.home]
    /// Settings ▸ Modules' keep-hot set.
    var keepHot: Set<PanelModule> = ModuleWarmth.defaultHot
    /// The keep-hot bodies are mounted: the panel is up and has settled.
    private(set) var hotMounted = false
    /// Module bodies built since launch — the driver's `moduleBuilds` (AC 12).
    private(set) var builds: [PanelModule: Int] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: Date?
    @ObservationIgnored private var prebuilding: Task<Void, Never>?

    static let defaultHot: Set<PanelModule> = [.home, .prs, .ci]

    var totalBuilds: Int { builds.values.reduce(0, +) }

    /// Every body to keep mounted, in a stable order (the strip's).
    var mounted: [PanelModule] {
        let wanted = Set(recent + [displayed]).union(hotMounted ? keepHot : [])
        return PanelModule.allCases.filter(wanted.contains)
    }

    /// The router moved to `target`: a mounted body flips at once, a cold
    /// one waits for the keys to rest. `immediate`: a summon restoring its
    /// place shows it at once — no keys to coalesce.
    func request(_ target: PanelModule, immediate: Bool = false, now: Date = Date()) {
        let walking = lastRequest.map { now.timeIntervalSince($0) < Self.walkGap } ?? false
        lastRequest = now
        pending?.cancel()
        pending = nil
        guard target != displayed else { return }
        if immediate || mounted.contains(target) {
            show(target)
            return
        }
        let settle = walking ? Self.walkSettle : Self.settle
        pending = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.show(target)
        }
    }

    /// A body appeared in the tree: one build.
    func built(_ module: PanelModule) {
        builds[module, default: 0] += 1
    }

    /// The panel is up: after it settles, the keep-hot bodies are built.
    func presented() {
        prebuilding?.cancel()
        prebuilding = Task { [weak self] in
            try? await Task.sleep(for: Self.prebuild)
            guard !Task.isCancelled else { return }
            self?.hotMounted = true
        }
    }

    /// Hidden: only the displayed body stays.
    func dismissed() {
        prebuilding?.cancel()
        pending?.cancel()
        hotMounted = false
        recent = [displayed]
    }

    private func show(_ target: PanelModule) {
        displayed = target
        recent.removeAll { $0 == target }
        recent.append(target)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }
}

/// Which details a page that stages them keeps built (focus D23): the
/// selection's, so ↵ is a flip, and with the detail open its next and
/// previous objects', so ↑/↓ is one too. The set follows the selection only
/// after the frame that drew the key, one detail a turn: building a
/// neighbour never sits in front of the flip it prepares. Object ids in the
/// list's drawn order; Foundation-only.
enum DetailStaging {
    /// The selection and one neighbour each side: never more built at once.
    static let limit = 3
    /// One frame: how long after a step onto a built detail the set follows.
    static let turn: Duration = .milliseconds(16)
    /// How long the cursor rests before a detail is built for it cold: a row
    /// of a closed list, a detail opened before it was built. A held key
    /// repeats faster and builds nothing. A tapped walk is slower: it builds
    /// the detail of each row it rests on this long, and a key that lands in
    /// that build waits for it — what ↵ being a flip this soon costs.
    static let rest: Duration = .milliseconds(100)

    /// What to keep built for `selection`, in the order to build it: the
    /// selection, then (open) the object after it and the one before.
    /// Nothing for a selection the list does not hold.
    static func wanted(selection: String?, open: Bool, in ids: [String]) -> [String] {
        guard let selection, let index = ids.firstIndex(of: selection) else { return [] }
        guard open else { return [selection] }
        var wanted = [selection]
        if index + 1 < ids.count { wanted.append(ids[index + 1]) }
        if index > 0 { wanted.append(ids[index - 1]) }
        return wanted
    }

    /// What is mounted now, in list order (a step never reorders the views):
    /// `staged` as far as the list still holds it, and the open selection
    /// whether staged or not — the key that opens it builds it. Past `limit`
    /// the farthest from the selection goes first.
    static func mounted(staged: [String], selection: String?, open: Bool, in ids: [String]) -> [String] {
        var held: [(id: String, index: Int)] = []
        for id in staged where !held.contains(where: { $0.id == id }) {
            if let index = ids.firstIndex(of: id) { held.append((id, index)) }
        }
        let cursor = selection.flatMap { ids.firstIndex(of: $0) }
        if open, let selection, let cursor, !held.contains(where: { $0.id == selection }) { held.append((selection, cursor)) }
        if held.count > limit {
            let centre = cursor ?? held[0].index
            held.sort { (abs($0.index - centre), $0.index) < (abs($1.index - centre), $1.index) }
            held.removeLast(held.count - limit)
        }
        return held.sorted { $0.index < $1.index }.map(\.id)
    }

    /// The next set on the way from `staged` to `wanted`: what is no longer
    /// wanted goes, and one more detail is built. The open selection is
    /// mounted already (`mounted`), so it joins without taking the turn.
    static func step(from staged: [String], toward wanted: [String], open: Bool) -> [String] {
        var next = staged.filter(wanted.contains)
        if open, let selection = wanted.first, !next.contains(selection) { next.append(selection) }
        if let add = wanted.first(where: { !next.contains($0) }) { next.append(add) }
        return next
    }

    /// How long the set waits before it follows `wanted`: a frame when the
    /// selection stepped onto a detail already built, the rest otherwise.
    static func delay(staged: [String], wanted: [String], open: Bool) -> Duration {
        open && wanted.first.map(staged.contains) == true ? turn : rest
    }

    /// Returns when the main run loop is next about to sleep: the key's
    /// frame is committed and no event waits behind it. A detail is built
    /// only from there, so the keys of a held ↓ are served before a
    /// neighbour is built, and the Debug bench's idle point (`PROpenProbe`,
    /// the same run-loop activity, registered first) comes before the build.
    @MainActor
    static func idle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // One shot: the observer is invalidated once it has fired.
            let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
            ) { _, _ in continuation.resume() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
}

/// One of the router's key requests (a scroll, a verb's letter, a composer's
/// ⌘↵, F12, ↵ on a ringed target) as a view inside a staged detail hears it
/// (focus D23): only on screen. Off screen the request is not read, so such
/// a key re-runs the views on screen and none of the staged ones. The value
/// of an `onChange`, which takes `taken(after:)`. Foundation-only.
struct Heard<Request: Equatable>: Equatable {
    let onScreen: Bool
    let request: Request?

    init(_ onScreen: Bool, _ request: @autoclosure () -> Request?) {
        self.onScreen = onScreen
        self.request = onScreen ? request() : nil
    }

    /// The request to act on. None for a view that just came on screen: the
    /// one it finds then was made for another detail, or never taken.
    func taken(after old: Self) -> Request? {
        old.onScreen ? request : nil
    }
}
