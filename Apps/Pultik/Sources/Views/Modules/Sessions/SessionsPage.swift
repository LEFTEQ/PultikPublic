import SwiftUI

/// The Sessions module's list (WP7, AC 11): this Mac's agent sessions from
/// Toolkit's fleet snapshot waiting on you, then eve's workflows parked on an
/// approval, then working and idle sessions, eve's notifications in the
/// watched lanes, and the vitrinka board listeners. Each row is the same
/// object Now's waiting lane opens (`session:<id>`, `approval:<root>`,
/// `eve-alert:<id>`); a session's primary verb is Focus, which brings cmux
/// to its surface, and an approval is answered on eve's own page (⌘↵).
struct SessionsPage: View {
    let fleet: FleetStore
    /// eve's state: approvals, notifications and how current they are.
    let store: StatusStore
    let listeners: [VitrinkaListening]
    let filter: String
    var selectedID: String?
    /// A click selects the row and opens its detail — never Focus.
    var onOpen: (String) -> Void = { _ in }

    /// The fleet's sections in drawn order; dead and ended sessions are
    /// `toolkit fleet revive`'s, not a list to walk.
    private var sections: [(title: String, sessions: [FleetSession])] {
        let all = (fleet.snapshot?.sessions ?? []).filter(matches)
        return [("Waiting on you", all.filter { $0.state == .waiting }.sorted { $0.statusSince < $1.statusSince }),
                ("Working", all.filter { $0.state == .busy }),
                ("Idle", all.filter { $0.state == .idle || $0.state == .shell })]
            .filter { !$0.sessions.isEmpty }
    }

    private func matches(_ session: FleetSession) -> Bool {
        matches([session.name, session.project, session.waitingFor, session.cwd])
    }

    private func matches(_ fields: [String?]) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return fields.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private var approvals: [EveApproval] {
        store.eveApprovals.filter { approval in
            matches([approval.title, approval.flow, approval.repo] + approval.parked.flatMap { [$0.title, $0.tool] })
        }
    }

    /// The watched lanes' notifications inside Now's window: the ones Now's
    /// rows open.
    private var notifications: [EveAlert] {
        let floor = Date().addingTimeInterval(-NowWindow.span)
        return store.visibleAlerts.filter { $0.ts >= floor && matches([$0.title, $0.flow, $0.category]) }
    }

    /// eve's rows are last known, not live (`StatusStore.eveLastKnownAt`).
    private var eveAsOf: Date? { store.eveLastKnownAt }

    var body: some View {
        let now = Date()
        let stale = fleet.isStale(now: now)
        SelectionScrollView(selection: selectedID) {
            VStack(alignment: .leading, spacing: 2) {
                if let snapshot = fleet.snapshot, stale {
                    RailNote("As of \(PultikFormat.clock(snapshot.generatedAt)) — toolkit fleet is not publishing")
                        .padding(.top, 10)
                } else if fleet.snapshot == nil {
                    RailNote("No fleet snapshot — toolkit fleet is not publishing")
                        .padding(.top, 10)
                }
                let sections = sections
                ForEach(sections.prefix { $0.title == "Waiting on you" }, id: \.title) { fleetSection($0, stale: stale, now: now) }
                approvalsSection(now: now)
                ForEach(sections.filter { $0.title != "Waiting on you" }, id: \.title) { fleetSection($0, stale: stale, now: now) }
                notificationsSection(now: now)
                if !listeners.isEmpty {
                    Kicker(text: "Board listeners", count: listeners.count)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                    ForEach(listeners) { entry in
                        VitrinkaListRow(entry: entry, selected: selectedID == "vit:\(entry.id)")
                            .opacity(ResolvedStore.shared.isResolved("vit:\(entry.id)") ? 0.35 : 1)
                            .id("vit:\(entry.id)")
                    }
                }
            }
            .padding(8)
        }
    }

    private func fleetSection(_ section: (title: String, sessions: [FleetSession]), stale: Bool, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Kicker(text: section.title, count: section.sessions.count,
                   tone: section.title == "Waiting on you" ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.top, 10)
            ForEach(section.sessions, id: \.sessionId) { session in
                let id = Self.objectID(session)
                ListRow(title: session.name ?? session.project, id: session.project,
                        meta: Text(verbatim: Self.meta(session, now: now)), selected: selectedID == id,
                        action: { onOpen(id) }) {
                    Self.dot(session, stale: stale)
                }
                .opacity(stale ? 0.6 : 1)
                .id(id)
            }
        }
    }

    @ViewBuilder
    private func approvalsSection(now: Date) -> some View {
        let approvals = approvals
        if !approvals.isEmpty {
            let asOf = eveAsOf
            Kicker(text: "eve approvals", count: approvals.count, tone: .orange)
                .padding(.horizontal, 8)
                .padding(.top, 10)
            if let asOf { RailNote("As of \(PultikFormat.clock(asOf)) — eve has not answered since") }
            ForEach(approvals) { approval in
                let id = EveApproval.objectID(approval.rootID)
                ListRow(title: approval.title, id: Self.approvalLabel(approval),
                        meta: Text(verbatim: Self.approvalMeta(approval, now: now)), selected: selectedID == id,
                        action: { onOpen(id) }) {
                    asOf == nil && !approval.display.stalled
                        ? StatusDot(tone: Theme.warn, style: .pulse) : StatusDot(tone: Theme.ink3, style: .ring)
                }
                .opacity(asOf == nil ? 1 : 0.6)
                .id(id)
            }
        }
    }

    @ViewBuilder
    private func notificationsSection(now: Date) -> some View {
        let notifications = notifications
        if !notifications.isEmpty {
            Kicker(text: "eve notifications", count: notifications.count)
                .padding(.horizontal, 8)
                .padding(.top, 10)
            ForEach(notifications) { alert in
                let id = Self.objectID(alert)
                ListRow(title: alert.title, id: alert.flow,
                        meta: Text(verbatim: "\(alert.category) · \(PultikFormat.ago(alert.ts, now: now))"),
                        selected: selectedID == id, action: { onOpen(id) }) {
                    StatusDot(tone: alert.severity == .critical ? Theme.danger
                        : alert.severity == .warning ? Theme.warn : Theme.ink3)
                }
                .id(id)
            }
        }
    }

    static func objectID(_ session: FleetSession) -> String { "session:\(session.sessionId)" }
    static func objectID(_ alert: EveAlert) -> String { "eve-alert:\(alert.id)" }

    /// `owner/repo#12` when the workflow is about a PR, else its flow.
    static func approvalLabel(_ approval: EveApproval) -> String {
        if let repo = approval.repo, let number = approval.prNumber { return "\(repo)#\(number)" }
        return approval.flow ?? "eve"
    }

    /// `approve open_pr · updated 3h ago`, `· 2 parked` when more wait.
    static func approvalMeta(_ approval: EveApproval, now: Date) -> String {
        let node = approval.display
        return [node.tool.map { "approve \($0)" } ?? node.title,
                node.stalled ? "stalled" : "updated \(PultikFormat.ago(node.updatedAt, now: now))",
                approval.parked.count > 1 ? "\(approval.parked.count) parked" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// `input needed · 3h` for a waiting one, the working directory's last
    /// path components otherwise.
    static func meta(_ session: FleetSession, now: Date) -> String {
        let age = PultikFormat.duration(now.timeIntervalSince(session.statusSince))
        switch session.state {
        case .waiting: return "\(session.waitingFor ?? "waiting on you") · \(age)"
        case .busy: return "working · \(age)"
        default: return "\(URL(fileURLWithPath: session.cwd).lastPathComponent) · idle \(age)"
        }
    }

    /// A stale snapshot draws no live signal: last known, hollow.
    @ViewBuilder
    static func dot(_ session: FleetSession, stale: Bool) -> some View {
        switch (stale, session.state) {
        case (false, .waiting): StatusDot(tone: Theme.warn, style: .pulse)
        case (false, .busy): StatusDot(tone: Theme.ok, style: .spin)
        default: StatusDot(tone: Theme.ink3, style: .ring)
        }
    }
}

extension SessionsPage: ModulePage {
    var objects: [ModuleObject] {
        let now = Date()
        let stale = fleet.isStale(now: now)
        let asOf = fleet.snapshot.map { "as of \(PultikFormat.clock($0.generatedAt))" } ?? "not publishing"
        let shell = SessionShell.installed
        let sessions = { (session: FleetSession) -> ModuleObject in
            var facts = [ModuleObject.Fact(label: "project", value: session.project),
                         .init(label: "directory", value: session.cwd),
                         .init(label: session.state == .waiting ? "waiting" : "since",
                               value: PultikFormat.ago(session.statusSince, now: now))]
            if let worktree = session.worktree { facts.append(.init(label: "worktree", value: worktree)) }
            if let started = session.startedAt { facts.append(.init(label: "started", value: PultikFormat.ago(started, now: now))) }
            if let version = session.version { facts.append(.init(label: "version", value: version)) }
            facts.append(.init(label: "resume", value: session.resume))
            let status: Chip = switch (stale, session.state) {
            case (true, _): Chip(asOf, .dashed, symbol: "clock")
            case (false, .waiting): Chip(session.waitingFor ?? "waiting on you", .warn)
            case (false, .busy): Chip("working", .ok)
            default: Chip("idle", .neutral)
            }
            var verbs: [DetailVerb] = []
            if session.actions.contains(.focus) {
                verbs.append(DetailVerb(title: "Focus", symbol: "macwindow", role: .primary,
                                        help: "Bring cmux to this session's surface") { fleet.focus(session) })
            }
            // The fleet cannot say which shell runs a session, so the agent
            // shell is offered wherever it is installed; it leads where cmux
            // cannot focus the session (workbench WP6).
            if let shell = shell {
                verbs.append(DetailVerb(title: "Open in \(shell.name)", symbol: "point.3.connected.trianglepath.dotted",
                                        role: session.actions.contains(.focus) ? .normal : .primary,
                                        help: "Fly \(shell.name)'s canvas to this session") {
                    SessionShell.open(session.sessionId, in: shell)
                })
            }
            return ModuleObject(id: Self.objectID(session), title: session.name ?? session.project,
                                label: session.project, status: status, meta: Self.meta(session, now: now),
                                symbol: "terminal", project: session.project, verbs: verbs, facts: facts)
        }
        // The drawn order: waiting sessions, approvals, working and idle,
        // notifications, listeners.
        let groups = sections
        let waiting = groups.prefix { $0.title == "Waiting on you" }.flatMap(\.sessions)
        let rest = groups.filter { $0.title != "Waiting on you" }.flatMap(\.sessions)
        return waiting.map(sessions) + approvalObjects(now: now) + rest.map(sessions)
            + notificationObjects(now: now) + VitrinkaAllView(entries: listeners, onBack: {}).objects
    }

    private func approvalObjects(now: Date) -> [ModuleObject] {
        let asOf = eveAsOf
        return approvals.map { approval in
            let node = approval.display
            var facts = [ModuleObject.Fact(label: "workflow", value: approval.rootID)]
            if let flow = approval.flow { facts.append(.init(label: "flow", value: flow)) }
            facts.append(.init(label: "answers", value: node.id))
            if let tool = node.tool { facts.append(.init(label: "tool", value: tool)) }
            facts.append(.init(label: "updated", value: PultikFormat.ago(node.updatedAt, now: now)))
            let status: Chip = if let asOf {
                Chip("as of \(PultikFormat.clock(asOf))", .dashed, symbol: "clock")
            } else if node.stalled {
                Chip("stalled · survived an eve restart", .dashed)
            } else {
                Chip("waiting on you", .warn)
            }
            return ModuleObject(id: EveApproval.objectID(approval.rootID), title: approval.title,
                                label: Self.approvalLabel(approval), status: status,
                                meta: Self.approvalMeta(approval, now: now), symbol: "hand.raised",
                                project: "eve", url: approval.url, facts: facts)
        }
    }

    private func notificationObjects(now: Date) -> [ModuleObject] {
        notifications.map { alert in
            let status: Chip = switch alert.severity {
            case .critical: Chip("critical", .danger)
            case .warning: Chip("warning", .warn)
            case nil: Chip(alert.category, .neutral)
            }
            return ModuleObject(id: Self.objectID(alert), title: alert.title, label: alert.flow, status: status,
                                meta: "\(alert.category) · \(PultikFormat.ago(alert.ts, now: now))",
                                symbol: "bell", project: "eve",
                                facts: [.init(label: "lane", value: alert.category),
                                        .init(label: "sent", value: PultikFormat.ago(alert.ts, now: now))])
        }
    }

    /// An approval's parked nodes, deepest first, and the notification's
    /// body; a session's detail is its header and context alone.
    @ViewBuilder
    func detailContent(for object: ModuleObject) -> some View {
        if let approval = store.eveApprovals.first(where: { EveApproval.objectID($0.rootID) == object.id }) {
            Tile(kicker: "Parked", caption: "\(approval.parked.count) waiting on you") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approval.parked, id: \.id) { node in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StatusDot(tone: node.stalled ? Theme.ink3 : Theme.warn, style: node.stalled ? .ring : .solid)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).font(Theme.Typo.body).foregroundStyle(Theme.ink).lineLimit(2)
                                Text(verbatim: [node.tool.map { "approve \($0)" }, node.id].compactMap { $0 }
                                    .joined(separator: " · "))
                                    .font(Theme.Typo.figure).foregroundStyle(Theme.ink3).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(PultikFormat.ago(node.updatedAt, now: Date()))
                                .font(Theme.Typo.meta).monospacedDigit().foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
        } else if let alert = store.visibleAlerts.first(where: { Self.objectID($0) == object.id }), !alert.body.isEmpty {
            Tile(kicker: "Message") {
                Text(alert.body).font(Theme.Typo.body).foregroundStyle(Theme.ink2).textSelection(.enabled)
            }
        }
    }
}
