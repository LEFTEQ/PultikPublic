import Foundation

// Agent sessions waiting on the operator (copilot shell WP7, AC 11): Toolkit's
// fleet snapshot, read from this Mac's disk.

extension NowInputs {
    /// The fleet snapshot as Now reads it: when it was written, whether cmux
    /// could see every surface, and the sessions.
    struct Fleet: Equatable, Sendable {
        let generatedAt: Date
        /// cmux answered: a waiting dialog on a surface it cannot see would
        /// read as busy, so anything else makes the read partial.
        let complete: Bool
        let sessions: [FleetSession]
    }

    struct FleetSession: Equatable, Sendable {
        let id: String
        let name: String?
        let project: String
        let waiting: Bool
        /// The process is not proven gone (alive, or liveness unknown).
        let alive: Bool
        let waitingFor: String?
        let since: Date
    }
}

extension NowAdapters {
    /// `toolkit fleet` rewrites its snapshot every few seconds while its
    /// watcher runs; older than this, nobody is publishing.
    static let fleetStaleAfter: TimeInterval = 120

    /// A live session waiting on the operator waits on you from the moment
    /// it started waiting — an agent blocked on you outranks your own failed
    /// CI (`blockedRequest`). A warning, so a crowd of waiting sessions folds
    /// into one row (D15). A stale snapshot is a failed read: it clears nothing.
    static func sessionsWaiting(_ fleet: NowInputs.Fleet?, machine: String, now: Date) -> NowRead {
        let source = NowSource(feed: .fleetSessions, identity: machine)
        guard let fleet, now.timeIntervalSince(fleet.generatedAt) <= fleetStaleAfter else { return failed(source) }
        let needs = fleet.sessions.filter { $0.waiting && $0.alive }.map { session in
            let key = "session:\(machine):\(session.id)"
            return NowNeed(
                needID: key, incidentKey: key, kind: .sessionWaiting, lane: .waitingOnYou, severity: .warning,
                onset: .exact(session.since), title: session.name ?? session.project,
                subtitle: [session.project, session.waitingFor ?? "waiting on you"].joined(separator: " · "),
                verb: .open("Open session"), target: NowTarget(module: .sessions, objectID: "session:\(session.id)"),
                waiterRank: .blockedRequest)
        }
        return NowRead(source: source, coverage: fleet.complete ? .complete : .partial, needs: needs)
    }

    /// eve workflows parked on an operator approval. The list is eve's own
    /// Approvals page, unpaginated, so an answer is complete: a node it stops
    /// listing was answered or dismissed. Each parked node is a need and its
    /// workflow root the incident, so two parked subagents of one workflow
    /// are one row. No onset rides the list (the request's time lives in the
    /// root's event stream), so a need starts hollow at its first
    /// observation. An agent blocked on you outranks your own failed CI; a
    /// stalled node parked over a week drifts instead (`Node.drifts`).
    static func eveApprovals(_ approvals: [EveApproval]?, origin: String, account: String, now: Date) -> NowRead {
        let source = NowSource(feed: .eveApprovals, identity: "\(origin)/\(account)")
        guard let approvals else { return failed(source) }
        let needs = approvals.flatMap { approval in
            approval.parked.map { node in
                NowNeed(
                    needID: "eve:\(origin):approval:\(node.id)", incidentKey: "eve:\(origin):workflow:\(approval.rootID)",
                    kind: .eveApproval, lane: node.drifts(now: now) ? .drifting : .waitingOnYou, severity: .warning,
                    onset: .observed(now),
                    title: approval.title,
                    subtitle: [approval.flow ?? "eve", node.tool.map { "approve \($0)" } ?? "approval",
                               node.stalled ? "stalled" : nil].compactMap { $0 }.joined(separator: " · "),
                    verb: .open("Open approval"),
                    target: NowTarget(module: .sessions, objectID: EveApproval.objectID(approval.rootID),
                                      url: approval.url.absoluteString),
                    waiterRank: .blockedRequest)
            }
        }
        return NowRead(source: source, coverage: .complete, needs: needs)
    }
}
