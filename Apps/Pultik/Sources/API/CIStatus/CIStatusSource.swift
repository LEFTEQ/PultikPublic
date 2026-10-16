import Foundation

/// Where live CI status comes from (stay in Pultík D7): our own CI first —
/// free mesh reads that carry the lane and its queue — with the CI host
/// asked only to confirm a transition. A Semafor push stream replaces the
/// mesh source behind this protocol without touching a view.
protocol CIStatusSource: Sendable {
    /// What our CI is doing for `runs` right now.
    func snapshot(for runs: Set<CIRunRef>) async throws -> CIStatusSnapshot
}

/// One read of our CI: the jobs running per run, every lane's backlog.
struct CIStatusSnapshot: Equatable, Sendable {
    var jobs: [Int: [CILiveJob]] = [:]
    var queued: [String: Int] = [:]
    /// The lane each host's pool places next, from every Semafor that
    /// answered — one head per host, never one global queue.
    var next: Set<String> = []
    var observedAt = Date()

    /// Equal by what the badges draw, not by when it was read.
    static func == (lhs: CIStatusSnapshot, rhs: CIStatusSnapshot) -> Bool {
        lhs.jobs == rhs.jobs && lhs.queued == rhs.queued && lhs.next == rhs.next
    }
}

/// A job our CI runs right now.
struct CILiveJob: Equatable, Hashable, Sendable {
    let name: String
    let lane: String
    let since: Date?
}

/// The watch's rules (AC 6), Foundation-only: `Tests/CIWatchTests.swift`.
enum CIWatch {
    static let lane = "ci-watch"
    static let interval: TimeInterval = 5
    /// Jobs our CI cannot see (GitHub-hosted runners) are confirmed this often.
    static let hostedConfirm: TimeInterval = 30

    /// `…/actions/runs/123` or `…/actions/runs/123/job/456` → 123.
    static func runID(in url: URL?) -> Int? {
        guard let parts = url?.pathComponents, let index = parts.firstIndex(of: "runs"),
              parts.indices.contains(index + 1) else { return nil }
        return Int(parts[index + 1])
    }

    /// The runs whose jobs on our CI changed between two reads — a job
    /// started, or left because it finished. The first read is no
    /// transition: it is the baseline the next read is judged against.
    static func transitions(from old: CIStatusSnapshot?, to new: CIStatusSnapshot, runs: Set<Int>) -> Set<Int> {
        guard let old else { return [] }
        return Set(runs.filter { Set(old.jobs[$0] ?? []) != Set(new.jobs[$0] ?? []) })
    }

    /// Ask the host now: a transition, or a running check our CI does not
    /// show and the last confirm is `hostedConfirm` old.
    static func needsConfirm(transitions: Set<Int>, running: Set<Int>, seen: CIStatusSnapshot,
                             confirmedAt: Date?, now: Date) -> Bool {
        if !transitions.isEmpty { return true }
        let unseen = running.contains { (seen.jobs[$0] ?? []).isEmpty }
        guard unseen else { return false }
        return confirmedAt.map { now.timeIntervalSince($0) >= hostedConfirm } ?? true
    }
}
