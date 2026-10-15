import Foundation

extension StatusStore {
    // MARK: - Vitrinka listeners (own host, own breaker)

    /// One host, one credential, one breaker: the listener rail and the todo
    /// engine (`TodoStore`) refresh inside the same `gated(.vitrinka)` pass,
    /// so an off-mesh Mac backs off once and every vitrinka surface folds
    /// together. Hiding the listener section skips its requests, not the
    /// todos'.
    func refreshVitrinka() async {
        let snapshotKey = await vitrinkaSnapshotKey()
        let wantListeners = isSectionVisible("vitrinka")
        if !wantListeners { vitrinkaWorkspaces = [] }
        var todosAnswered = false
        defer { recordTodoNeeds(answered: todosAnswered, account: snapshotKey?.identity) }
        // A half-open trial spends ONE request (`probe`) before the fan-out
        // is allowed back — without it the default probe reports success,
        // clears the strike ladder, and a still-dead host restarts at the
        // gentle 2-minute step every round.
        await gated(.vitrinka, probe: { await VitrinkaClient.shared.probe() }) {
            // Atomic from the rails' point of view: nothing is published until
            // BOTH halves answered, and any failure folds both — one hide,
            // one breaker, never a listener rail showing a stale success
            // beside a hidden todo rail.
            var workspaces: [VitrinkaWorkspaceSnapshot] = []
            if wantListeners {
                switch await VitrinkaClient.shared.dailyWorkspaces(preferring: vitrinkaWorkspace) {
                case let .failed(failure):
                    vitrinkaWorkspaces = []
                    TodoStore.shared.markUnreachable()
                    return failure
                case let .value(value):
                    workspaces = value.snapshots
                    if let rejection = value.rejection {
                        vitrinkaWorkspaces = workspaces
                        TodoStore.shared.markUnreachable()
                        return rejection
                    }
                }
            }
            if let failure = await TodoStore.shared.refresh(using: VitrinkaClient.shared) {
                vitrinkaWorkspaces = []
                return failure
            }
            todosAnswered = true
            vitrinkaWorkspaces = workspaces
            recordVitrinkaSnapshot(key: snapshotKey)
            return nil
        }
    }
}
