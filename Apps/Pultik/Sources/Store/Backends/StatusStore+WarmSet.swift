import Foundation

/// The warm set (stay in Pultík D9): every change request the index saw
/// updated in the last 48 hours — open, merged or closed — kept on disk, so
/// a PR opens instantly from search, Home or the list, also right after a
/// launch. It rides the GitHub lane (no second poller): after each estate
/// read the conversations whose `updatedAt` moved are re-read in batches of
/// ten, in the background budget, and new heads get their diff from the git
/// mirror (D10) in one background pass at a time.
extension StatusStore {
    /// Every change request in the window, newest first (`WarmSet`).
    func warmCandidates(now: Date = Date()) -> [(ref: ChangeRequestRef, updatedAt: Date)] {
        WarmSet.candidates(prIndex.records.values.map(\.pr), scope: Set(searchableRepos.map { $0.lowercased() }), now: now)
    }

    /// One sync: learn what the disk holds (first pass after a launch),
    /// re-read what moved, queue new heads for the mirror. GitHub failures
    /// here never feed the lane's breaker — the estate read alone decides it.
    func syncWarmSet(now: Date = Date()) async {
        guard let identity = prIndexIdentity else { return }
        var ledger = warmUpdatedAt
        do {
            let settled = try await WarmSet.sync(warmCandidates(now: now), ledger: &ledger, host: codeHost,
                                                 identity: identity, repository: .shared,
                                                 resource: PRDetailResources.conversation) { [self] ref in
                conversationKey(ref, identity: identity)
            }
            guard identity == prIndexIdentity else { return }
            warmUpdatedAt.merge(ledger) { max($0, $1) }
            warmSyncedAt = Date()
            warmMirror(settled)
        } catch is CancellationError {
            return
        } catch {
            warmUpdatedAt.merge(ledger) { max($0, $1) }
            NSLog("pultik: warm set sync failed: %@", error.localizedDescription)
        }
    }

    /// Queues `requests` whose diff is not on disk for the mirror, and starts
    /// the one pass that works the queue, newest first.
    func warmMirror(_ requests: [ChangeRequest]) {
        guard let identity = prIndexIdentity else { return }
        let queued = Set(warmMirrorQueue.map { filesKey($0, identity: identity).scope })
        for request in requests {
            let scope = filesKey(request, identity: identity).scope
            guard !warmFiles.contains(scope), !queued.contains(scope) else { continue }
            warmMirrorQueue.append(request)
        }
        guard warmMirrorTask == nil, !warmMirrorQueue.isEmpty else { return }
        warmMirrorTask = Task(priority: .background) { [weak self] in
            await self?.drainMirrorQueue(identity: identity)
            self?.warmMirrorTask = nil
        }
    }

    private func drainMirrorQueue(identity: String) async {
        let host = codeHost
        var done = 0
        while done < WarmSet.mirrorBatch, !warmMirrorQueue.isEmpty, identity == prIndexIdentity, !Task.isCancelled {
            let request = warmMirrorQueue.removeFirst()
            let key = filesKey(request, identity: identity)
            if await QueryRepository.shared.isPersisted(key) {
                warmFiles.insert(key.scope)
                continue
            }
            do {
                let password = try await host.gitPassword(identity: identity)
                let files = try await GitMirror.shared.changeSet(for: request, remote: host.remoteURL(repo: request.ref.repo),
                                                                 password: password)
                QueryRepository.shared.persist(PRDetailResources.files, key: key, value: files)
                warmFiles.insert(key.scope)
            } catch is CancellationError {
                return
            } catch {
                // Not retried this run: an explicit open falls back to the host.
                warmFiles.insert(key.scope)
                NSLog("pultik: mirror diff of %@ failed: %@", request.ref.key, error.localizedDescription)
            }
            done += 1
        }
        await GitMirror.shared.evict()
    }
}
