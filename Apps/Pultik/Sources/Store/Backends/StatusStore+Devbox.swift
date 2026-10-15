import Foundation

extension StatusStore {
    // MARK: - Devbox (one ws-v2 snapshot over ssh)

    /// Workspace identity, units, fleet cpu/mem and public hosts all arrive in
    /// one ssh process. A repo-local `ws ls --json` pass adds Mac-only app
    /// ports and sync paths without touching sshd.
    ///
    /// Deliberately independent of the other sections: the box being asleep or
    /// this Mac being off-network empties devbox and leaves GitHub/Sentry alone.
    ///
    /// This is the only poll that talks to sshd, so it is the one that got
    /// this Mac banned: a failing poll is an authentication attempt repeated
    /// every 90 seconds, forever. Its breaker matters more than the rest —
    /// and its one-request way back in stays `DevboxClient.status()`, the
    /// cheap probe, never this heavier call.
    ///
    /// Every discovered box is polled concurrently behind ITS OWN breaker
    /// (spec 2026-09-25): a silent box drops out of the merge and is marked
    /// silent, and never blanks the rail or delays the other box.
    func refreshDevbox() async {
        guard isSectionVisible("devbox") else {
            devboxWorkspaces = []
            devboxSummary = nil
            devboxFetchedAt = nil
            devboxSnapshots = [:]
            NowStore.shared.forget(.devboxStale)
            return
        }
        await discoverDevboxBoxesIfDue()
        let boxes = devboxBoxes
        let answered = await withTaskGroup(of: Bool.self) { group in
            for box in boxes {
                group.addTask { await self.refreshDevbox(box) }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        // Keyed by name, so a box whose host, port or alias changed would
        // otherwise keep a held snapshot stamped with its OLD endpoint —
        // and its rows would act there. Only an exact endpoint match stays.
        devboxSnapshots = devboxSnapshots.filter { _, snapshot in boxes.contains(snapshot.endpoint) }
        publishDevboxEstate()
        recordDevboxSnapshot()
        recordDevboxNeeds(answered: answered, of: boxes.count)
        for box in boxes {
            guard let snapshot = devboxSnapshots[box.name] else { continue }
            notifyDevboxPressure(snapshot.summary, box: box.name, named: boxes.count > 1)
        }
    }

    /// One box's overview behind that box's breaker; true when the box
    /// answered this call (a held breaker or a failure is no answer).
    @discardableResult
    func refreshDevbox(_ box: DevboxEndpoint) async -> Bool {
        var answered = false
        await gated(.devbox(box: box.name), probe: {
            // The cheap one-request way back in for a half-open breaker —
            // `status()`, never the docker-stats-heavy hub call. A successful
            // trial then proceeds to `work` like every other gated target.
            if case let .failed(failure) = await DevboxClient.shared.status(box) {
                return failure
            }
            return nil
        }) {
            switch await DevboxClient.shared.hub(box) {
            case let .failed(failure):
                devboxSnapshots[box.name] = nil
                return failure
            case let .value(snapshot):
                devboxSnapshots[box.name] = snapshot
                answered = true
                return nil
            }
        }
        return answered
    }

    /// `devbox boxes --json` at launch and every `DevboxDiscovery.interval`.
    /// A failed discovery (older CLI, no answer) keeps the last good list;
    /// with none, today's single endpoint stays. The stamp is taken before
    /// the await so an overlapping refresh does not discover twice.
    func discoverDevboxBoxesIfDue() async {
        if let last = devboxDiscoveredAt, Date().timeIntervalSince(last) < DevboxDiscovery.interval { return }
        devboxDiscoveredAt = Date()
        let discovered = await DevboxClient.shared.discoverBoxes()
        let boxes = DevboxDiscovery.resolve(discovered: discovered, previous: devboxBoxes)
        if boxes != devboxBoxes {
            NSLog("pultik: devbox boxes → %@",
                  boxes.map { "\($0.name)=\($0.host):\($0.port)" }.joined(separator: ", "))
            devboxBoxes = boxes
        }
    }

    /// The sweep parked something because the box was short, not because a
    /// workspace went quiet: parked rose while memory PSI was non-zero. A
    /// stale park at PSI 0 is routine housekeeping and stays silent. Only a
    /// rise counts — a revive that lowers the count is the user's own doing.
    func notifyDevboxPressure(_ summary: DevboxOverviewSummary, box: String, named: Bool) {
        defer { previousDevboxParked[box] = summary.parked }
        guard let previous = previousDevboxParked[box],
              summary.parked > previous,
              summary.pressureSome > 0
        else { return }
        let parked = summary.parked - previous
        let psi = String(format: "%.1f", summary.pressureSome)
        let free = String(format: "%.0fG", summary.availableGB)
        Notifier.send(
            title: "\(named ? "devbox \(box)" : "devbox") — parked \(parked) under memory pressure",
            body: "\(summary.running) hot of \(summary.hotCeiling) · PSI some \(psi) · \(free) free / \(summary.floorGB)G floor",
            url: nil
        )
    }

    /// A card action (park / hold / up) just changed the box; the next
    /// scheduled poll is up to 90 s away. Same gated path, so a box that has
    /// gone away is still never hammered.
    /// After a devbox action: through the lane, so it never overlaps the
    /// scheduled fan-out (before `startPolling`, directly).
    func refreshDevboxNow() async {
        if pollingStarted { await schedule.rerun("devbox") } else { await refreshDevbox() }
    }

    #if DEBUG
        /// Targeted native-UI verification hook. It deliberately calls the same
        /// gated production path; only the scheduling shortcut is Debug-only.
        func debugRefreshDevbox() async {
            await refreshDevbox()
        }
    #endif
}

extension StatusStore {
    /// Every box's last snapshot merged into the rail — after a poll, or from
    /// disk at launch.
    func publishDevboxEstate() {
        let estate = DevboxEstate(boxes: devboxBoxes, snapshots: Array(devboxSnapshots.values))
        // The overview lists hot AND parked identities (parking contract,
        // 2026-09-02): a parked workspace still holds its slot and ports and
        // is one `up` from hot, so it stays on the rail as a parked card —
        // vanishing is what a reaped workspace does. Anything the box calls
        // neither is not a slot and is not shown.
        devboxWorkspaces = estate.workspaces.filter { $0.isHot || $0.isParked }
        devboxSummary = estate.summary
        // A hidden rail must not keep a stale "as of" for its return.
        devboxFetchedAt = estate.generated
    }
}
