import Foundation

/// The warm set's rules (stay in Pultík D9), Foundation-only so
/// `Tests/WarmSetTests.swift` drives them against a fake host and a
/// disposable snapshot store: which change requests are warm, when a held
/// conversation answers an open without a request, and one sync.
enum WarmSet {
    /// Everything the index saw updated this recently stays warm.
    static let window: TimeInterval = 48 * 3600
    /// Newest first; the rest wait for an explicit open.
    static let limit = 150
    /// Diffs computed per mirror pass: one pass never monopolises the box.
    static let mirrorBatch = 8
    /// A conversation read this recently is current whatever the index says.
    static let fresh: TimeInterval = 30

    /// Every change request in the window and in `scope` (lowercased repo
    /// slugs), newest first.
    static func candidates(_ records: [ArchivedPR], scope: Set<String>,
                           now: Date) -> [(ref: ChangeRequestRef, updatedAt: Date)] {
        records
            .filter { now.timeIntervalSince($0.updatedAt) < window && scope.contains($0.repoSlug.lowercased()) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { (ChangeRequestRef(repo: $0.repoSlug, number: $0.number), $0.updatedAt) }
    }

    /// A held conversation answers an open without a request (AC 10) while
    /// the index has not seen the request move past it and its checks are
    /// settled — running checks belong to the CI watch, which confirms them.
    static func isCurrent(_ request: ChangeRequest, fetchedAt: Date, indexed: Date?, now: Date) -> Bool {
        isCurrent(updatedAt: request.updatedAt, settled: !request.checks.contains { $0.outcome == .running },
                  fetchedAt: fetchedAt, indexed: indexed, now: now)
    }

    /// The same rule for anything read beside the conversation (the PR
    /// workbench's activity): `settled` is false while the read held state
    /// the host can still move without moving `updatedAt`.
    static func isCurrent(updatedAt: Date, settled: Bool, fetchedAt: Date, indexed: Date?, now: Date) -> Bool {
        if now.timeIntervalSince(fetchedAt) < fresh { return true }
        guard let indexed else { return false }
        return updatedAt >= indexed && settled
    }

    /// One sync. `ledger` is the `updatedAt` each request was synced at this
    /// run; an empty ledger first learns what the disk holds. What moved is
    /// read through `host` in its batches and written to disk only. Returns
    /// every settled request, for the mirror.
    @MainActor
    static func sync(_ candidates: [(ref: ChangeRequestRef, updatedAt: Date)], ledger: inout [ChangeRequestRef: Date],
                     host: any CodeHost, identity: String, repository: QueryRepository,
                     resource: QueryResource<ChangeRequest>, key: (ChangeRequestRef) -> QueryKey) async throws
        -> [ChangeRequest] {
        var stale: [ChangeRequestRef] = []
        var settled: [ChangeRequest] = []
        for candidate in candidates {
            if let synced = ledger[candidate.ref], synced >= candidate.updatedAt { continue }
            if ledger[candidate.ref] == nil,
               let held = await repository.held(resource, key: key(candidate.ref), remember: false),
               held.value.updatedAt >= candidate.updatedAt {
                ledger[candidate.ref] = held.value.updatedAt
                settled.append(held.value)
                continue
            }
            stale.append(candidate.ref)
        }
        guard !stale.isEmpty else { return settled }
        let answer = try await host.changeRequests(stale, identity: identity)
        let at = Date()
        var writes: [Task<Void, Never>] = []
        for ref in stale {
            guard let request = answer[ref] else { continue }
            if let write = repository.persist(resource, key: key(ref), value: request, at: at) { writes.append(write) }
            ledger[ref] = request.updatedAt
            settled.append(request)
        }
        for write in writes { await write.value }
        return settled
    }
}
