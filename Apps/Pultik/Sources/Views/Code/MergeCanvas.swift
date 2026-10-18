import AppKit
import Canvas
import CodeCore
import CodeThemes
import SwiftUI

/// The merge canvas (vt-7968, `docs/specs/2026-10-18-merge-view-decisions.md`): one file's
/// three-way merge on the shared Rust renderer, a `CanvasView` drawing a `MergeEngine`. Rust
/// merges the file, lays out ours · result · theirs (the base on demand), scrolls them in step,
/// draws the ribbons and walks ⇥; Swift feeds the texts, the panes' titles and their
/// highlights, and turns a click into the region under it.
///
/// Never first responder: `KeyboardCoordinator` routes ↑/↓, ⇥ and ⌥B here, as it routes the
/// diff's keys to `CodeCanvasView`.
final class MergeCanvasView: NSView {
    /// The canvas the shown Merge tab draws, for the panel driver.
    static weak var active: MergeCanvasView?

    let surface: CanvasView
    let engine: MergeEngine?
    /// The region ⇥ or a click put the merge on (nil: none), and why it reads as it does.
    var onRegion: (Int?, String?) -> Void = { _, _ in }
    /// ⇥ ran past the file's last stop (forward) or its first.
    var onWrap: (Bool) -> Void = { _ in }
    private var theme: CodeTheme
    private var tasks: [Task<Void, Never>] = []
    /// What the canvas shows, so a highlight landing late for another file is dropped.
    private(set) var fileID = ""

    override convenience init(frame: NSRect) {
        self.init(frame: frame, themes: CodePreferences.shared.themes)
    }

    init(frame: NSRect, themes: CodeThemeStore) {
        theme = themes.theme
        surface = CanvasView(id: "merge", background: themes.theme[.background].nsColor)
        do {
            engine = try MergeEngine(theme: themes.theme.id, accent: .theme(Theme.accent))
        } catch {
            NSLog("pultik: merge canvas refused theme %@: %@", themes.theme.id, error.localizedDescription)
            engine = nil
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = theme[.background].nsColor.cgColor
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        engine?.onMouse = { [weak self] event in self?.mouse(event) ?? false }
        surface.use(engine)
        themes.observe(self) { [weak self] theme in self?.apply(theme) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MergeCanvasView is built in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func apply(_ theme: CodeTheme) {
        self.theme = theme
        let background = theme[.background].nsColor
        layer?.backgroundColor = background.cgColor
        surface.background = background
        do {
            try engine?.setTheme(id: theme.id, accent: .theme(Theme.accent))
        } catch {
            NSLog("pultik: merge canvas refused theme %@: %@", theme.id, error.localizedDescription)
        }
        surface.wake()
    }

    func setDrawing(_ drawing: Bool) {
        surface.setActive(drawing)
    }

    func teardown() {
        tasks.forEach { $0.cancel() }
        tasks = []
        surface.teardown()
    }

    // MARK: - Content

    /// `file`'s merge, its panes titled `labels`; every pane highlights as `HighlightCache`
    /// answers and draws plain until then.
    func show(_ file: MergeFile, id: String, labels: [MergeEngine.Pane: String]) {
        guard let engine else { return }
        tasks.forEach { $0.cancel() }
        tasks = []
        fileID = id
        do {
            try engine.setFile(path: file.path, base: file.base, ours: file.ours, theirs: file.theirs,
                               committed: file.committed)
            try engine.setLabels(labels)
        } catch {
            NSLog("pultik: merge canvas refused %@: %@", file.path, error.localizedDescription)
        }
        report(nil)
        surface.wake()
        guard let language = SyntaxLanguage(path: file.path) else { return }
        let panes: [(MergeEngine.Pane, String)] = [(.base, file.base), (.ours, file.ours), (.result, engine.result),
                                                   (.theirs, file.theirs)]
        for (pane, text) in panes {
            let key = "merge:\(language.rawValue):\(text.utf16.count):\(text.hashValue)"
            tasks.append(Task { [weak self] in
                guard let runs = await HighlightCache.shared.tokens(key: key, language: language, text: { text }),
                      let self, self.fileID == id else { return }
                self.setTokens(runs, pane: pane)
            })
        }
    }

    private func setTokens(_ runs: LineTokens, pane: MergeEngine.Pane) {
        guard let engine else { return }
        var flat: [DiffEngine.Run] = []
        var starts: [UInt32] = [0]
        for line in 0 ..< runs.lineCount {
            for run in runs.runs(line: line) {
                flat.append(DiffEngine.Run(start: UInt32(clamping: run.start), length: UInt32(clamping: run.length),
                                           kind: run.kind.rawValue))
            }
            starts.append(UInt32(flat.count))
        }
        do {
            try engine.setTokens(pane: pane, runs: flat, lineStarts: starts)
        } catch {
            NSLog("pultik: merge canvas refused a pane's runs: %@", error.localizedDescription)
        }
        surface.wake()
    }

    func setShowsBase(_ shows: Bool) {
        guard engine?.state.showsBase != shows else { return }
        engine?.setShowsBase(shows)
        surface.wake()
    }

    // MARK: - Keys

    func scroll(_ amount: ScrollAmount) {
        switch amount {
        case let .step(sign): engine?.step(.line, sign: sign, animated: animates)
        case let .page(sign): engine?.step(.page, sign: sign, animated: animates)
        case let .edge(sign): engine?.step(.edge, sign: sign, animated: animates)
        }
        surface.wake()
    }

    /// ⇥ or ⇧⇥: the next conflict or resolution. Past the file's last one (⇧⇥: its first), or
    /// in a file with none, `onWrap` may move to another file instead.
    func next(forward: Bool) {
        guard let engine else { return }
        let before = engine.state.current
        let region = engine.next(forward: forward, animated: animates)
        let wrapped = switch (before, region) {
        case let (before?, region?): forward ? region <= before : region >= before
        case (_, nil): true
        case (nil, _?): false
        }
        report(region, wrapped: wrapped ? forward : nil)
        surface.wake()
    }

    /// Tells the tab which region is ⇥'s and why (and that ⇥ ran past the file's stops), on the
    /// next main-queue turn: `show` and `next` run inside SwiftUI's update, which drops state
    /// written there.
    private func report(_ region: Int?, wrapped forward: Bool? = nil) {
        let reason = region.flatMap { engine?.reason(region: $0) }
        DispatchQueue.main.async { [weak self] in
            self?.onRegion(region, reason)
            if let forward { self?.onWrap(forward) }
        }
    }

    // MARK: - Pointer

    /// A press on a line or a ribbon of a changed region makes it ⇥'s; anywhere else clears it.
    private func mouse(_ event: CanvasMouse) -> Bool {
        guard case let .down(point, _, _) = event, let engine else { return false }
        let region: Int? = switch engine.hit(x: point.x, y: point.y) {
        case let .line(_, _, region): region.flatMap { engine.regions[safe: $0]?.kind == .unchanged ? nil : $0 }
        case let .ribbon(region): region
        case .header, .none: nil
        }
        engine.select(region: region, reveal: false, animated: false)
        report(region)
        return true
    }

    // MARK: - Reading

    var state: MergeEngine.State? { engine?.state }
    var regions: [MergeEngine.Region] { engine?.regions ?? [] }
    func reason(region: Int) -> String? { engine?.reason(region: region) }
    var visibleText: String { engine?.visibleText ?? "" }
}

/// `MergeCanvasView` in SwiftUI: shows `file` once per `fileID`, follows the base toggle, and
/// takes the shown tab's scroll and ⇥ requests once per serial.
struct MergeCanvas: NSViewRepresentable {
    let file: MergeFile
    /// Changes exactly when `file` does.
    let fileID: String
    let labels: [MergeEngine.Pane: String]
    let showsBase: Bool
    /// The shown tab of the open detail: it takes ↑/↓ and ⇥.
    let active: Bool
    let scrollRequest: ScrollRequest?
    /// ⇥ (`forward`) or ⇧⇥, once per serial.
    let stepRequest: MergeStepRequest?
    let onRegion: (Int?, String?) -> Void
    let onWrap: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MergeCanvasView {
        let view = MergeCanvasView(frame: .zero)
        context.coordinator.scrollSerial = scrollRequest?.serial
        context.coordinator.stepSerial = stepRequest?.serial
        return view
    }

    func updateNSView(_ view: MergeCanvasView, context: Context) {
        let coordinator = context.coordinator
        view.onRegion = onRegion
        view.onWrap = onWrap
        if view.fileID != fileID {
            view.show(file, id: fileID, labels: labels)
        }
        view.setShowsBase(showsBase)
        view.setDrawing(context.environment.panelIsPresented && context.environment.bodyShown)
        if active {
            MergeCanvasView.active = view
            if let scrollRequest, scrollRequest.serial != coordinator.scrollSerial { view.scroll(scrollRequest.amount) }
            if let stepRequest, stepRequest.serial != coordinator.stepSerial { view.next(forward: stepRequest.forward) }
        }
        // A request made while another tab was shown is never replayed here.
        coordinator.scrollSerial = scrollRequest?.serial
        coordinator.stepSerial = stepRequest?.serial
    }

    static func dismantleNSView(_ view: MergeCanvasView, coordinator _: Coordinator) {
        view.teardown()
        if MergeCanvasView.active === view { MergeCanvasView.active = nil }
    }

    @MainActor
    final class Coordinator {
        var scrollSerial: Int?
        var stepSerial: Int?
    }
}
