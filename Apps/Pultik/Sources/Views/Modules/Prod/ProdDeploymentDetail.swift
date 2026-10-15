import SwiftUI

/// A deployment's own content under the detail header (WP7, AC 12; the D4-B
/// frame): its checks, failing first; the day's logs; the Sentry issues and
/// firing alerts; its release line — what runs and what waits to ship
/// (Shipping inside Prod, D9) — and eve's pool accounts. Checks and alerts
/// come from Hlídač's digest, the full issue list from its per-deployment
/// read on selection, the release line from GitHub. A stale or blind card
/// reads its issues and alerts blind, never red.
struct ProdDeploymentDetail: View {
    let store: StatusStore
    let card: ProdGlance.Card

    @State private var detail: Detail?
    @State private var releases: [ReleaseSource: Release] = [:]

    /// Hlídač's per-deployment answer and when it landed: a newer digest
    /// makes the issues it alone lists last known.
    private struct Detail {
        let base: URL
        let deployment: HlidacDigest.Deployment
        let at: Date
        /// The digest generation on screen when it landed: Hlídač serves
        /// both from one cache, so a new generation may have resolved them.
        let generation: Date?
    }

    private struct Release {
        var line: ReleaseLine?
        var fetchedAt: Date?
        var failure: String?
    }

    private var deployment: HlidacDigest.Deployment? { card.deployment }
    private var sources: [ReleaseSource] {
        store.preferences.prodPointers.first { $0.key == card.key }?.releaseSources
            ?? ProdPointer(key: card.key).releaseSources
    }

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 10) {
            checks
            if let hours = card.hours, !hours.isEmpty { logs(hours) }
            issues(now: now)
            alerts(now: now)
            releaseTiles(now: now)
            if let pool = deployment?.pool {
                ProdAccountsTable(pool: pool, now: now, blind: card.stale)
                    .kitTile()
            }
            links
        }
        .task(id: card.key) { await loadDetail() }
        .task(id: sources) { await loadReleases() }
    }

    // MARK: - Loading

    /// The repository's flight outlives this task, so a read for the
    /// previous selection must not land on this one.
    /// It is stamped with the digest generation on screen when it was asked
    /// for: a newer generation landing during the flight makes it last
    /// known at once, never current under the newer one.
    private func loadDetail() async {
        detail = nil
        let base = store.hlidacBase
        let generation = store.prodDigest?.generatedAt
        do {
            let fresh = try await store.hlidacDeployment(card.key)
            try Task.checkCancellation()
            guard let fresh, fresh.key == card.key, base == store.hlidacBase else { return }
            detail = Detail(base: base, deployment: fresh, at: Date(), generation: generation)
        } catch is CancellationError {
        } catch {
            // The digest's card stays the detail.
            NSLog("pultik: hlidac deployment %@ failed: %@", card.key, error.localizedDescription)
        }
    }

    /// Each source draws its last line at once (memory or snapshot), then
    /// revalidates past its schedule. One after another: the GitHub queue
    /// serializes them anyway.
    private func loadReleases() async {
        releases = [:]
        for source in sources {
            await load(source)
        }
    }

    private func load(_ source: ReleaseSource) async {
        for maxAge in [TimeInterval.infinity, StatusStore.ProdDetailResources.release.staleAfter] {
            do {
                let (line, fetchedAt) = try await store.releaseLine(source, maxAge: maxAge)
                try Task.checkCancellation()
                releases[source] = Release(line: line, fetchedAt: fetchedAt)
            } catch is CancellationError {
                return
            } catch {
                NSLog("pultik: release line %@ %@ failed: %@", source.repo, source.environment,
                      error.localizedDescription)
                releases[source, default: Release()].failure = error.localizedDescription
                return
            }
        }
    }

    // MARK: - Checks

    private var checks: some View {
        let failing = card.chips.filter { $0.tone == .red || $0.tone == .orange }
        let rest = card.chips.filter { $0.tone != .red && $0.tone != .orange }
        return Tile(kicker: "Checks", caption: card.status ?? "\(card.chips.count - failing.count)/\(card.chips.count) ok") {
            if card.chips.isEmpty {
                Text(card.tone == .hollow ? "Not monitored — Hlídač reports no checks" : "No checks reported")
                    .font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            } else {
                FlowRow(hSpacing: 6, vSpacing: 6) {
                    ForEach(failing + rest) { chip in checkChip(chip) }
                }
            }
        }
    }

    private func checkChip(_ chip: ProdGlance.Chip) -> Chip {
        Self.chip(chip, pages: deployment?.checks.first { $0.id == chip.id }?.page == true)
    }

    /// A check's chip in its own tone — the Checks tile and the detail's
    /// context band draw a warn check alike, never as failing.
    static func chip(_ chip: ProdGlance.Chip, pages: Bool = false) -> Chip {
        let symbol = pages ? "bell.fill" : nil
        return switch chip.tone {
        case .red: Chip(chip.label, .failing, symbol: symbol)
        case .orange: Chip(chip.label, .warn, symbol: symbol)
        case .green: Chip(chip.label, .passing, symbol: symbol)
        case .blind, .hollow: Chip(chip.label, .dashed, symbol: symbol)
        }
    }

    // MARK: - Logs

    private func logs(_ hours: [HlidacDigest.Hour]) -> some View {
        Tile(kicker: "Logs · 24 h", caption: [card.logsLine, card.edgeLine].compactMap { $0 }.joined(separator: " · ")) {
            HourBars(stacks: hours.map(HourBars.Stack.init), height: 56, barWidth: 6)
                .opacity(card.stale ? 0.6 : 1)
        }
    }

    // MARK: - Issues and alerts

    /// The digest's issues always read as current. The detail's further
    /// issues are current while the digest generation it landed beside is
    /// still on screen; after a newer one they are last known, "as of",
    /// until the deployment is opened again — the detail is never polled.
    @ViewBuilder
    private func issues(now: Date) -> some View {
        let digestIssues = deployment?.sentry ?? []
        let detail = detail.flatMap { $0.deployment.key == card.key && $0.base == store.hlidacBase ? $0 : nil }
        let current = detail.map { $0.generation == store.prodDigest?.generatedAt } ?? false
        let listed = Set(digestIssues.map(\.id))
        let more = current ? [] : (detail?.deployment.sentry ?? []).filter { !listed.contains($0.id) }
        let issues = current ? detail?.deployment.sentry ?? digestIssues : digestIssues
        if !issues.isEmpty || !more.isEmpty {
            let caption = detail == nil ? "\(issues.count) shown · top of the digest"
                : more.isEmpty ? "\(issues.count) open"
                : "\(issues.count) open · \(more.count) more as of \(PultikFormat.clock(detail?.at ?? now))"
            Tile(kicker: "Sentry", caption: caption) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in issueRow(issue, lastKnown: false, now: now) }
                    ForEach(more) { issue in issueRow(issue, lastKnown: true, now: now) }
                }
            }
        }
    }

    private func issueRow(_ issue: HlidacDigest.Issue, lastKnown: Bool, now: Date) -> some View {
        issueRow(tone: card.stale || lastKnown ? Theme.idle : issue.isNew ? Theme.danger : Theme.warn,
                 title: issue.title,
                 meta: "\(issue.shortId) · \(issue.project) · \(issue.count)× · \(issue.users) users"
                     + (issue.isNew ? " · new" : ""),
                 age: PultikFormat.ago(issue.lastSeen, now: now),
                 url: issue.permalink.flatMap(URL.init(string:)), label: "Sentry issue \(issue.shortId)",
                 lastKnown: lastKnown)
    }

    @ViewBuilder
    private func alerts(now: Date) -> some View {
        let alerts = deployment?.alerts ?? []
        if !alerts.isEmpty {
            Tile(kicker: "Firing", caption: "\(alerts.count) alert\(alerts.count == 1 ? "" : "s")") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                        issueRow(tone: card.stale ? Theme.idle : alert.isCritical ? Theme.danger : Theme.warn,
                                 title: alert.summary.isEmpty ? alert.name : alert.summary,
                                 meta: [alert.name, alert.severity, alert.emergency ? "emergency" : nil]
                                     .compactMap { $0 }.joined(separator: " · "),
                                 age: alert.activeAt.map { PultikFormat.ago($0, now: now) } ?? "",
                                 url: alert.url.flatMap(URL.init(string:)), label: "Alert \(alert.name)")
                    }
                }
            }
        }
    }

    private func issueRow(tone: Color, title: String, meta: String, age: String, url: URL?, label: String,
                          lastKnown: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: tone, style: card.stale || lastKnown ? .ring : .solid)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(2)
                Text(meta).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(age).font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
            LinkGlyph(url: url, label: label)
        }
        .opacity(lastKnown ? 0.6 : 1)
    }

    // MARK: - Release line

    @ViewBuilder
    private func releaseTiles(now: Date) -> some View {
        if sources.isEmpty {
            Tile(kicker: "Release") {
                HStack(spacing: 8) {
                    Chip("not tracked", .dashed)
                    Text("No GitHub environment records this deployment's releases")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
                }
            }
        }
        ForEach(sources, id: \.self) { source in
            releaseTile(source, release: releases[source], now: now)
        }
    }

    private func releaseTile(_ source: ReleaseSource, release: Release?, now: Date) -> some View {
        let stale = release?.fetchedAt.map { now.timeIntervalSince($0) > StatusStore.ProdDetailResources.release.staleAfter } ?? false
        let caption = [source.repo, source.environment,
                       stale ? release?.fetchedAt.map { "as of \(PultikFormat.clock($0))" } : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Tile(kicker: "Release", caption: caption) {
            if let line = release?.line {
                ReleaseLineView(line: line, now: now)
                    .opacity(stale ? 0.6 : 1)
            } else if let failure = release?.failure {
                Text("Release line unread — \(failure)").font(Theme.Typo.meta).foregroundStyle(Theme.ink2)
            } else {
                SkeletonBars(widths: [0.55, 0.8, 0.7])
            }
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var links: some View {
        if let links = deployment?.links, !links.isEmpty {
            FlowRow(hSpacing: 14, vSpacing: 6) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button {
                        if let url = URL(string: link.url) { OverviewURL.open(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(link.title)
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                        }
                        .font(Theme.Typo.meta)
                        .foregroundStyle(Theme.ink2)
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                    .accessibilityAddTraits(.isLink)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

/// What a GitHub environment runs against its branch: the live commit, a
/// newer deployment in flight or failed, and the commits waiting to ship.
struct ReleaseLineView: View {
    let line: ReleaseLine
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let live = line.live {
                deployRow(live, tone: Theme.ok, style: .solid, verb: "Live")
            } else {
                HStack(spacing: 8) {
                    Chip("no live deployment", .dashed)
                    Text("None of the last \(ReleaseLine.deploymentLimit) deployments to \(line.source.environment) succeeded")
                        .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            if let latest = line.latest {
                if latest.isFailed {
                    deployRow(latest, tone: Theme.danger, style: .solid, verb: "Failed")
                } else if latest.state != "inactive" {
                    deployRow(latest, tone: Theme.ok, style: .spin, verb: "Deploying")
                }
            }
            waiting
        }
    }

    private func deployRow(_ deploy: ReleaseDeploy, tone: Color, style: StatusDot.Style, verb: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: tone, style: style)
            Text(verb).font(Theme.Typo.title).foregroundStyle(Theme.ink)
            Text(deploy.short).font(Theme.Typo.figure).foregroundStyle(Theme.ink).layoutPriority(1)
            Text([deploy.ref, deploy.creator.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Typo.meta).foregroundStyle(Theme.ink2).lineLimit(1)
            Spacer(minLength: 8)
            Text(PultikFormat.ago(deploy.stateAt ?? deploy.createdAt, now: now))
                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3)
            LinkGlyph(url: deploy.url.flatMap(URL.init(string:)) ?? line.deploymentsURL,
                      label: "Deployment \(deploy.short)")
        }
    }

    @ViewBuilder
    private var waiting: some View {
        if let waiting = line.waiting {
            if waiting == 0 {
                Text("Up to date with \(line.branch)").font(Theme.Typo.meta).foregroundStyle(Theme.ok)
            } else {
                Text("\(waiting) commit\(waiting == 1 ? "" : "s") on \(line.branch) wait to ship")
                    .font(Theme.Typo.title).monospacedDigit().foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(line.commits) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(commit.short).font(Theme.Typo.figure).foregroundStyle(Theme.ink3).layoutPriority(1)
                            Text(commit.headline).font(Theme.Typo.meta).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text([commit.author, PultikFormat.ago(commit.committedAt, now: now)].compactMap { $0 }
                                .joined(separator: " · "))
                                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                    }
                    if waiting > line.commits.count {
                        Text("+\(waiting - line.commits.count) older").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
        if let ahead = line.ahead, ahead > 0 {
            Text("Live carries \(ahead) commit\(ahead == 1 ? "" : "s") not on \(line.branch)")
                .font(Theme.Typo.meta).foregroundStyle(Theme.warn)
        }
    }
}
