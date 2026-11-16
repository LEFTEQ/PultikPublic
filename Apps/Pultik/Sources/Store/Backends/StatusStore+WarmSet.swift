import Foundation

/// The warm set (stay in Pultík D9): every change request the index saw
/// updated in the last 48 hours — open, merged or closed — kept on disk, so
/// a PR opens instantly from search, Home or the list, also right after a
/// launch. It rides the GitHub lane (no second poller): after each estate
/// read the conversations whose `updatedAt` moved are re-read in batches of
/// ten, in the background budget, and new heads get their diff from the git
/// mirror (D10) in one background pass at a time.
extension StatusStore {
    /// The operator's own open rows first, whatever their age (instant PR
    /// open: the inbox is what ↵ lands on), then every change request in
    /// the window, newest first (`WarmSet`).
    func warmCandidates(now: Date = Date()) -> [(ref: ChangeRequestRef, updatedAt: Date)] {
        let own = inbox.map { entry in
            (ref: ChangeRequestRef(repo: entry.repoSlug, number: entry.info.pr.number),
             updatedAt: entry.info.pr.updatedAt ?? .distantPast)
        }
        let window = WarmSet.candidates(prIndex.records.values.map(\.pr),
                                        scope: Set(searchableRepos.map { $0.lowercased() }), now: now)
        var seen: Set<String> = []
        return (own + window).filter { seen.insert($0.ref.key.lowercased()).inserted }
    }

    /// The open inbox's change requests: the warm passes hold and lay out
    /// diffs only for these (↵ lands on them); any other PR's diff loads
    /// when it is opened. Every diff of the 48 h window kept the app near
    /// a gigabyte.
    var openRefs: Set<ChangeRequestRef> {
        Set(inbox.map { ChangeRequestRef(repo: $0.repoSlug, number: $0.info.pr.number) })
    }

    /// Pulls the warm set's snapshots — conversation, activity and the
    /// conversation's own diff — from disk into memory, one request after
    /// another in `warmCandidates`' order, and has each prepared for
    /// drawing (instant PR open). The disk read and its decode run on the
    /// snapshot store's actor; the main actor only files the value. No
    /// request leaves the Mac. Called again it restarts: what memory
    /// already holds costs a lookup.
    func warmPRMemory() {
        guard let identity = prIndexIdentity else { return }
        warmMemoryTask?.cancel()
        let refs = warmCandidates().map(\.ref)
        let open = openRefs
        let resolver = autolinksSnapshot
        warmMemoryTask = Task(priority: .utility) { [weak self] in
            for ref in refs {
                guard let self, !Task.isCancelled, identity == self.prIndexIdentity else { return }
                let repository = QueryRepository.shared
                _ = await repository.held(PRDetailResources.activity, key: self.activityKey(ref, identity: identity))
                if let conversation = await repository.held(PRDetailResources.conversation,
                                                            key: self.conversationKey(ref, identity: identity))?.value, open.contains(ref) {
                    _ = await repository.held(PRDetailResources.files, key: self.filesKey(conversation, identity: identity))
                }
                guard !Task.isCancelled, identity == self.prIndexIdentity else { return }
                self.prepareRender([ref], resolver: resolver, diffsFor: open)
            }
        }
    }

    /// The identity behind the index changed: its ledgers, its queue and
    /// everything memory holds of the old one's PRs go with it. The mirror
    /// pass in flight stops itself on the identity.
    func forgetWarmSet() {
        warmMemoryTask?.cancel()
        warmMemoryTask = nil
        warmMirrorQueue = []
        warmUpdatedAt = [:]
        warmActivityAt = [:]
        warmFiles = []
        for resource in [PRDetailResources.conversation.name, PRDetailResources.files.name, PRDetailResources.activity.name] {
            QueryRepository.shared.invalidate(resource: resource)
        }
        PRRenderCache.shared.removeAll()
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
            prepareRender(settled.map(\.ref), diffsFor: openRefs)
        } catch is CancellationError {
            return
        } catch {
            warmUpdatedAt.merge(ledger) { max($0, $1) }
            NSLog("pultik: warm set sync failed: %@", error.localizedDescription)
        }
        await syncWarmActivity(identity: identity, now: now)
        // A PR the inbox or the index learnt since the launch's pass, and
        // any diff the mirror has written: into memory, from disk.
        if identity == prIndexIdentity { warmPRMemory() }
    }

    /// The activity beside each warm conversation (instant PR open): the
    /// same sync on its own ledger, so a warm PR opens with its timeline,
    /// merge box and verbs. Batched like the conversation and read only when
    /// `updatedAt` moved — never one request per PR, never a poll.
    private func syncWarmActivity(identity: String, now: Date) async {
        guard identity == prIndexIdentity else { return }
        let host = codeHost
        var ledger = warmActivityAt
        var settled: [ChangeRequestRef] = []
        do {
            _ = try await WarmSet.sync(warmCandidates(now: now), ledger: &ledger, repository: .shared,
                                       resource: PRDetailResources.activity, key: { [self] in activityKey($0, identity: identity) },
                                       updatedAt: \.updatedAt, limit: WarmSet.activitiesPerSync) { refs in
                let answer = try await host.activities(refs, identity: identity)
                settled = Array(answer.keys)
                return answer
            }
        } catch is CancellationError {
            return
        } catch {
            NSLog("pultik: warm activity sync failed: %@", error.localizedDescription)
        }
        guard identity == prIndexIdentity else { return }
        warmActivityAt.merge(ledger) { max($0, $1) }
        prepareRender(settled, diffsFor: openRefs)
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
                prepareRender([request.ref])
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
