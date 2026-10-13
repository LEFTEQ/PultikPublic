#if DEBUG
import SwiftUI

extension StatusPanelView {
    /// PanelDriver relay: the same state changes and key routing a typed
    /// query or keystroke would produce, minus the field editor.
    func driveFromDebugger(_ info: [AnyHashable: Any]) {
        let cmd = info["cmd"] as? String
        switch cmd {
        case "query":
            // Typed text: the dot grammar applies (`.c failed` enters CI).
            query = info["text"] as? String ?? ""
        case "key":
            guard let name = info["key"] as? String,
                  let event = PanelDriver.keyEvent(named: name, mods: info["mods"] as? String) else { return }
            // `text` repeats the key at key-repeat speed (AC 12's fast walk):
            // one shell call per key is slower than any keyboard.
            let repeats = max(1, Int(info["text"] as? String ?? "") ?? 1)
            Task { @MainActor in
                for index in 0 ..< repeats {
                    if index > 0 { try? await Task.sleep(for: .milliseconds(50)) }
                    // What the coordinator leaves alone would reach the field editor:
                    // ↵ submits. The rest are caret moves (Esc is always a layer).
                    guard driveKey(event) != nil else { continue }
                    if name == "enter" { submitPalette() }
                }
            }
        case "mark":
            // A ⌘-click on the row (bulk D1); `all` is ⌘A, `none` is Esc's unmark.
            switch info["text"] as? String ?? "" {
            case "all": router.markAll(markableIDs)
            case "none": router.clearMarks()
            case let id where markableIDs.contains(id): router.toggleMark(id)
            default: break
            }
        case "home-toggle":
            let text = info["text"] as? String ?? ""
            let key = text == "fold" ? PRDigest<StatusStore.InboxPR>.foldKey : text
            if homeExpanded.contains(key) { homeExpanded.remove(key) } else { homeExpanded.insert(key) }
        case "paste":
            // ⌘V's real route: the monitor first, then the field editor —
            // the one driver verb that takes the keyboard (`open` never does).
            guard let event = PanelDriver.keyEvent(named: "v", mods: "cmd"),
                  driveKey(event) != nil else { return }
            let panel = NSApp.windows.first { $0 is StatusPanel }
            panel?.makeKey()
            (panel?.fieldEditor(false, for: nil) as? NSTextView)?.paste(nil)
        case "state":
            guard let path = info["path"] as? String else { return }
            var state: [String: Any] = [
                "query": query,
                "selectedID": selectedID ?? NSNull(),
                "pathVerbIndex": pathVerbIndex,
                "commandNotice": commandNotice?.text ?? NSNull(),
                // A module reports the `.x` mode it aliases (CI → "ci", Prod → "health").
                "activeMode": activeMode?.mode.rawValue
                    ?? router.module.flatMap { PaletteMode.alias(of: $0)?.rawValue } ?? NSNull(),
                // The shell (WP3): where the panel is, what ↑/↓ walk and what is open.
                "module": stripModule?.rawValue ?? NSNull(),
                "moduleFilter": router.module == nil ? NSNull() : query,
                "selection": selectedID ?? NSNull(),
                "moduleItems": keyItems,
                "detailOpen": detailShown,
                "inspectorOpen": router.inspectorOpen,
                // Stay in Pultík (WP8): the dwelled place a summon returns to, the card
                // stack and the ⇥ focus, the warm bodies and their builds.
                "place": Self.describe(place.dwelled),
                "stack": router.stack.map { card -> [String: Any] in
                    ["kind": card.kind.rawValue, "id": card.id, "column": card.column,
                     "picks": Dictionary(uniqueKeysWithValues: card.picks.map { (String($0.key), $0.value) })]
                },
                "focus": router.focus ?? NSNull(),
                "focusTargets": router.focusTargets,
                // Bulk actions: the marked rows as drawn, the pane, and the module's batch.
                "marks": markableIDs.filter(router.marks.contains),
                "bulkShown": bulkShown,
                "bulk": router.module.flatMap { BulkRuns.shared.batch($0) }.map { batch -> [String: Any] in
                    ["verb": batch.verb, "shown": batch.shown, "running": batch.running, "summary": batch.summary,
                     "rows": batch.rows.map { ["id": $0.id, "state": "\($0.state)"] }]
                } ?? NSNull(),
                "displayedModule": warmth.displayed.rawValue,
                "mountedModules": warmth.mounted.map(\.rawValue),
                "moduleBuilds": warmth.totalBuilds,
                "moduleBuildsBy": Dictionary(uniqueKeysWithValues: warmth.builds.map { ($0.key.rawValue, $0.value) }),
                "prSections": router.module == .prs && detailShown ? PRDetailContent.drawnSections : [],
                "ciWatch": store.ciWatchTarget.map { target -> [String: Any] in
                    ["request": target.request.key, "runs": target.runs.map(\.key).sorted(),
                     "live": store.ciLive.map { $0.jobs.mapValues { $0.map(\.name) }.reduce(into: [String: [String]]()) {
                         $0[String($1.key)] = $1.value } } ?? [:],
                     "confirms": store.ciConfirmReads]
                } ?? NSNull(),
                "warmSet": ["synced": store.warmUpdatedAt.count, "files": store.warmFiles.count,
                            "candidates": store.warmCandidates().count,
                            "at": store.warmSyncedAt.map { PultikFormat.clock($0) } ?? NSNull()] as [String: Any],
                "strip": stripSignals,
                "prodExpanded": prodExpandedKey ?? NSNull(),
                "eveAskedPrompt": eveAskedPrompt ?? NSNull(),
                // Home (copilot shell D6): which region shows, its style, the
                // Now queue's incidents and the rows the keyboard walks, the
                // prod rail beside results, the frame.
                "home": showsHome,
                "homeStyle": store.homeStyle.rawValue,
                "homeExpanded": homeExpanded.sorted(),
                "nowExpanded": nowExpanded.sorted(),
                "homeRows": showsHome ? homeNowRows.map(\.id) : [],
                "nowIncidents": NowStore.shared.queue.incidents.map(\.key),
                "nowLanes": NowStore.shared.queue.lanes.map { [$0.lane.rawValue, $0.incidents, $0.needs, $0.folded] },
                "nowHandled": NowStore.shared.handled.map(\.episodeID),
                "nowTombstone": nowTombstone.map { NowHomeRow.id($0.row.key) } ?? NSNull(),
                "nowAsOf": NowStore.shared.restoredAsOf.map { PultikFormat.clock($0) } ?? NSNull(),
                // Drawn only beside global results: a module takes the body.
                "prodRail": router.module == nil && showServiceRail && !showsHome,
                "panelSize": [PanelMetrics.shared.panelSize.width, PanelMetrics.shared.panelSize.height],
                "prSearchIDs": store.searchMatches.map(\.id),
                "prSearchError": store.searchError ?? NSNull(),
                "prSearchPartial": store.searchIsPartial,
                "prSearchMilliseconds": store.localSearchMilliseconds,
                "prIsSearching": store.isSearching,
            ]
            if let target = pathTarget {
                state["pathTarget"] = [
                    "path": target.url.path,
                    "isDirectory": target.isDirectory,
                    "missing": target.missing ?? NSNull(),
                    "line": target.line ?? NSNull(),
                    "column": target.column ?? NSNull(),
                    "verbs": target.verbs.map(\.rawValue),
                ] as [String: Any]
            } else {
                state["pathTarget"] = NSNull()
            }
            Task { @MainActor in
                let counts = await store.githubRequestCounts()
                state["githubNetworkRequests"] = counts.network
                state["githubSharedRequests"] = counts.shared
                state["githubPRLookups"] = counts.lookups
                state["githubPRSearches"] = counts.searches
                // WP5 AC 9: a same-head reopen adds no files request.
                state["githubPRDetails"] = counts.details
                state["githubPRFiles"] = counts.files
                // Stay in Pultík AC 10: the warm set's batched reads, apart from the detail's.
                state["githubPRBatches"] = counts.batches
                // WP6 AC 10: a failed run's detail reads its run + jobs and one log.
                state["githubCIRuns"] = counts.ciRuns
                state["githubCILogs"] = counts.ciLogs
                // WP7 AC 12: a deployment's release line, two reads per source.
                state["githubReleases"] = counts.releases
                state["ciRerun"] = CIRerunCenter.shared.outcomes.mapValues { "\($0)" }
                    .reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
                state["prAllSearchIDs"] = store.searchResults.map(\.id)
                PanelDriver.write(state: state, to: path)
            }
        default:
            break
        }
    }

    static func describe(_ place: ModuleRouter.Place) -> [String: Any] {
        ["module": place.module?.rawValue ?? "home", "filter": place.filter, "selection": place.selection ?? NSNull(),
         "detailOpen": place.detailOpen, "stack": place.stack.map(\.id)]
    }

    /// A driver key through the same coordinator a real keystroke takes,
    /// addressed to the field. nil = consumed.
    private func driveKey(_ event: NSEvent) -> NSEvent? {
        KeyboardCoordinator.handle(event, synthetic: true, context: keyContext(synthetic: true),
                                   perform: { perform($0, $1) })
    }

    /// Each module chip's live signal as drawn (`ModuleSignal.drawnText`),
    /// null while it is quiet.
    private var stripSignals: [String: Any] {
        let signals = ModuleSignals.make(store: store, fanStore: FanStore.shared, macHealth: MacHealthStore.shared)
        return Dictionary(uniqueKeysWithValues: PanelModule.allCases.map { module -> (String, Any) in
            (module.rawValue, signals[module]?.drawnText.map { $0 as Any } ?? NSNull())
        })
    }
}
#endif
