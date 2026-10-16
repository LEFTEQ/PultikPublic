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
