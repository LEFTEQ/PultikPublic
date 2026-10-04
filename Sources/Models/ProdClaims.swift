import Foundation

/// Which signals the prod board owns while Hlídač answers — the one
/// predicate the rails, the notifications and `FiringWatch` all ask, so a
/// prod incident is shown and announced through exactly one channel
/// (docs/specs/2026-10-03-prod-watch-contracts.md §4–§5).
enum ProdClaims {
    /// A firing alert belongs to the prod board only while the board can
    /// actually show it:
    /// - Hlídač answered and is not stale (`unreachableSince` nil);
    /// - the alert's `deployment` label names a deployment in the digest
    ///   that Hlídač is watching (not `blind`, not `unmonitored`);
    /// - that deployment is on the board: among `pointers` (settings.json
    ///   `projects[].prod`), or any digest deployment when there are none —
    ///   `ProdGlance.make`'s selection. An excluded deployment's alert stays
    ///   with the estate path, since no card would show or announce it;
    /// - Hlídač's Alertmanager source has not failed — otherwise the digest
    ///   cannot carry the alert, and the estate path keeps it.
    static func isClaimed(alert: FiringAlert, digest: HlidacDigest?, unreachableSince: Date?,
                          pointers: [ProdPointer]) -> Bool {
        guard let digest, unreachableSince == nil,
              digest.sources["alertmanager"]?.ok != false,
              let key = alert.labels["deployment"],
              pointers.isEmpty || pointers.contains(where: { $0.key == key }),
              let deployment = digest.deployments.first(where: { $0.key == key })
        else { return false }
        return deployment.verdict != .blind && deployment.verdict != .unmonitored
    }

    /// True when Hlídač serves prod Sentry issues, so the Mac's own Sentry
    /// sweep (the fallback) should stay hidden: Hlídač answering, not stale,
    /// and its Sentry source not failed.
    static func sentryLive(digest: HlidacDigest?, unreachableSince: Date?) -> Bool {
        guard let digest, unreachableSince == nil else { return false }
        return digest.sources["sentry"]?.ok != false
    }
}
