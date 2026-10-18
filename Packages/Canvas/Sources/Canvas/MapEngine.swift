import CCanvas
import Foundation
import QuartzCore

/// The live estate map (D11): Semafor's boxes, apps, topology and backup copies in; Rust lays
/// them out (a port of Semafor's `layout.ts`), hit-tests, walks the arrows and draws into the
/// host's `CAMetalLayer`. Words (`synced`, `wireguard`, `storagebox`) stay Semafor's own: the
/// engine parses them and refuses one it does not know. Main-thread only.
@MainActor
public final class MapEngine {
    public struct App: Equatable, Sendable {
        public var name, sync, health: String
        public var note: String?
        public init(name: String, sync: String, health: String, note: String? = nil) {
            (self.name, self.sync, self.health, self.note) = (name, sync, health, note)
        }
    }

    public struct Rollout: Equatable, Sendable {
        public var gateway: Bool
        public var target, app: String?
        public init(gateway: Bool, target: String?, app: String?) {
            (self.gateway, self.target, self.app) = (gateway, target, app)
        }
    }

    public struct Box: Equatable, Sendable {
        public var name, sync: String
        public var addr, line: String?
        public var apps: [App]
        public var rollouts: [Rollout]
        public init(name: String, sync: String, addr: String?, line: String?, apps: [App], rollouts: [Rollout]) {
            (self.name, self.sync, self.addr, self.line, self.apps, self.rollouts) = (name, sync, addr, line, apps, rollouts)
        }
    }

    public struct Node: Equatable, Sendable {
        public var id, kind, label, detail: String
        public var place: String?
        public init(id: String, kind: String, label: String, detail: String, place: String?) {
            (self.id, self.kind, self.label, self.detail, self.place) = (id, kind, label, detail, place)
        }
    }

    public struct Edge: Equatable, Sendable {
        public var id, from, to, kind, label: String
        public var both: Bool
        public var targets: [String]?
        public init(id: String, from: String, to: String, kind: String, label: String, both: Bool, targets: [String]?) {
            (self.id, self.from, self.to, self.kind, self.label, self.both, self.targets) = (id, from, to, kind, label, both, targets)
        }
    }

    /// One backup pipeline's copy at one place whose state is not `none`.
    public struct Copy: Equatable, Sendable {
        public var box, pipeline, place, state: String
        public var location: String?
        public var age: TimeInterval?
        public init(box: String, pipeline: String, place: String, state: String, location: String?, age: TimeInterval?) {
            (self.box, self.pipeline, self.place, self.state, self.location, self.age) = (box, pipeline, place, state, location, age)
        }
    }

    public enum Direction: UInt8, Sendable { case up = 0, down, left, right }

    public enum Hit: Equatable, Sendable { case none, card(String), link(String), frame(String) }

    nonisolated(unsafe) let handle: OpaquePointer

    public init(palette: TimelineEngine.Palette) throws {
        var palette = palette.c
        var out: OpaquePointer?
        try CanvasError.call(.map) { canvas_map_new(&palette, &out, $0) }
        guard let out else { throw CanvasError(engine: .map, kind: .invalid, message: "no map handle") }
        handle = out
    }

    deinit { canvas_map_free(handle) }

    public func attach(layer: CAMetalLayer, size: CGSize, scale: CGFloat) throws {
        let raw = Unmanaged.passUnretained(layer).toOpaque()
        try CanvasError.call(.map) {
            canvas_map_attach(handle, raw, Double(size.width), Double(size.height), Double(scale), $0)
        }
    }

    public func detach() { canvas_map_detach(handle) }

    public func resize(size: CGSize, scale: CGFloat) {
        canvas_map_resize(handle, Double(size.width), Double(size.height), Double(scale))
    }

    public func setPalette(_ palette: TimelineEngine.Palette) {
        var palette = palette.c
        canvas_map_set_palette(handle, &palette)
    }

    /// Replace the estate. `copies` nil: the backups did not load.
    public func setEstate(boxes: [Box], nodes: [Node], edges: [Edge], copies: [Copy]?) throws {
        var a = TextArena()
        let boxText = boxes.map { b in
            (
                [a.add(b.name), a.add(b.sync), a.add(b.addr ?? ""), a.add(b.line ?? "")],
                b.apps.map { [a.add($0.name), a.add($0.sync), a.add($0.health), a.add($0.note ?? "")] },
                b.rollouts.map { [a.add($0.target ?? ""), a.add($0.app ?? "")] }
            )
        }
        let nodeText = nodes.map { [a.add($0.id), a.add($0.kind), a.add($0.label), a.add($0.detail), a.add($0.place ?? "")] }
        let edgeText = edges.map { e in
            ([a.add(e.id), a.add(e.from), a.add(e.to), a.add(e.kind), a.add(e.label)], (e.targets ?? []).map { a.add($0) })
        }
        let copyText = (copies ?? []).map { [a.add($0.box), a.add($0.pipeline), a.add($0.place), a.add($0.state), a.add($0.location ?? "")] }
        try a.with { base in
            // Every nested array flattened into one, each owner pointing at its run of it.
            let apps = zip(boxes, boxText).flatMap { _, t in
                t.1.map { CanvasMapApp(name: $0[0].at(base), sync: $0[1].at(base), health: $0[2].at(base), note: $0[3].at(base)) }
            }
            let rollouts = zip(boxes, boxText).flatMap { b, t in
                zip(b.rollouts, t.2).map { r, s in CanvasMapRollout(gateway: r.gateway, target: s[0].at(base), app: s[1].at(base)) }
            }
            let targets = edgeText.flatMap { $0.1.map { $0.at(base) } }
            var cNodes = nodeText.map {
                CanvasMapNode(id: $0[0].at(base), kind: $0[1].at(base), label: $0[2].at(base), detail: $0[3].at(base), place: $0[4].at(base))
            }
            var cCopies = zip(copies ?? [], copyText).map { c, t in
                CanvasMapCopy(
                    box_name: t[0].at(base), pipeline: t[1].at(base), place: t[2].at(base), state: t[3].at(base),
                    location: t[4].at(base), age_s: c.age ?? .nan
                )
            }
            try apps.withUnsafeBufferPointer { appsP in
                try rollouts.withUnsafeBufferPointer { rollP in
                    try targets.withUnsafeBufferPointer { targP in
                        var (ai, ri, ti) = (0, 0, 0)
                        var cBoxes: [CanvasMapBox] = []
                        for (b, t) in zip(boxes, boxText) {
                            cBoxes.append(CanvasMapBox(
                                name: t.0[0].at(base), sync: t.0[1].at(base), addr: t.0[2].at(base), line: t.0[3].at(base),
                                apps: b.apps.isEmpty ? nil : appsP.baseAddress.map { $0 + ai }, app_count: b.apps.count,
                                rollouts: b.rollouts.isEmpty ? nil : rollP.baseAddress.map { $0 + ri }, rollout_count: b.rollouts.count
                            ))
                            ai += b.apps.count
                            ri += b.rollouts.count
                        }
                        var cEdges: [CanvasMapEdge] = []
                        for (e, t) in zip(edges, edgeText) {
                            let n = e.targets?.count ?? 0
                            cEdges.append(CanvasMapEdge(
                                id: t.0[0].at(base), from: t.0[1].at(base), to: t.0[2].at(base), kind: t.0[3].at(base),
                                label: t.0[4].at(base), both: e.both, has_targets: e.targets != nil,
                                targets: n == 0 ? nil : targP.baseAddress.map { $0 + ti }, target_count: n
                            ))
                            ti += n
                        }
                        try CanvasError.call(.map) {
                            canvas_map_set_estate(
                                handle, &cBoxes, cBoxes.count, &cNodes, cNodes.count, &cEdges, cEdges.count,
                                &cCopies, cCopies.count, copies != nil, $0
                            )
                        }
                    }
                }
            }
        }
    }

    /// Two fingers moved the map by (`dx`, `dy`) points.
    public func scroll(dx: Double, dy: Double) { canvas_map_scroll(handle, dx, dy) }

    /// A pinch by `factor` around view point (`x`, `y`).
    public func magnify(factor: Double, x: Double, y: Double) { canvas_map_magnify(handle, factor, x, y) }

    public func fit() { canvas_map_fit(handle) }

    /// An arrow: the nearest card that way, brought into view.
    public func walk(_ direction: Direction) { canvas_map_walk(handle, direction.rawValue) }

    public func select(_ id: String?) throws {
        var bytes = Array((id ?? "").utf8)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            let s = CanvasStr(ptr: UnsafePointer(buffer.baseAddress), len: buffer.count)
            try CanvasError.call(.map) { canvas_map_select(handle, s, $0) }
        }
    }

    public var selected: String? {
        guard let raw = canvas_map_selected(handle) else { return nil }
        defer { canvas_string_free(raw) }
        return String(cString: raw)
    }

    /// What ↵ opens: the selected card's live app, as (box, app).
    public var selectedApp: (box: String, app: String)? {
        var box: UnsafeMutablePointer<CChar>?
        var app: UnsafeMutablePointer<CChar>?
        guard canvas_map_selected_app(handle, &box, &app), let box, let app else { return nil }
        defer {
            canvas_string_free(box)
            canvas_string_free(app)
        }
        return (String(cString: box), String(cString: app))
    }

    public func hit(x: Double, y: Double) throws -> Hit {
        var out = CanvasTimelineHit(kind: 0, id: nil, from: .nan, to: .nan)
        try CanvasError.call(.map) { canvas_map_hit(handle, x, y, &out, $0) }
        defer { canvas_string_free(out.id) }
        let id = out.id.map { String(cString: $0) } ?? ""
        switch Int32(out.kind) {
        case CANVAS_TIMELINE_HIT_CARD: return .card(id)
        case CANVAS_TIMELINE_HIT_LINK: return .link(id)
        case CANVAS_TIMELINE_HIT_FRAME: return .frame(id)
        default: return .none
        }
    }

    /// Draw a frame if anything changed; call it from the display link while `animating`.
    public func frame() throws -> TimelineEngine.Frame {
        var out = CanvasFrameReport(built: false, presented: false, animating: false, next_due_ms: .nan)
        try CanvasError.call(.map) { canvas_map_frame(handle, &out, $0) }
        return TimelineEngine.Frame(built: out.built, presented: out.presented, animating: out.animating, nextDue: nil)
    }
}
