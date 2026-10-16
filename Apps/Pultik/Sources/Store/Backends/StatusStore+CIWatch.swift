import Foundation

/// The CI watch (stay in Pultík D7, AC 6): a 5 s lane that exists only while
/// a change request's detail with running checks is on screen. It reads our
/// own CI (`CIStatusSource`: Prometheus + Semafor, free mesh reads) and asks
/// the host to confirm only when a run's jobs change — or every 30 s while a
/// running check is one our CI cannot see (GitHub-hosted runners). This
/// replaces the detail's old "never poll" for its checks alone; the
/// conversation still reads on open, on `updatedAt` moving and through the
/// warm set.
extension StatusStore {
    struct CIWatchTarget: Equatable {
        let request: ChangeRequestRef
        /// The runs with a running check, on the request's host.
        let runs: Set<CIRunRef>
    }

    var ciStatusSource: any CIStatusSource {
        MeshCIStatus(metrics: .shared) { [weak self] in
            await self?.semaforHeads() ?? []
        }
    }

    /// The open detail says what it shows: running runs start the watch,
    /// none (or nil — the detail left, the panel hid) retires it.
    func watchCI(_ target: CIWatchTarget?) {
        let target = target.flatMap { $0.runs.isEmpty ? nil : $0 }
        guard target != ciWatchTarget else { return }
        if target?.request != ciWatchTarget?.request {
            ciLive = nil
            ciConfirmedAt = nil
        }
        ciWatchTarget = target
        if target == nil {
            schedule.remove(CIWatch.lane)
        } else if !schedule.contains(CIWatch.lane) {
            schedule.add(CIWatch.lane, every: { CIWatch.interval }) { [weak self] in await self?.ciWatchTick() }
        }
    }

    func ciWatchTick(now: Date = Date()) async {
        guard let target = ciWatchTarget else { return }
        let source = ciStatusSource
        await gated(.prometheus) {
            do {
                let snapshot = try await source.snapshot(for: target.runs)
                guard target == ciWatchTarget else { return nil }
                let ids = Set(target.runs.map(\.runID))
                let changed = CIWatch.transitions(from: ciLive, to: snapshot, runs: ids)
                ciLive = snapshot
                if CIWatch.needsConfirm(transitions: changed, running: ids, seen: snapshot,
                                        confirmedAt: ciConfirmedAt, now: now) {
                    await confirmCI(target, changed: changed, now: now)
                }
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                NSLog("pultik: CI watch read failed: %@", error.localizedDescription)
                return .classify(error)
            }
        }
    }

    /// One host read of the request's conversation — its checks — and the
    /// changed runs' cards read again.
    private func confirmCI(_ target: CIWatchTarget, changed: Set<Int>, now: Date) async {
        ciConfirmedAt = now
        ciConfirmReads += 1
        do {
            let fresh = try await prConversation(target.request, force: true)
            guard target == ciWatchTarget else { return }
            if !changed.isEmpty { QueryRepository.shared.invalidate(resource: CIDetailResources.run.name) }
            ciConfirmed[target.request, default: 0] += 1
            let running = Set(fresh.checks.filter { $0.outcome == .running }.compactMap(\.runID))
            watchCI(CIWatchTarget(request: target.request,
                                  runs: Set(target.runs.filter { running.contains($0.runID) })))
        } catch {
            NSLog("pultik: CI confirm of %@ failed: %@", target.request.key, error.localizedDescription)
        }
    }

    /// Each host's placing lane, every Semafor behind its own breaker.
    private func semaforHeads() async -> Set<String> {
        var heads: Set<String> = []
        for base in preferences.servers.compactMap(\.semaforURL) {
            await gated(.semafor(host: base.host() ?? base.absoluteString)) {
                let answer = await SemaforClient.shared.pool(at: base, lanes: [])
                if let lane = answer.pool?.head?.lane { heads.insert(lane) }
                return answer.failure
            }
        }
        return heads
    }
}
