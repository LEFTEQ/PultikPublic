import Foundation

/// The Toolkit module's backend (docs/specs/2026-10-20-toolkit-module-brief.md):
/// one `toolkit` lane that reads `toolkit catalog dashboard --json` only while
/// the module is on screen, and records each answer through
/// `QueryRepository` so a cold start draws the last one — labelled cached,
/// never current, until a live read answers. Read-only (vitr:dec/bctezf0).
extension StatusStore {
    /// The visible module's lane never reads faster than this, whatever
    /// Settings ▸ Modules asks: each read runs a local process.
    static let toolkitFloor: TimeInterval = 30
    static let toolkitDefaultInterval: TimeInterval = 120

    /// Hidden, the lane idles (its work returns at once anyway); on screen,
    /// the module's refresh speed, floored.
    func toolkitInterval() -> TimeInterval {
        guard visibleModule == .toolkit else { return 3600 }
        return max(Self.toolkitFloor, visibleCadence("toolkit") ?? Self.toolkitDefaultInterval)
    }

    /// Entering the module reads now unless a read was just made — the
    /// module's own, not the lane's: a hidden lane's run reads nothing.
    func kickToolkit() {
        guard pollingStarted else { return }
        let last = toolkit.attemptedAt ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.toolkitFloor else { return }
        Task { await schedule.run("toolkit") }
    }

    func refreshToolkit() async {
        guard visibleModule == .toolkit else { return }
        guard let executable = ToolkitClient.executable() else {
            // A configured path is the only candidate: say it is unusable
            // rather than "not installed".
            if let configured = RuntimeConfig.current.toolkitPath {
                toolkit.failed(.failed("settings.json toolkitPath \(configured) is not an executable absolute path"))
            } else {
                toolkit.failed(.missing)
            }
            return
        }
        let key = toolkitSnapshotKey(executable)
        switch await ToolkitClient.dashboard(executable: executable) {
        case let .success(dashboard):
            let now = Date()
            toolkit.answered(dashboard, at: now)
            QueryRepository.shared.record(Snapshots.toolkit, key: key, value: dashboard, at: now)
        case let .failure(failure):
            NSLog("pultik: toolkit catalog dashboard — %@", failure.message)
            toolkit.failed(failure)
        }
    }

    /// The binary that answered is the identity: a Debug build pointed at a
    /// worktree's provider never restores the installed one's answer.
    func toolkitSnapshotKey(_ executable: URL) -> QueryKey {
        QueryKey(resource: Snapshots.toolkit.name, identity: executable.path)
    }

    func restoreToolkit() async {
        guard let executable = ToolkitClient.executable(),
              let snapshot = await QueryRepository.shared.restore(Snapshots.toolkit, key: toolkitSnapshotKey(executable))
        else { return }
        toolkit.restore(snapshot.value, fetchedAt: snapshot.fetchedAt)
    }
}
