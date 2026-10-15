import Foundation

// Production's needs: Hlídač blindness, Hlídač's Sentry issues and the
// estate's firing alerts. Verdicts stay Hlídač's (prod watch D14); a cached
// digest is never judged, so prod is never green — or cleared — from cache.

extension NowAdapters {
    /// Hlídač lists at most this many Sentry issues per deployment
    /// (contracts §5): a full list may hide more.
    static let digestIssueCap = 5

    /// The one row a deployment's verdict, mapped Sentry issues and claimed
    /// firing alerts share.
    static func deploymentIncident(origin: String, _ key: String) -> String {
        "hlidac:\(origin):deployment:\(key)"
    }

    /// The Prod module's row for a deployment (`ProdMatrixPage.objectID`).
    static func deploymentObject(_ key: String) -> String {
        "deployment:\(key)"
    }

    /// Production that cannot be judged is on fire from the failure's own
    /// onset: Mac → Hlídač transport (`prodUnreachableSince`), a failing
    /// Hlídač source (`sources.<name>.since`) or a blind deployment
    /// (`blindSince`, on the deployment's row).
    static func hlidacBlindness(digest: HlidacDigest?, unreachableSince: Date?, origin: String, now: Date) -> NowRead {
        let source = NowSource(feed: .hlidacBlindness, identity: origin)
        func blind(_ id: String, incident: String? = nil, title: String, subtitle: String?, since: Date?,
                   object: String) -> NowNeed {
            let needID = "hlidac:\(origin):blind:\(id)"
            return NowNeed(needID: needID, incidentKey: incident ?? needID, kind: .monitoringBlind, lane: .onFire,
                           severity: .critical, onset: onset(since, now: now), title: title, subtitle: subtitle,
                           verb: .open("Inspect monitoring"), target: NowTarget(module: .prod, objectID: object))
        }
        if let unreachableSince {
            // The digest is a cache now: only the transport need is known,
            // and nothing the cache last said may clear.
            return NowRead(source: source, coverage: .partial, needs: [
                blind("transport", title: "Hlídač is unreachable — prod is blind", subtitle: origin,
                      since: unreachableSince, object: "hlidac"),
            ])
        }
        guard let digest else { return failed(source) }
        let sources = digest.sources.keys.sorted().compactMap { name -> NowNeed? in
            guard let state = digest.sources[name], !state.ok else { return nil }
            return blind(name, title: "Hlídač's \(name) source is failing", subtitle: state.error, since: state.since,
                         object: "source:\(name)")
        }
        let deployments = digest.deployments.filter { $0.verdict == .blind }.map { deployment in
            blind("deployment:\(deployment.key)", incident: deploymentIncident(origin: origin, deployment.key),
                  title: "\(deployment.title) is blind", subtitle: deployment.project, since: deployment.blindSince,
                  object: deploymentObject(deployment.key))
        }
        return NowRead(source: source, coverage: .complete, needs: sources + deployments)
    }

    /// Sentry issues Hlídač maps to an unhealthy deployment join that
    /// deployment's row, onset labelled with the issue's lifetime
    /// `firstSeen`. An `ok` deployment's issues stay in Prod: Hlídač judged
    /// it healthy. A deployment showing a full issue list makes the read
    /// partial; a failing Sentry source makes it fail.
    static func hlidacSentry(digest: HlidacDigest?, unreachableSince: Date?, origin: String, now: Date) -> NowRead {
        let source = NowSource(feed: .hlidacSentry, identity: origin)
        guard unreachableSince == nil, let digest, digest.sources["sentry"]?.ok != false else { return failed(source) }
        var truncated = false
        var needs: [NowNeed] = []
        for deployment in digest.deployments where deployment.verdict != .ok {
            truncated = truncated || deployment.sentry.count >= digestIssueCap
            let severity: NowSeverity = deployment.emergency ? .emergency
                : deployment.verdict == .down ? .critical : .warning
            let incident = deploymentIncident(origin: origin, deployment.key)
            needs += deployment.sentry.map { issue in
                NowNeed(needID: "\(incident):sentry:\(issue.id)", incidentKey: incident, kind: .sentryIssue,
                        lane: .onFire, severity: severity, onset: .firstSeen(issue.firstSeen), title: issue.title,
                        subtitle: deployment.title, displayID: issue.shortId, verb: .open("Inspect issue"),
                        target: NowTarget(module: .prod, objectID: deploymentObject(deployment.key),
                                          url: issue.permalink))
            }
        }
        return NowRead(source: source, coverage: truncated ? .partial : .complete, needs: needs)
    }

    /// Firing rules from the estate's Prometheus and Loki rulers. One the
    /// prod board claims (`ProdClaims`) joins its deployment's row on fire —
    /// identity unchanged, so a claim moving never reads as handled; an
    /// unclaimed critical or emergency rule is on fire on its own row, an
    /// unclaimed warning drifts. Pending rules are not needs yet, and the
    /// `Watchdog` heartbeat firing is the healthy state, never one. `complete`
    /// is false when one ruler (Prometheus or Loki) did not answer: its
    /// rules are missing, not resolved.
    static func estateAlerts(_ alerts: [FiringAlert]?, complete: Bool = true, digest: HlidacDigest?,
                             unreachableSince: Date?, pointers: [ProdPointer], hlidacOrigin: String, origin: String,
                             now: Date) -> NowRead {
        let source = NowSource(feed: .estateAlerts, identity: origin)
        guard let alerts else { return failed(source) }
        let needs = alerts.filter { $0.state == "firing" && !$0.isHeartbeat }.map { alert -> NowNeed in
            let severity: NowSeverity = alert.labels["page"] == "emergency" ? .emergency
                : alert.severity == "critical" ? .critical
                : alert.severity == "warning" ? .warning : .normal
            let needID = "estate:\(alert.source.rawValue):\(alert.name):\(stableLabels(alert))"
            let claimedBy = ProdClaims.isClaimed(alert: alert, digest: digest, unreachableSince: unreachableSince,
                                                 pointers: pointers) ? alert.labels["deployment"] : nil
            return NowNeed(
                needID: needID,
                incidentKey: claimedBy.map { deploymentIncident(origin: hlidacOrigin, $0) } ?? needID,
                kind: .firingAlert,
                lane: claimedBy != nil || severity < .warning ? .onFire : .drifting,
                severity: severity, onset: onset(alert.activeAt, now: now), title: alert.summary ?? alert.name,
                subtitle: alert.context, verb: .open("Inspect alert"),
                target: NowTarget(module: claimedBy != nil ? .prod : .estate,
                                  objectID: claimedBy.map(deploymentObject) ?? alert.id))
        }
        return NowRead(source: source, coverage: complete ? .complete : .partial, needs: needs)
    }

    /// An alert's identity labels: all but its name and the labels an
    /// escalation rewrites, so identity survives a severity change.
    private static func stableLabels(_ alert: FiringAlert) -> String {
        alert.labels.filter { !["alertname", "severity", "page"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }
}
