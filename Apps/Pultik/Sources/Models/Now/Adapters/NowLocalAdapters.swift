import Foundation

// This Mac's own sources: Toolkit's health report and the expiry radar.

extension NowAdapters {
    /// `MacHealthStatus.staleAfter`: three missed 60 s publishes.
    static let macReportStaleAfter: TimeInterval = 180

    /// Toolkit's findings from their own `since`: a stop candidate waits on
    /// you, anything else drifts; red is a warning, amber and info normal,
    /// ok no need. Red marks a likely orphan, not an outage — never critical,
    /// so a dozen orphans fold into one row (D15) instead of flooding the
    /// lane. A stale report (`toolkit watch` stopped) is a failed read — it
    /// shows nothing and clears nothing.
    static func macFindings(_ report: NowInputs.MacReport?, machine: String, now: Date) -> NowRead {
        let source = NowSource(feed: .macHealth, identity: machine)
        guard let report, now.timeIntervalSince(report.generatedAt) <= macReportStaleAfter else { return failed(source) }
        let needs = report.findings.compactMap { finding -> NowNeed? in
            let severity: NowSeverity
            switch finding.severity {
            case .red: severity = .warning
            case .amber, .info: severity = .normal
            case .ok: return nil
            }
            let key = "mac:\(machine):finding:\(finding.id)"
            return NowNeed(
                needID: key, incidentKey: key, kind: .macFinding,
                lane: finding.stopSupported ? .waitingOnYou : .drifting, severity: severity,
                onset: .exact(finding.since), title: finding.title, subtitle: finding.detail,
                verb: finding.stopSupported ? NowVerb(title: "Stop…", destructive: true) : .open("Inspect finding"),
                target: NowTarget(module: .estate, objectID: "finding:\(finding.id)"))
        }
        return NowRead(source: source, coverage: .complete, needs: needs)
    }

    /// A watched expiry is due from `expiry − lead`, with the expiry itself
    /// as the deadline marker: critical once past, a warning inside three
    /// days. An item with no date yet makes the read partial.
    static func expiries(_ items: [NowInputs.Expiry]?, now: Date) -> NowRead {
        let source = NowSource(feed: .expiryRadar, identity: "settings")
        guard let items else { return failed(source) }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        var unknown = false
        var needs: [NowNeed] = []
        for item in items {
            guard let expiry = item.expiry else {
                unknown = true
                continue
            }
            let windowStart = expiry.addingTimeInterval(-item.lead)
            guard windowStart <= now else { continue }
            let left = expiry.timeIntervalSince(now)
            let key = "expiry:\(item.id):\(day.string(from: expiry))"
            needs.append(NowNeed(
                needID: key, incidentKey: key, kind: .expiry, lane: .due,
                severity: left <= 0 ? .critical : left <= 3 * 86400 ? .warning : .normal,
                onset: .exact(windowStart), title: item.label, verb: .open("Inspect renewal"),
                target: NowTarget(module: .estate, objectID: item.id), deadline: expiry))
        }
        return NowRead(source: source, coverage: unknown ? .partial : .complete, needs: needs)
    }
}
