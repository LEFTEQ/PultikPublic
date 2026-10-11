import Foundation

extension StatusStore {
    // MARK: - Sentry (prod issues)

    /// Unresolved production issues across the configured projects — throttled
    /// to every 5 minutes; new issues (after the first load) notify.
    func refreshSentryIfStale() async {
        // Decision log (Settled): while Hlídač serves prod Sentry the Mac
        // stops sweeping it — no polling, no new-issue banners. The first
        // sweep after Hlídač goes away is a silent baseline, so what arrived
        // meanwhile does not burst out as banners.
        if ProdClaims.sentryLive(digest: prodDigest, unreachableSince: prodUnconfirmedSince) {
            seenSentryIssues = nil
            return
        }
        if let last = lastSentryRefresh, Date().timeIntervalSince(last) < 300 { return }
        // The global list plus every project's own: `eve-exampleapp` and
        // `booking-onboarding` were configured per project and never swept.
        let projects = preferences.allSentryProjects
        // `sentryToken`, never `preferences.sentryToken`: the keychain is the
        // runtime store and the legacy plaintext copy is blanked on migration.
        let settingsToken = sentryToken
        guard !projects.isEmpty else { return }

        await gated(.sentry, probe: {
            await SentryClient.shared.probeHealth(settingsToken: settingsToken)
        }) {
            let collected = await withTaskGroup(of: ProbeResult<[ProdIssue]>.self) { group in
                for project in projects {
                    group.addTask {
                        do {
                            let issues = try await SentryClient.shared.unresolvedIssues(
                                project: project, settingsToken: settingsToken
                            )
                            return .value(issues.map { ProdIssue(project: project, issue: $0) })
                        } catch {
                            // Off-mesh / token missing: prod strip just stays empty.
                            NSLog("pultik: sentry %@ failed: %@", project, error.localizedDescription)
                            return .failed(.classify(error))
                        }
                    }
                }
                var all: [ProdIssue] = []
                var failures: [ProbeFailure] = []
                for await result in group {
                    switch result {
                    case let .value(issues): all.append(contentsOf: issues)
                    case let .failed(failure): failures.append(failure)
                    }
                }
                return (issues: all, failures: failures)
            }

            // One project failing is a project problem (permissions, a typo in
            // the slug); ALL of them failing is a host problem, and only that
            // is worth pulling the whole strip off Sentry for.
            guard collected.failures.count < projects.count else {
                lastSentryRefresh = Date()
                return collected.failures.first
            }
            // Hlídač took Sentry over while this sweep was out: its banners
            // and rows are no longer the Mac's to publish.
            if ProdClaims.sentryLive(digest: prodDigest, unreachableSince: prodUnconfirmedSince) {
                seenSentryIssues = nil
                lastSentryRefresh = Date()
                return nil
            }

            // "Major" means CURRENT: unresolved is forever in Sentry, so keep only
            // issues actually seen in the last 24h (kills months-old test noise).
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let sorted = collected.issues
                .filter { $0.issue.lastSeen > cutoff }
                .sorted { $0.issue.lastSeen > $1.issue.lastSeen }
            if let seen = seenSentryIssues {
                for prodIssue in sorted where !seen.contains(prodIssue.id) {
                    Notifier.send(
                        title: "\(prodIssue.productLabel) prod — \(prodIssue.issue.shortId)",
                        body: prodIssue.issue.title,
                        url: prodIssue.issue.permalink
                    )
                }
            }
            seenSentryIssues = (seenSentryIssues ?? []).union(sorted.map(\.id))
            prodIssues = sorted
            lastSentryRefresh = Date()
            return nil
        }
    }
}
