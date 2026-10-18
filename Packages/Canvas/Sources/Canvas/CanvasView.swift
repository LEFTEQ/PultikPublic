import AppKit
import CCanvas
import QuartzCore

/// Watches a canvas's frames (the host's frame bench): `willDraw` before the
/// engine draws, `didDraw` after with the frame's own cost. While one is set
/// the display link never sleeps, so every display frame is a sample.
@MainActor
public protocol CanvasFrameObserver: AnyObject {
    /// Before a frame, at the display link's `timestamp`.
    func willDraw(_ view: CanvasView, at timestamp: CFTimeInterval)
    /// After a frame: its link, its cost in milliseconds and whether it built the scene.
    func didDraw(_ view: CanvasView, link: CADisplayLink, cost: Double, built: Bool)
}

/// The canvas (vt-7781 WP5): an AppKit view whose backing layer is the
/// `CAMetalLayer` its engine draws into. Two-finger scrolls (with their
/// momentum, which AppKit sends as events) and pinches go straight to the
/// engine; a click selects what it hits; a drag in the axis strip moves the
/// playhead, and a drag in the lanes pans. An engine that handles the
/// pointer itself (`CanvasEngine.mouse`) takes the press instead, and hears
/// hovers while it `tracksHover`. A display link draws, paused unless the
/// engine is animating or a gesture is in flight.
///
/// Never first responder: the host keeps the keys and routes them to the
/// engine. The canvas attaches when it first shows in a window, and detaches
/// when it is torn down, leaves the window or is handed another engine; the
/// shared device outlives a detach until `CanvasSurface.release`.
public final class CanvasView: NSView {
    /// How the host hears its canvas, each called where the canvas decides it.
    public struct Hooks {
        /// The canvas started or stopped drawing (`setActive`, `teardown`).
        public var shown: @MainActor (Bool) -> Void
        /// A frame was drawn: the camera may have moved. Called from the
        /// display link, so it must touch no SwiftUI state.
        public var viewed: @MainActor () -> Void
        /// The playhead moved (a scrub), `settled` on its release.
        public var playhead: @MainActor (_ settled: Bool) -> Void

        public init(shown: @escaping @MainActor (Bool) -> Void = { _ in },
                    viewed: @escaping @MainActor () -> Void = {},
                    playhead: @escaping @MainActor (_ settled: Bool) -> Void = { _ in }) {
            self.shown = shown
            self.viewed = viewed
            self.playhead = playhead
        }
    }

    /// Names the canvas in its log lines.
    public let id: String
    public var hooks = Hooks()
    /// Watches every frame while set (the host's bench); the canvas holds it weakly.
    public weak var observer: (any CanvasFrameObserver)?

    public private(set) var engine: (any CanvasEngine)?
    public private(set) var attached = false
    /// Drawn and on screen: the host says it is displayed (`setActive`).
    public private(set) var active = false
    /// What fills the layer until the engine's first frame (a code theme switch moves it).
    public var background: NSColor {
        didSet { layer?.backgroundColor = background.cgColor }
    }

    private var link: CADisplayLink?
    /// The frame `nextDue` asked for while the link sleeps (a running bar grows).
    private var dueTimer: Timer?
    private var hover: NSTrackingArea?
    private var scrolling = false
    private var momentum = false
    private var pinching = false
    private var drag: Drag?
    /// Frames drawn and scenes built since the canvas appeared (the panel driver's).
    public private(set) var frames = 0
    public private(set) var builds = 0
    public private(set) var failure: String?

    private enum Drag {
        case press(NSPoint)
        case pan
        case scrub
        /// The engine took the press (`mouse(.down)`): its drag and release go to it.
        case engine
    }

    /// `background` fills the layer until the engine's first frame.
    public init(id: String, background: NSColor) {
        self.id = id
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("CanvasView is built in code")
    }

    deinit {
        // The layer must outlive the engine's target: a canvas dropped without
        // a teardown still lets go of its target first.
        MainActor.assumeIsolated {
            link?.invalidate()
            dueTimer?.invalidate()
            if attached { engine?.detach() }
        }
    }

    override public func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        layer.backgroundColor = background.cgColor
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { false }
    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: - Lifecycle

    /// The host hands the canvas its engine (nil while it has none yet).
    public func use(_ engine: (any CanvasEngine)?) {
        guard engine !== self.engine else { return }
        detach()
        self.engine = engine
        trackHover()
        attachIfNeeded()
    }

    public func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        hooks.shown(active)
        if active {
            attachIfNeeded()
            wake()
        } else {
            scrolling = false
            momentum = false
            pinching = false
            drag = nil
            sleep()
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { attachIfNeeded() }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = scale
        sizeChanged()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func sizeChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard attached, let engine else { return attachIfNeeded() }
        do {
            try engine.resize(size: bounds.size, scale: scale)
        } catch {
            fail("resize", error)
        }
        wake()
    }

    /// The first show: a window, a size, an engine, and the canvas displayed.
    private func attachIfNeeded() {
        guard !attached, active, let engine, let window, let metalLayer, bounds.width > 0, bounds.height > 0
        else { return }
        metalLayer.contentsScale = window.backingScaleFactor
        do {
            try engine.attach(layer: metalLayer, size: bounds.size, scale: window.backingScaleFactor)
        } catch {
            return fail("attach", error)
        }
        attached = true
        failure = nil
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        wake()
    }

    /// Lets go of the engine's target on the shared device; the engine keeps its data and camera.
    public func detach() {
        sleep()
        guard attached else { return }
        engine?.detach()
        attached = false
    }

    /// The host is dropping the canvas: the link and the engine go with it.
    public func teardown() {
        if active { hooks.shown(false) }
        active = false
        detach()
        link?.invalidate()
        link = nil
        engine = nil
        trackHover()
    }

    /// Nothing draws until something moves or a frame falls due.
    private func sleep() {
        link?.isPaused = true
        dueTimer?.invalidate()
        dueTimer = nil
    }

    // MARK: - Frames

    private var inFlight: Bool {
        scrolling || momentum || pinching || drag != nil
    }

    /// Something moved: draw on the next display frame.
    public func wake() {
        guard attached, active else { return }
        dueTimer?.invalidate()
        dueTimer = nil
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard attached, active, let engine else {
            return sleep()
        }
        observer?.willDraw(self, at: link.timestamp)
        let started = CACurrentMediaTime()
        engine.setNow(Date())
        let frame: CanvasFrame
        do {
            frame = try engine.drawFrame()
        } catch {
            fail("frame", error)
            return sleep()
        }
        frames += 1
        if frame.built { builds += 1 }
        // The camera may have moved: the host tells its data layer what is wanted (no SwiftUI state).
        hooks.viewed()
        if let observer {
            observer.didDraw(self, link: link, cost: (CACurrentMediaTime() - started) * 1000, built: frame.built)
            return
        }
        guard !frame.animating, !inFlight else { return }
        sleep()
        // A running bar grows a point at `nextDue`: one frame then, not one per display refresh.
        if let due = frame.nextDue {
            let timer = Timer(timeInterval: max(due, 1.0 / 120), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
            RunLoop.main.add(timer, forMode: .common)
            dueTimer = timer
        }
    }

    /// Whether the display link sleeps (the panel driver's).
    public var sleeping: Bool { link?.isPaused ?? true }

    /// Never silent: a refusal is logged and kept for the panel driver's state.
    private func fail(_ step: String, _ error: Error) {
        failure = "\(step): \(error.localizedDescription)"
        NSLog("pultik: canvas %@ %@ failed: %@", id, step, error.localizedDescription)
    }

    // MARK: - Gestures

    override public func scrollWheel(with event: NSEvent) {
        guard engine != nil, active else { return super.scrollWheel(with: event) }
        switch event.phase {
        case .began, .changed: scrolling = true
        case .ended, .cancelled: scrolling = false
        default: break
        }
        switch event.momentumPhase {
        case .began, .changed: momentum = true
        case .ended, .cancelled: momentum = false
        default: break
        }
        // A wheel's lines become points; a trackpad's deltas are points already.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        applyScroll(dx: Double(event.scrollingDeltaX * unit), dy: Double(event.scrollingDeltaY * unit))
    }

    override public func magnify(with event: NSEvent) {
        guard engine != nil, active else { return super.magnify(with: event) }
        switch event.phase {
        case .began, .changed: pinching = true
        case .ended, .cancelled: pinching = false
        default: break
        }
        let at = point(event)
        applyMagnify(factor: 1 + Double(event.magnification), x: Double(at.x), y: Double(at.y))
    }

    /// The scroll gesture's entry, the bench's too.
    public func applyScroll(dx: Double, dy: Double) {
        if dx != 0 || dy != 0 { engine?.scroll(dx: dx, dy: dy) }
        wake()
    }

    /// The pinch's entry, the bench's too.
    public func applyMagnify(factor: Double, x: Double?, y: Double? = nil) {
        if factor != 1 { engine?.magnify(factor: factor, x: x, y: y ?? Double(bounds.midY)) }
        wake()
    }

    override public func mouseDown(with event: NSEvent) {
        guard let engine, active else { return super.mouseDown(with: event) }
        let at = point(event)
        if engine.mouse(.down(at, event.modifierFlags, clicks: event.clickCount)) {
            drag = .engine
        } else if at.y < engine.scrubStrip {
            drag = .scrub
            scrub(x: Double(at.x), release: false)
        } else {
            drag = .press(at)
        }
        wake()
    }

    /// The playhead's drag entry, the panel driver's scrub too: the engine
    /// moves it, the host throttles what replay reads (`hooks.playhead`).
    public func scrub(x: Double, release: Bool) {
        engine?.playhead(x: x, release: release)
        hooks.playhead(release)
        wake()
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let at = point(event)
        switch drag {
        case .engine:
            _ = engine?.mouse(.dragged(at))
            wake()
        case .scrub:
            scrub(x: Double(at.x), release: false)
        case let .press(start) where hypot(at.x - start.x, at.y - start.y) > 3:
            self.drag = .pan
            applyScroll(dx: Double(at.x - start.x), dy: Double(at.y - start.y))
        case .press:
            break
        case .pan:
            // The content follows the pointer.
            applyScroll(dx: Double(event.deltaX), dy: Double(event.deltaY))
        }
    }

    override public func mouseUp(with event: NSEvent) {
        guard let engine, let drag else { return }
        let at = point(event)
        self.drag = nil
        switch drag {
        case .engine:
            _ = engine.mouse(.up(at))
        case .scrub:
            scrub(x: Double(at.x), release: true)
        case .press:
            do {
                _ = try engine.click(x: Double(at.x), y: Double(at.y))
            } catch {
                fail("click", error)
            }
        case .pan:
            break
        }
        wake()
    }

    // MARK: - Hover

    /// A tracking area over the visible canvas while the engine `tracksHover`, none otherwise.
    private func trackHover() {
        let wanted = engine?.tracksHover ?? false
        if wanted, hover == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                             .inVisibleRect], owner: self)
            addTrackingArea(area)
            hover = area
        } else if !wanted, let hover {
            removeTrackingArea(hover)
            self.hover = nil
        }
    }

    override public func mouseMoved(with event: NSEvent) {
        guard let engine, active, engine.tracksHover else { return super.mouseMoved(with: event) }
        if engine.mouse(.moved(point(event))) { wake() }
    }

    override public func mouseExited(with event: NSEvent) {
        guard let engine, active, engine.tracksHover else { return super.mouseExited(with: event) }
        if engine.mouse(.exited) { wake() }
    }

    private func point(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }
}

/// The one GPU device and text system every canvas draws with (D2,
/// docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md): built by the
/// first attach, kept across detaches, so switching canvases builds none, and
/// dropped by `release` once nothing is attached (else with the last detach).
/// Main-thread only, like the device.
@MainActor
public enum CanvasSurface {
    /// The panel's tree release (30 s hidden): the device goes; the next attach builds it again.
    public static func release() {
        canvas_surface_release()
    }

    /// Devices built since launch: one per process until a release.
    public static var builds: Int { Int(canvas_surface_builds()) }

    /// A shared device exists now.
    public static var live: Bool { canvas_surface_live() }
}
