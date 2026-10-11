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
            // What the coordinator leaves alone would reach the field editor:
            // ↵ submits. The rest are caret moves (Esc is always a layer).
            guard driveKey(event) != nil else { return }
            if name == "enter" { submitPalette() }
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
