import AppKit
import QuartzCore
import SwiftUI
import Timeline

/// What the canvas host drives (vt-7781 WP5): one engine drawing into its
/// `CAMetalLayer`. The timeline (`TimelineEngine`) is one and the estate map
/// (`MapEngine`, WP8) the other; both share one host.
@MainActor
protocol CanvasEngine: AnyObject {
    /// Creates the GPU device and draws into `layer`, which outlives it (`detach` first).
    func attach(layer: CAMetalLayer, size: CGSize, scale: CGFloat) throws
    func detach()
    func resize(size: CGSize, scale: CGFloat) throws
    func setNow(_ now: Date)
    /// Two fingers moved the content by (`dx`, `dy`) points.
    func scroll(dx: Double, dy: Double)
    /// A pinch by `factor` around view point (`x`, `y`); nil: the centre.
    /// A timeline zooms time only, so it reads `x` alone.
    func magnify(factor: Double, x: Double?, y: Double?)
    /// Draws a frame if anything changed.
    func drawFrame() throws -> CanvasFrame
    /// A click at a view point selects what it hits; the selection after it.
    func click(x: Double, y: Double) throws -> String?
    /// The strip along the top a drag scrubs the playhead in, points; 0: no playhead.
    var scrubStrip: CGFloat { get }
    func playhead(x: Double?, release: Bool)
}

struct CanvasFrame: Equatable {
    /// The scene was built again, not only moved by the camera.
    let built: Bool
    /// Keep the display link running: something moves every frame.
    let animating: Bool
    /// How long until a frame is due without input (a running bar grows a point).
    let nextDue: TimeInterval?
}

extension TimelineEngine: CanvasEngine {
    var scrubStrip: CGFloat { Self.axisHeight }

    func magnify(factor: Double, x: Double?, y _: Double?) {
        magnify(factor: factor, x: x)
    }

    func drawFrame() throws -> CanvasFrame {
        let frame = try frame()
        return CanvasFrame(built: frame.built, animating: frame.animating, nextDue: frame.nextDue)
    }

    /// A mark selects itself and empty lanes clear the selection; a cluster
    /// or a band opens to its span; a rail keeps the selection.
    func click(x: Double, y: Double) throws -> String? {
        switch try hit(x: x, y: y) {
        case let .mark(id):
            try select(id)
        case .none:
            try select(nil)
        case let .cluster(from, to):
            zoom(to: from ... max(from, to))
        case let .band(_, from, to):
            zoom(to: from ... max(from, to ?? Date()))
        case .rail:
            break
        }
        return selected
    }
}

/// The estate map on the same host (vt-7781 WP8): no playhead (its scrub
/// strip is 0), no clock; a click selects the card it hits and clears on
/// empty ground or a box's frame; the display link runs only while a
/// deploy flows (`animating`). It fits itself on its first frame with data.
extension MapEngine: CanvasEngine {
    var scrubStrip: CGFloat { 0 }

    func setNow(_: Date) {}

    func magnify(factor: Double, x: Double?, y: Double?) {
        magnify(factor: factor, x: x ?? 0, y: y ?? 0)
    }

    func drawFrame() throws -> CanvasFrame {
        let frame = try frame()
        return CanvasFrame(built: frame.built, animating: frame.animating, nextDue: frame.nextDue)
    }

    func click(x: Double, y: Double) throws -> String? {
        switch try hit(x: x, y: y) {
        case let .card(id):
            try select(id)
        case .none, .frame:
            try select(nil)
        case .link:
            break
        }
        return selected
    }

    func playhead(x _: Double?, release _: Bool) {}
}

extension TimelineEngine.Palette {
    /// Pultík's tokens (vt-7727 D4, DESIGN.md §2): colour means status, the
    /// accent is the selection ring and the playhead, never a status.
    static var pultik: Self {
        Self(background: .theme(Theme.canvas), band: .theme(Theme.surface), foreground: .theme(Theme.ink),
             muted: .theme(Theme.ink3), grid: .theme(Theme.hairline), data: .theme(Theme.data), ok: .theme(Theme.ok),
             danger: .theme(Theme.danger), warning: .theme(Theme.warn), accent: .theme(Theme.accent))
    }
}

extension TimelineColor {
    /// A `Theme` token as the renderer takes it: straight-alpha sRGB.
    static func theme(_ color: Color) -> TimelineColor {
        let resolved = color.resolve(in: EnvironmentValues())
        return TimelineColor(red: resolved.red, green: resolved.green, blue: resolved.blue, alpha: resolved.opacity)
    }
}

/// The canvas (vt-7781 WP5): an AppKit view whose backing layer is the
/// `CAMetalLayer` its engine draws into. Two-finger scrolls (with their
/// momentum, which AppKit sends as events) and pinches go straight to the
/// engine; a click selects what it hits; a drag in the axis strip moves the
/// playhead, and a drag in the lanes pans. A display link draws, paused
/// unless the engine is animating or a gesture is in flight.
///
/// Never first responder: the search field keeps the keys and
/// `KeyboardCoordinator` routes them to the engine (`TimelineStage.perform`).
/// The GPU device appears when the canvas first shows in a window, and goes
/// when it is dismantled, leaves the window or the panel's tree is released
/// after 30 s hidden (`TimelineStage.release`).
final class TimelineCanvasView: NSView {
    let slot: CanvasSlot

    private(set) var engine: (any CanvasEngine)?
    private(set) var attached = false
    /// Drawn and on screen: the module is displayed and the panel presented.
    private(set) var active = false
    private var link: CADisplayLink?
    /// The frame `nextDue` asked for while the link sleeps (a running bar grows).
    private var dueTimer: Timer?
    private var scrolling = false
    private var momentum = false
    private var pinching = false
    private var drag: Drag?
    /// Frames drawn and scenes built since the canvas appeared (the panel driver's).
    private(set) var frames = 0
    private(set) var builds = 0
    private(set) var failure: String?
    #if DEBUG
    var bench: TimelineBench?
    #endif

    private enum Drag {
        case press(NSPoint)
        case pan
        case scrub
    }

    init(slot: CanvasSlot) {
        self.slot = slot
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("TimelineCanvasView is built in code")
    }

    deinit {
        // The layer must outlive the engine's target: a canvas dropped without
        // a dismantle still lets go of its device first.
        MainActor.assumeIsolated {
            link?.invalidate()
            dueTimer?.invalidate()
            if attached { engine?.detach() }
        }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        layer.backgroundColor = NSColor(Theme.canvas).cgColor
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: - Lifecycle

    /// The stage hands the slot's engine (nil while the slot has none yet).
    func use(_ engine: (any CanvasEngine)?) {
        guard engine !== self.engine else { return }
        detach()
        self.engine = engine
        attachIfNeeded()
    }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        TimelineStage.shared.shown(slot, active)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { attachIfNeeded() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeChanged()
    }

    override func viewDidChangeBackingProperties() {
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

    /// Releases the GPU device; the engine keeps its data and camera.
    func detach() {
        sleep()
        guard attached else { return }
        engine?.detach()
        attached = false
    }

    /// The representable is going: the link and the device go with it.
    func teardown() {
        if active { TimelineStage.shared.shown(slot, false) }
        active = false
        detach()
        link?.invalidate()
        link = nil
        engine = nil
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
    func wake() {
        guard attached, active else { return }
        dueTimer?.invalidate()
        dueTimer = nil
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard attached, active, let engine else {
            return sleep()
        }
        #if DEBUG
        bench?.drive(self, at: link.timestamp)
        let started = CACurrentMediaTime()
        #endif
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
        // The camera may have moved: the stage tells the data layer what is wanted (no SwiftUI state).
        TimelineStage.shared.viewed(slot)
        #if DEBUG
        if let bench {
            bench.record(link, cost: (CACurrentMediaTime() - started) * 1000, built: frame.built, canvas: self)
            return
        }
        #endif
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

    /// Ticks since the canvas appeared, and whether it sleeps (the panel driver's).
    var sleeping: Bool { link?.isPaused ?? true }

    /// Never silent: a refusal is logged and kept for the panel driver's state.
    private func fail(_ step: String, _ error: Error) {
        failure = "\(step): \(error.localizedDescription)"
        NSLog("pultik: timeline %@ %@ failed: %@", slot.rawValue, step, error.localizedDescription)
    }

    // MARK: - Gestures

    override func scrollWheel(with event: NSEvent) {
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

    override func magnify(with event: NSEvent) {
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
    func applyScroll(dx: Double, dy: Double) {
        if dx != 0 || dy != 0 { engine?.scroll(dx: dx, dy: dy) }
        wake()
    }

    /// The pinch's entry, the bench's too.
    func applyMagnify(factor: Double, x: Double?, y: Double? = nil) {
        if factor != 1 { engine?.magnify(factor: factor, x: x, y: y ?? Double(bounds.midY)) }
        wake()
    }

    override func mouseDown(with event: NSEvent) {
        guard let engine, active else { return super.mouseDown(with: event) }
        let at = point(event)
        if at.y < engine.scrubStrip {
            drag = .scrub
            scrub(x: Double(at.x), release: false)
        } else {
            drag = .press(at)
        }
        wake()
    }

    /// The playhead's drag entry, the panel driver's scrub too: the engine
    /// moves it, the stage throttles what replay reads (`ReplayClock`).
    func scrub(x: Double, release: Bool) {
        engine?.playhead(x: x, release: release)
        TimelineStage.shared.playheadMoved(slot, settled: release)
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let at = point(event)
        switch drag {
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

    override func mouseUp(with event: NSEvent) {
        guard let engine, let drag else { return }
        let at = point(event)
        self.drag = nil
        switch drag {
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

    private func point(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }
}

/// The canvas in a module's view. The engine lives in `TimelineStage`, so a
/// remounted canvas (⇥ away and back) keeps its camera and selection.
struct TimelineCanvas: NSViewRepresentable {
    let slot: CanvasSlot
    /// The canvas's module is the one displayed (a warm hidden body draws nothing).
    let active: Bool

    func makeNSView(context _: Context) -> TimelineCanvasView {
        TimelineCanvasView(slot: slot)
    }

    func updateNSView(_ view: TimelineCanvasView, context: Context) {
        TimelineStage.shared.mount(view)
        view.setActive(active && context.environment.panelIsPresented)
    }

    static func dismantleNSView(_ view: TimelineCanvasView, coordinator _: ()) {
        TimelineStage.shared.unmount(view)
        view.teardown()
    }
}
