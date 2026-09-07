import Foundation
import Observation

/// The `.prod` palette mode's data: ALL unresolved prod errors, fetched in
/// 4-day windows that load staggered (0–4d immediately, then 4–8d, then
/// 8–12d) and merge newest-first.
///
/// Cache contract: older windows keep their last result for `ttl` and are
/// served from cache on re-entry; the NEWEST window is always refetched —
/// having a cache never means skipping the fetch for what's current.
@MainActor
@Observable
final class ProdArchive {
    static let shared = ProdArchive()

    private(set) var issues: [ProdIssue] = []
    private(set) var loadedDays = 0
    private(set) var isLoading = false
    private(set) var error: String?

    private static let windowDays = 4
    private static let windowCount = 3    // 3 × 4d = 12 days total
    private static let ttl: TimeInterval = 10 * 60

    private struct CachedWindow {
        let issues: [ProdIssue]
        let fetchedAt: Date
    }
    private var cache: [Int: CachedWindow] = [:]
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Entering `.prod` mode calls this; re-entry within the TTL serves the
    /// old windows instantly while window 0 refreshes underneath.
    func load() {
        guard loadTask == nil else { return }
        error = nil
        loadTask = Task {
            defer { loadTask = nil }
            isLoading = true
            defer { isLoading = false }
            for window in 0..<Self.windowCount {
                if window > 0, let cached = cache[window],
                   Date().timeIntervalSince(cached.fetchedAt) < Self.ttl {
                    publish(upTo: window)
                    continue
                }
                await fetchWindow(window)
                publish(upTo: window)
            }
        }
    }

    private func fetchWindow(_ window: Int) async {
        // Three windows × every project is the heaviest burst Pultík makes at
        // Sentry, so it takes a real gate verdict — not just an isPaused peek
        // that goes quiet the moment a pause expires. A half-open breaker gets
        // one cheap org probe before the burst is allowed out.
        let prefs = Preferences.load()
        switch ProbeGate.shared.verdict(.sentry) {
        case .hold:
            error = "sentry probes paused — refresh from the footer to retry"
            return
        case .trial:
            if let failure = await SentryClient.shared.probeHealth(settingsToken: StatusStore.shared.sentryToken) {
                ProbeGate.shared.failed(.sentry, failure)
                if window == 0 { error = "sentry unreachable (mesh? token?)" }
                return
            }
            ProbeGate.shared.succeeded(.sentry)
        case .go:
            break
        }
        let now = Date()
        let end = now.addingTimeInterval(-Double(window * Self.windowDays) * 86_400)
        let start = end.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        var collected: [ProdIssue] = []
        var failures: [ProbeFailure] = []
        await withTaskGroup(of: ProbeResult<[ProdIssue]>.self) { group in
            for project in prefs.sentryProjects {
                group.addTask {
                    do {
                        let fetched = try await SentryClient.shared.archiveIssues(
                            project: project, settingsToken: StatusStore.shared.sentryToken,
                            start: start, end: end
                        )
                        return .value(fetched.map { ProdIssue(project: project, issue: $0) })
                    } catch {
                        return .failed(.classify(error))
                    }
                }
            }
            for await result in group {
                switch result {
                case .value(let slice): collected.append(contentsOf: slice)
                case .failed(let failure): failures.append(failure)
                }
            }
        }
        // Every project failing is off-mesh / no token, not a quiet 4 days —
        // say so, and stop the next mode entry firing the same burst again.
        // (A window that comes back genuinely empty is no longer mistaken for
        // this: only a thrown request counts as a failure now.)
        if failures.count == prefs.sentryProjects.count, let failure = failures.first {
            ProbeGate.shared.failed(.sentry, failure)
            if window == 0 { error = "sentry unreachable (mesh? token?)" }
        } else {
            // Landed answers clear the strike ladder — without this, a run of
            // old failures survives every successful archive sweep.
            ProbeGate.shared.succeeded(.sentry)
        }
        cache[window] = CachedWindow(issues: collected, fetchedAt: Date())
    }

    /// Merge the loaded windows newest-first, deduped by issue id (an issue
    /// active across two windows keeps its newest-window entry).
    private func publish(upTo window: Int) {
        var seen = Set<String>()
        var merged: [ProdIssue] = []
        for index in 0...window {
            guard let cached = cache[index] else { continue }
            for issue in cached.issues.sorted(by: { $0.issue.lastSeen > $1.issue.lastSeen })
            where seen.insert(issue.id).inserted {
                merged.append(issue)
            }
        }
        issues = merged
        loadedDays = (window + 1) * Self.windowDays
    }
}
