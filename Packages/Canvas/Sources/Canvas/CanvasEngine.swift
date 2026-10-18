import AppKit
import CCanvas
import QuartzCore

/// Why an engine did not answer: it refused (`failed`: no GPU adapter, a surface it could not
/// configure), a Rust panic was caught at the boundary (`panicked`), or an argument was unusable.
public struct CanvasError: Error, LocalizedError, Equatable, Sendable {
    /// The engine that refused, as its message names it.
    public enum Engine: String, Sendable { case timeline, map, diff, merge }
    public enum Kind: String, Sendable { case failed, panicked, invalid }

    public let engine: Engine
    public let kind: Kind
    public let message: String

    public var errorDescription: String? { "\(engine.rawValue) (\(kind.rawValue)): \(message)" }

    /// Run one of `engine`'s C calls; throw what it reports, freeing its message.
    static func call(_ engine: Engine,
                     _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> CanvasStatus) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = body(&message)
        defer { canvas_string_free(message) }
        guard status != CANVAS_OK else { return }
        let text = message.map { String(cString: $0) } ?? "no message"
        let kind: Kind = switch status {
        case CANVAS_FAILED: .failed
        case CANVAS_PANICKED: .panicked
        default: .invalid
        }
        throw CanvasError(engine: engine, kind: kind, message: text)
    }
}

/// What the canvas host drives (vt-7781 WP5): one engine drawing into its
/// `CAMetalLayer`. The timeline (`TimelineEngine`) and the estate map
/// (`MapEngine`, WP8) are two; every engine shares one host (`CanvasView`).
@MainActor
public protocol CanvasEngine: AnyObject {
    /// Draws into `layer` on the shared device, which it builds on the first attach. `layer`
    /// outlives the engine's target: `detach` first.
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
    /// The pointer, for an engine that handles it itself (a diff selects text, clicks its
    /// gutter and hovers words). True: the engine took it, and the canvas draws again. A taken
    /// `.down` makes the press the engine's: its `.dragged` and `.up` come here too, and the
    /// host's own click, pan and scrub stay out of it. The default takes nothing.
    func mouse(_ event: CanvasMouse) -> Bool
    /// The canvas forwards `.moved` and `.exited` (a tracking area) only while this is true.
    var tracksHover: Bool { get }
}

public extension CanvasEngine {
    func mouse(_: CanvasMouse) -> Bool { false }
    var tracksHover: Bool { false }
}

/// The pointer over a canvas, in its flipped view points.
public enum CanvasMouse: Equatable {
    case down(CGPoint, NSEvent.ModifierFlags, clicks: Int)
    case dragged(CGPoint)
    case up(CGPoint)
    case moved(CGPoint)
    case exited
}

public struct CanvasFrame: Equatable, Sendable {
    /// The scene was built again, not only moved by the camera.
    public let built: Bool
    /// Keep the display link running: something moves every frame.
    public let animating: Bool
    /// How long until a frame is due without input (a running bar grows a point).
    public let nextDue: TimeInterval?

    public init(built: Bool, animating: Bool, nextDue: TimeInterval?) {
        (self.built, self.animating, self.nextDue) = (built, animating, nextDue)
    }
}

extension TimelineEngine: CanvasEngine {
    public var scrubStrip: CGFloat { Self.axisHeight }

    public func magnify(factor: Double, x: Double?, y _: Double?) {
        magnify(factor: factor, x: x)
    }

    public func drawFrame() throws -> CanvasFrame {
        let frame = try frame()
        return CanvasFrame(built: frame.built, animating: frame.animating, nextDue: frame.nextDue)
    }

    /// A mark selects itself and empty lanes clear the selection; a cluster
    /// or a band opens to its span; a rail keeps the selection.
    public func click(x: Double, y: Double) throws -> String? {
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
    public var scrubStrip: CGFloat { 0 }

    public func setNow(_: Date) {}

    public func magnify(factor: Double, x: Double?, y: Double?) {
        magnify(factor: factor, x: x ?? 0, y: y ?? 0)
    }

    public func drawFrame() throws -> CanvasFrame {
        let frame = try frame()
        return CanvasFrame(built: frame.built, animating: frame.animating, nextDue: frame.nextDue)
    }

    public func click(x: Double, y: Double) throws -> String? {
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

    public func playhead(x _: Double?, release _: Bool) {}
}
