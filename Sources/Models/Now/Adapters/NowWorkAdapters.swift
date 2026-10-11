import Foundation

// The operator's work sources: eve's notification ledger, stale PRs, ripe
// vitrinka todos and stale Devbox workspaces. Ordinary state — running
// checks, generic awaiting reviews, parked-but-fresh workspaces — never
// becomes a need.

extension NowAdapters {
    /// eve's notifications ledger in the lanes the operator watches: a
    /// critical one is on fire, a warning drifts, one without a severity is
    /// not known to be actionable. Onset is the notification's creation.
    /// The ledger is append-only and capped at 50, so an omission never
    /// closes a need (always `.partial`): one past the cap stays open; a
    /// notification older than the Now window ages out instead
    /// (`NowFeed.horizon`).
    /// `account` is the credential's digest: another token is another view.
    static func eveNotifications(_ alerts: [EveAlert]?, lanes: Set<String>, origin: String, account: String,
                                 now: Date) -> NowRead {
        let source = NowSource(feed: .eveNotifications, identity: "\(origin)/\(account)")
        guard let alerts else { return failed(source) }
        let floor = now.addingTimeInterval(-NowAxis.window)
        let needs = alerts.compactMap { alert -> NowNeed? in
            guard lanes.contains(alert.category), let severity = alert.severity, alert.ts >= floor else { return nil }
            let key = "eve:\(origin):notification:\(alert.id)"
            // eve repeats an alert while it holds ("codex: 5% capacity left" ×5):
            // one title in one lane is one incident, its bar from the first.
            let incident = "eve:\(origin):notification-title:\(alert.category):\(alert.title.lowercased())"
            let critical = severity == .critical
            return NowNeed(needID: key, incidentKey: incident, kind: .eveNotification, lane: critical ? .onFire : .drifting,
                           severity: critical ? .critical : .warning, onset: .exact(alert.ts), title: alert.title,
                           // A flow named like its lane ("priority · priority") is said once.
                           subtitle: (alert.flow.map { $0 == alert.category ? [$0] : [$0, alert.category] }
                               ?? [alert.category]).joined(separator: " · "),
                           verb: .open("Inspect notification"),
                           target: NowTarget(module: .sessions, objectID: "eve-alert:\(alert.id)"))
        }
        return NowRead(source: source, coverage: .partial, needs: needs)
    }

    /// A non-draft PR nothing else asks you about (`PRDigest`'s ready set),
    /// untouched for `PRDigest.staleAfter`: it drifts from `updatedAt + 7 d`.
    /// A repo whose estate read failed, or that filled the estate's capped
    /// open list (the least recently touched — the stale ones — fall off
    /// first), makes the read partial.
    static func stalePRs(_ repos: [RepoStatus]?, host: String = "github.com", login: String, now: Date) -> NowRead {
        let source = NowSource(feed: .githubStalePRs, identity: "\(host)/\(login)")
        guard let repos else { return failed(source) }
        var needs: [NowNeed] = []
        for repo in repos {
            for info in repo.prs where !info.isDraft && info.attentionRank >= 2 {
                guard let updated = info.pr.updatedAt else { continue }
                let staleAt = updated.addingTimeInterval(PRDigest<PRInfo>.staleAfter)
                guard staleAt <= now else { continue }
                let incident = "github:\(host):\(repo.slug):pr:\(info.pr.number)"
                needs.append(NowNeed(
                    needID: "\(incident):stale", incidentKey: incident, kind: .stalePR, lane: .drifting,
                    severity: .normal, onset: .exact(staleAt), title: info.pr.title, subtitle: repo.slug,
                    displayID: "#\(info.pr.number)", verb: .open("Inspect PR"),
                    target: NowTarget(module: .prs, objectID: "pr:\(info.pr.id)", url: info.pr.htmlUrl)))
            }
        }
        let partial = repos.contains { $0.error != nil || $0.prs.count >= GitHubEstate.openLimit }
        return NowRead(source: source, coverage: partial ? .partial : .complete, needs: needs)
    }

    /// Open vitrinka todos past their `ripeAt` (dueAt − lead, default 2 h)
    /// are due from that instant; overdue raises the severity and keeps the
    /// onset. A milestone-ripened todo has no clock: first observed. Each
    /// occurrence is its own need under the task's row, and todos due at the
    /// same instant share a ×N series. `account` is the sign-in's digest.
    static func ripeTodos(_ todos: [NowInputs.Todo]?, origin: String, workspace: String, account: String,
                          now: Date) -> NowRead {
        let source = NowSource(feed: .vitrinkaTodos, identity: "\(origin)/\(workspace)/\(account)")
        guard let todos else { return failed(source) }
        let scope = "vitrinka:\(origin):\(workspace)"
        let needs = todos.compactMap { todo -> NowNeed? in
            guard todo.status != "done", todo.status != "cancelled" else { return nil }
            let ripeAt = todo.dueAt?.addingTimeInterval(-(todo.lead ?? NowInputs.Todo.defaultLead))
            let onset: NowOnset
            if let ripeAt, ripeAt <= now {
                onset = .exact(ripeAt)
            } else if todo.reason == "milestone" {
                onset = .observed(now)
            } else {
                return nil
            }
            let due = todo.dueAt.map { String(Int($0.timeIntervalSince1970)) }
            let task = "\(scope):task:\(todo.id)"
            return NowNeed(
                needID: "\(task):occurrence:\(due ?? "milestone")", incidentKey: task, kind: .reminder, lane: .due,
                severity: (todo.dueAt.map { $0 <= now } ?? false) ? .warning : .normal, onset: onset,
                title: todo.title, subtitle: todo.project, displayID: todo.key, verb: NowVerb(title: "Complete todo…"),
                target: NowTarget(module: .work, objectID: "task:\(todo.id)", url: todo.url),
                deadline: todo.dueAt, seriesKey: due.map { "\(scope):due:\($0)" })
        }
        return NowRead(source: source, coverage: .complete, needs: needs)
    }

    /// An unheld parked workspace drifts from `parkedAt + DevboxGlance.staleAfter`
    /// (what `gc --retire-stale` would clear); held, hot and fresh ones never
    /// enter Now. `complete` is false when a box did not answer — its
    /// workspaces are missing, not gone.
    static func staleWorkspaces(_ workspaces: [DevboxWorkspace]?, complete: Bool = true, now: Date) -> NowRead {
        let source = NowSource(feed: .devboxStale, identity: "devbox")
        guard let workspaces else { return failed(source) }
        let needs = workspaces.compactMap { workspace -> NowNeed? in
            guard workspace.isParked, !workspace.hold, let parkedAt = workspace.parkedAt else { return nil }
            let staleAt = parkedAt.addingTimeInterval(DevboxGlance.staleAfter)
            guard staleAt < now else { return nil }
            let box = workspace.box?.name ?? DevboxEndpoint.fallback.name
            let incident = "devbox:\(box):workspace:\(workspace.name):stale"
            return NowNeed(
                needID: "\(incident):\(Int(parkedAt.timeIntervalSince1970))", incidentKey: incident,
                kind: .staleWorkspace, lane: .drifting, severity: .normal, onset: .exact(staleAt),
                title: workspace.name, subtitle: workspace.project.map { "\($0) · devbox \(box)" } ?? "devbox \(box)",
                verb: NowVerb(title: "Clear this…", destructive: true),
                target: NowTarget(module: .devbox, objectID: "ws:\(workspace.id)"))
        }
        return NowRead(source: source, coverage: complete ? .complete : .partial, needs: needs)
    }
}
