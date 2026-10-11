import Foundation

extension StatusStore {
    // MARK: - Prod watch (Hlídač)

    /// The prod board's cards in board order — settings pointers over
    /// Hlídač's verdicts, blind while Hlídač is not answering.
    var prodGlance: ProdGlance {
        ProdGlance.make(pointers: preferences.prodPointers, digest: prodDigest,
                        unreachableSince: prodUnreachableSince, asOf: prodRestoredAt, now: Date())
    }

    /// The prod board owns this firing alert (`ProdClaims.isClaimed` over the
    /// board's own deployment selection): FIRING and `.h`'s estate firing
    /// leave it to the deployment's card.
    func prodClaims(_ alert: FiringAlert) -> Bool {
        ProdClaims.isClaimed(alert: alert, digest: prodDigest, unreachableSince: prodUnconfirmedSince,
                             pointers: preferences.prodPointers)
    }

    /// settings.json problems plus doubled prod keys — the orange rows above
    /// the prod board, shown whatever the board's visibility or fold.
    var prodConfigIssues: [String] {
        configIssues + preferences.prodPointerIssues
    }

    /// Since when the board has not been confirmed live: Hlídač failing, or the
    /// digest restored from disk at launch before its first answer. While
    /// set, nothing — a claim, the Sentry handoff, a card — trusts the digest.
    var prodUnconfirmedSince: Date? {
        prodUnreachableSince ?? prodRestoredAt
    }

    /// `hlidacURL: ""` in settings.json turns the prod board off; unset means
    /// the default Hlídač.
    var hlidacConfigured: Bool {
        preferences.hlidacURL.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? true
    }

    /// The menu bar's health strip (WP7 draws it).
    var prodDots: [ProdGlance.Dot] {
        prodGlance.dots(seenRed: prodSeenRed)
    }

    /// An open panel has shown every red card: stop their dots pulsing.
    func markProdSeen() {
        prodSeenRed.formUnion(prodGlance.redKeys)
    }

    /// One `gated(.hlidac)` call at a time: the fast lane and an explicit
    /// refresh must not both hold a trial, or the breaker's bookkeeping races.
    func refreshProd() async {
        guard !isRefreshingProd else { return }
        isRefreshingProd = true
        defer { isRefreshingProd = false }
        guard hlidacConfigured else {
            // `hlidacURL: ""` turns the board off — no request, no digest,
            // so no card claims an alert, no dot draws and FiringWatch keeps
            // every alert and announcement.
            prodDigest = nil
            prodUnreachableSince = nil
            prodRestoredAt = nil
            ProdWatch.shared.observe(digest: nil, unreachableSince: nil, pointers: [], firingAnnounced: [])
            recordProdNeeds(answered: false)
            return
        }
        let base = hlidacBase
        let snapshotKey = prodSnapshotKey
        var answered = false
        await gated(.hlidac, probe: { await HlidacClient.shared.probe(base: base) }) {
            let (digest, failure) = await HlidacClient.shared.digest(base: base)
            guard let digest else {
                if prodUnreachableSince == nil { prodUnreachableSince = Date() }
                return failure
            }
            answered = true
            prodDigest = digest
            prodUnreachableSince = nil
            prodRestoredAt = nil
            recordProdSnapshot(key: snapshotKey)
            prodSeenRed = ProdGlance.seen(prodSeenRed, keepingOnly: prodGlance.redKeys)
            return nil
        }
        // A held breaker skips the call above; the board must still read
        // blind rather than keep showing a stale green.
        if gate.isPaused(.hlidac), prodUnreachableSince == nil { prodUnreachableSince = Date() }
        // Hlídač owns prod Sentry from this answer on (`refreshSentryIfStale`):
        // drop the Mac sweep's baseline now, on the 15 s lane, so a fallback
        // sweep after a short ownership never announces what piled up meanwhile.
        if ProdClaims.sentryLive(digest: prodDigest, unreachableSince: prodUnconfirmedSince) {
            seenSentryIssues = nil
        }
        ProdWatch.shared.observe(digest: prodDigest, unreachableSince: prodUnreachableSince,
                                 pointers: preferences.prodPointers,
                                 firingAnnounced: firingWatch.announcedDeployments)
        recordProdNeeds(answered: answered)
    }
}

extension StatusStore {
    /// Hlídač's base: settings.json `hlidacURL`, else the default.
    var hlidacBase: URL {
        var configured = preferences.hlidacURL ?? Preferences.defaultHlidacURL
        #if DEBUG
            // Hands-off verification serves the golden digest locally
            // (CLAUDE.md "Verification"); release builds never read this.
            if let override = ProcessInfo.processInfo.environment["PULTIK_HLIDAC_URL"], !override.isEmpty {
                configured = override
            }
        #endif
        return URL(string: configured) ?? URL(string: Preferences.defaultHlidacURL)!
    }
}
