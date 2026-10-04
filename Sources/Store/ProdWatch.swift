import Foundation

/// The prod board's notifications (decision log D9 L1, D10). `StatusStore`
/// hands it every Hlídač outcome; `ProdTransitions` decides, this sends.
///
/// While Hlídač answers, an alert the digest can show belongs to the prod
/// board (`ProdClaims.isClaimed`): `FiringWatch` keeps quiet on it, so one
/// outage is one banner, not two. While Hlídač is away those alerts fall back
/// to FiringWatch; when it returns, the deployments FiringWatch announced are
/// adopted here, so their red is not repeated and their recovery comes once.
@MainActor
final class ProdWatch {
    static let shared = ProdWatch()

    private var transitions = ProdTransitions()
    private var digest: HlidacDigest?
    private var unreachableSince: Date?
    private var pointers: [ProdPointer] = []
    private var live = false

    private init() {}

    func claims(_ alert: FiringAlert) -> Bool {
        ProdClaims.isClaimed(alert: alert, digest: digest, unreachableSince: unreachableSince, pointers: pointers)
    }

    /// - Parameters:
    ///   - pointers: settings.json `projects[].prod` — only these notify.
    ///   - firingAnnounced: deployments FiringWatch has announced red
    ///     (`FiringWatch.announcedDeployments`), adopted when Hlídač returns.
    func observe(digest: HlidacDigest?, unreachableSince: Date?, pointers: [ProdPointer],
                 firingAnnounced: Set<String>) {
        self.digest = digest
        self.unreachableSince = unreachableSince
        self.pointers = pointers
        let nowLive = digest != nil && unreachableSince == nil
        if nowLive, !live { transitions.adopt(firingAnnounced) }
        live = nowLive
        for notice in transitions.update(digest: digest, unreachableSince: unreachableSince, pointers: pointers) {
            Notifier.send(title: notice.title, body: notice.body, url: Notifier.prodPanelURL(notice.key),
                          thread: "prod.\(notice.key)", interruption: notice.interruption,
                          bypassFocus: notice.bypassesFocus)
        }
    }
}
