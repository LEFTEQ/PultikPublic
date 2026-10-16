import Foundation
import Observation

/// Where a summon lands (stay in Pultík D1): Esc still peels one layer at a
/// time, but ⌥Space returns to the last place the operator dwelled — rested
/// on for 1.5 s while the panel was up — not to the layers an Esc run
/// passed on its way out. Hidden past `homeAfter`, a summon opens on Home.
///
/// `AppDelegate` owns it, so the router (and with it the place) outlives
/// the hosting tree's release after 30 s hidden: a rebuilt panel restores
/// from here. Foundation-only; `Tests/PanelLifecycleTests.swift` drives the
/// dwell with explicit times.
@MainActor
@Observable
final class PanelPlace {
    /// Resting this long on a place makes it the one a summon returns to.
    nonisolated static let dwell: TimeInterval = 1.5
    nonisolated static let defaultHomeAfter: TimeInterval = 15 * 60

    let router: ModuleRouter
    /// The last place rested on while the panel was up.
    private(set) var dwelled: ModuleRouter.Place = .home
    private(set) var hiddenAt: Date?
    /// Settings ▸ Panel: hidden longer than this opens on Home.
    @ObservationIgnored var homeAfter: TimeInterval
    /// Per scroller (a module's list, a detail by its object), the item it
    /// was scrolled to: a rebuilt tree scrolls back there.
    @ObservationIgnored var anchors: [String: String] = [:]

    init(router: ModuleRouter? = nil, homeAfter: TimeInterval = PanelPlace.defaultHomeAfter) {
        self.router = router ?? ModuleRouter()
        self.homeAfter = homeAfter
    }

    /// `place` has been on screen, unchanged, since `since`: at 1.5 s it is
    /// the place. The panel calls this when the place settles.
    func rested(on place: ModuleRouter.Place, since: Date, now: Date = Date()) {
        guard hiddenAt == nil, now.timeIntervalSince(since) >= Self.dwell, place == router.place else { return }
        dwelled = place
    }

    func dismissed(at now: Date = Date()) {
        if hiddenAt == nil { hiddenAt = now }
    }

    /// A summon: the dwelled place, or Home after `homeAfter` hidden.
    func presented(at now: Date = Date()) {
        defer { hiddenAt = nil }
        if let hiddenAt, now.timeIntervalSince(hiddenAt) > homeAfter {
            dwelled = .home
            anchors = [:]
        }
        router.restore(dwelled)
    }
}
