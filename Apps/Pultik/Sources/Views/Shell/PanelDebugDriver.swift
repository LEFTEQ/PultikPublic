#if DEBUG
import SwiftUI
import Timeline

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
        case "diff-fixture":
            // AC 4: a big diff in place of the shown PR's ('' clears it).
            let path = info["text"] as? String ?? ""
            DiffFixture.shared.load(path.isEmpty ? nil : path)
        case "pr-verb":
            // AC 15 on a throwaway PR: one verb on the open PR through the same
            // `performPRVerb` the sheets call (the driver cannot type into them).
            guard let path = info["path"] as? String else { return }
            let text = info["text"] as? String ?? ""
            guard let ref = debugSelectedPR, let verb = debugVerb(text, ref: ref) else {
                PanelDriver.write(state: ["error": "no open PR or unknown verb \(text)"], to: path)
                return
            }
            Task { @MainActor in
                do {
                    try await store.performPRVerb(verb, ref: ref)
                    PanelDriver.write(state: ["ok": true, "verb": text, "pr": ref.key], to: path)
                } catch {
                    PanelDriver.write(state: ["ok": false, "verb": text, "error": error.localizedDescription], to: path)
                }
            }
        case "gutter":
            // A gutter click on `<file index>:<line index>` (⇧ with `+`): a review comment starts there.
            let parts = (info["text"] as? String ?? "").split(separator: ":").compactMap { Int($0.replacingOccurrences(of: "+", with: "")) }
            guard parts.count == 2, let canvas = CodeCanvasView.active else { return }
            canvas.callbacks.gutter(parts[0], parts[1], (info["text"] as? String ?? "").hasSuffix("+"))
        case "scroll-bench":
            // AC 4: the shown canvas scrolls top to bottom on the display link.
            guard let path = info["path"] as? String else { return }
            guard let canvas = CodeCanvasView.active else {
                PanelDriver.write(state: ["error": "no code canvas on screen"], to: path)
                return
            }
            let speed = Double(info["text"] as? String ?? "") ?? 5000
            canvas.runScrollBench(speed: CGFloat(speed)) { PanelDriver.write(state: $0, to: path) }
        case "timeline-demo":
            // The CI timeline fed a Debug set that holds it until `clear` (vt-7781 WP5): `small`,
            // `busiest` (synthetic), or a recorded page's path (`Tests/Fixtures/semafor/*-ci-*.json`).
            let stage = TimelineStage.shared
            switch info["text"] as? String ?? "" {
            case "clear": stage.debugFeed(.ciTimeline, nil)
            case "small": stage.debugFeed(.ciTimeline, TimelineDemo.small(now: Date()))
            case "", "busiest": stage.debugFeed(.ciTimeline, TimelineDemo.busiest(now: Date()))
            case let path:
                do {
                    let fixture = try TimelineDemo.fixture(path)
                    stage.debugFeed(.ciTimeline, fixture.feed)
                    stage.debugZoom(.ciTimeline, to: fixture.day)
                } catch {
                    NSLog("pultik: timeline-demo could not read %@: %@", path, error.localizedDescription)
                }
            }
        case "timeline-bench":
            // AC 8: CI's Timeline on the recorded busiest day (`text` = "<s per phase> <fixture path>"),
            // a scripted pan and pinch per display frame; the live feed comes back after it.
            guard let path = info["path"] as? String else { return }
            let parts = (info["text"] as? String ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            let seconds = parts.first.flatMap(Double.init) ?? 2
            let stage = TimelineStage.shared
            var day: ClosedRange<Date>?
            if parts.count == 2 {
                do {
                    let fixture = try TimelineDemo.fixture(parts[1])
                    stage.debugFeed(.ciTimeline, fixture.feed)
                    day = fixture.day
                } catch {
                    return PanelDriver.write(state: ["error": "fixture: \(error.localizedDescription)"], to: path)
                }
            } else {
                stage.debugFeed(.ciTimeline, TimelineDemo.busiest(now: Date()))
            }
            if router.module != .ci || router.view != .timeline { router.enter(.ci, view: .timeline) }
            Task { @MainActor in
                // The body swaps in once the strip's keys settle; the canvas attaches when it shows.
                for _ in 0 ..< 60 {
                    if let canvas = stage.canvas(.ciTimeline), canvas.attached, canvas.active { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let canvas = stage.canvas(.ciTimeline) else {
                    stage.debugFeed(.ciTimeline, nil)
                    return PanelDriver.write(state: ["error": "no CI timeline canvas on screen"], to: path)
                }
                if let day { stage.debugZoom(.ciTimeline, to: day) } else { stage.perform(.now, on: .ciTimeline) }
                // `mods` = "vsync": the surface presents in step with the display for this run, to
                // compare with what ships (Immediate, AC 8's diagnosis).
                let vsync = (info["mods"] as? String) == "vsync"
                stage.debugVSync(.ciTimeline, vsync)
                // Let the framed day build once before the clock starts.
                try? await Task.sleep(for: .milliseconds(300))
                canvas.runBench(seconds: seconds) { report in
                    var report = report
                    report["vsync"] = vsync
                    report["drawablePx"] = stage.debugDrawableSize(.ciTimeline)
                    stage.debugVSync(.ciTimeline, false)
                    stage.debugFeed(.ciTimeline, nil)
                    PanelDriver.write(state: report, to: path)
                }
            }
        case "timeline-scrub":
            // AC 10: the playhead dragged across the shown timeline's axis (CI's, Estate's or
            // Backups') through the mouse's own entry (`scrub(x:release:)`) every 8 ms for
            // `text` seconds, then released.
            guard let path = info["path"] as? String else { return }
            let seconds = Double(info["text"] as? String ?? "") ?? 2
            let slot = shownCanvas ?? .ciTimeline
            guard let lens = slot.lens, let canvas = TimelineStage.shared.canvas(slot), canvas.attached, canvas.active else {
                return PanelDriver.write(state: ["error": "no timeline canvas on screen"], to: path)
            }
            let counter = switch lens {
            case .ci: "ci/at"
            case .estate: "estate/map?at"
            case .backups: "estate/backups?at"
            }
            Task { @MainActor in
                let stage = TimelineStage.shared
                let before = SemaforClient.requests.snapshot[counter] ?? 0
                stage.debugClearReplay(slot)
                let left = Double(TimelineEngine.labelWidth) + 40
                let right = Double(canvas.bounds.width) - 40
                let steps = Int(seconds / 0.008)
                for step in 0 ... steps {
                    canvas.scrub(x: left + (right - left) * Double(step) / Double(max(steps, 1)), release: false)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                canvas.scrub(x: right - 3, release: true)
                try? await Task.sleep(for: .milliseconds(600))
                let log = stage.debugReplayLog(slot)
                let gaps = zip(log.dropFirst(), log).map { $0.at.timeIntervalSince($1.at) * 1000 }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                PanelDriver.write(state: [
                    "seconds": seconds, "moves": steps + 1, "sent": log.count,
                    "minGapMs": gaps.min() ?? 0, "flooredWhileMoving": log.dropLast().allSatisfy {
                        $0.instant == ReplayClock.floored($0.instant)
                    },
                    "settledInstant": log.last.map { iso.string(from: $0.instant) } ?? NSNull(),
                    "playhead": stage.debugState(slot)["playhead"] ?? NSNull(),
                    "slot": slot.rawValue,
                    // The lens's replay reads since the drag began (`ci/at`, `estate/map?at`, `estate/backups?at`).
                    "replayReads": [counter: (SemaforClient.requests.snapshot[counter] ?? 0) - before],
                ], to: path)
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
                "moduleView": router.view?.rawValue ?? NSNull(),
                "moduleViews": router.module?.views.map(\.rawValue) ?? [],
                "selection": selectedID ?? NSNull(),
                "moduleItems": keyItems,
                "detailOpen": detailShown,
                "inspectorOpen": router.inspectorOpen,
                // D20: the open detail's verbs, and what ⌘R would route to — read, never pressed.
                "detailVerbs": detailShown ? moduleObjects.first { $0.id == router.selection }?.verbs
                    .map { "\($0.title) \($0.kbd ?? "")" } ?? [] : [],
                "commandR": KeyboardCoordinator.intent(for: KeyStroke(key: .character("r"), command: true), in: keyContext())
                    .map { String(describing: $0) } ?? NSNull(),
                "markable": moduleObjects.filter(\.markable).count,
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
                "prSections": router.module == .prs && detailShown ? PRWorkbench.drawnSections : [],
                // PR workbench (D5, AC 2): entered, its tabs and the one shown.
                "entered": detailShown && router.entered,
                "prTabs": router.module == .prs && detailShown ? router.tabs : [],
                "prTab": router.module == .prs && detailShown ? router.shownTab ?? NSNull() : NSNull(),
                "verbKeys": router.verbKeys.sorted(),
                // vt-7727 D5: the shown canvas view, entered or not, and its engine.
                "canvasEntered": shownCanvas != nil && router.canvasEntered,
                "canvas": shownCanvas.map { TimelineStage.shared.debugState($0) } ?? NSNull(),
                // vt-7781 AC 10: what the data layer is asked to keep loaded, and the replay shown.
                "timelineVisibility": store.timelineVisibility.map { visibility -> [String: Any] in
                    ["lens": visibility.lens.rawValue, "from": PultikFormat.clock(visibility.range.lowerBound),
                     "to": PultikFormat.clock(visibility.range.upperBound),
                     "bucketS": visibility.density?.bucketS ?? NSNull()]
                } ?? NSNull(),
                "timelineReplay": store.timelineReplay.map { PultikFormat.clock($0.at) } ?? NSNull(),
                "ciHost": store.ciSemaforHost ?? NSNull(),
                "code": CodeCanvasView.active.map { canvas -> [String: Any] in
                    ["files": canvas.document.files.count, "lines": canvas.lineCount, "wraps": canvas.wraps,
                     "highlighted": canvas.highlightedFiles, "selection": canvas.hasSelection,
                     "language": canvas.document.files.first?.language?.rawValue ?? NSNull()]
                } ?? NSNull(),
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
                // Home (copilot shell D6, vt-7727 D8): which region shows, the
                // widgets beside Now, the Now queue's incidents and the rows
                // the keyboard walks, the prod rail beside results, the frame.
                "home": showsHome,
                "homeWidgets": showsHome ? homeWidgets.map(\.rawValue) : [],
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
                // vt-7727 AC 12: Semafor requests by path, zero while hidden.
                state["semaforRequests"] = SemaforClient.requests.snapshot
                // vt-7727 AC 6: a machine's history is read on selection only.
                state["prometheusRangeQueries"] = await MetricsClient.shared.rangeQueries
                state["semaforHosts"] = store.semaforHosts.mapValues { host in
                    host.fetchedAt.mapValues { PultikFormat.clock($0) }
                }
                PanelDriver.write(state: state, to: path)
            }
        default:
            break
        }
    }

    /// The PR whose detail is open in PRs.
    private var debugSelectedPR: ChangeRequestRef? {
        guard router.module == .prs, let id = selectedID else { return nil }
        if id.hasPrefix("pr:"), let number = Int(id.dropFirst(3)), let entry = store.inbox.first(where: { $0.id == number }) {
            return ChangeRequestRef(repo: entry.repoSlug, number: entry.info.pr.number)
        }
        return PRListPage.archiveRef(id)
    }

    /// `comment:<text>`, `inline:<path>:<line>:<text>`, `review:<comment|approve|requestChanges>:<text>`,
    /// `resolve`, `merge:<merge|squash|rebase>`, `close`, `reopen`.
    private func debugVerb(_ text: String, ref: ChangeRequestRef) -> ChangeRequestVerb? {
        let parts = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let held = store.cachedPRDetail(ref).conversation
        switch parts.first {
        case "comment": return parts.count > 1 ? .comment(parts.dropFirst().joined(separator: ":")) : nil
        case "inline":
            guard parts.count == 4, let line = Int(parts[2]) else { return nil }
            return .addReviewComment(DraftReviewComment(path: parts[1], line: line, side: .right, body: parts[3]))
        case "review":
            guard parts.count >= 2, let event = ReviewEvent(rawValue: parts[1]) else { return nil }
            return .submitReview(event, body: parts.dropFirst(2).joined(separator: ":"))
        case "resolve": return held?.openThreads.first.map { .resolve(thread: $0.id) }
        case "merge":
            guard let held, let method = MergeMethod(rawValue: parts.count > 1 ? parts[1] : "merge") else { return nil }
            return .merge(method, expectedHead: held.headSHA, deleteBranch: true)
        case "close": return .close
        case "reopen": return .reopen
        default: return nil
        }
    }

    static func describe(_ place: ModuleRouter.Place) -> [String: Any] {
        ["module": place.module?.rawValue ?? "home", "filter": place.filter, "selection": place.selection ?? NSNull(),
         "detailOpen": place.detailOpen, "stack": place.stack.map(\.id), "entered": place.entered,
         "tab": place.tab ?? NSNull(), "view": place.view?.rawValue ?? NSNull(), "canvasEntered": place.canvasEntered]
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
