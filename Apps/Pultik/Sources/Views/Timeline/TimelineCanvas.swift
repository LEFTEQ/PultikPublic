import AppKit
import Canvas
import SwiftUI

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

/// The canvas in a module's view (`Packages/Canvas`' `CanvasView`). The engine
/// lives in `TimelineStage`, so a remounted canvas (⇥ away and back) keeps its
/// camera and selection; the canvas's hooks tell the stage about its slot.
struct TimelineCanvas: NSViewRepresentable {
    let slot: CanvasSlot
    /// The canvas's module is the one displayed (a warm hidden body draws nothing).
    let active: Bool

    func makeNSView(context _: Context) -> CanvasView {
        let view = CanvasView(id: slot.rawValue, background: NSColor(Theme.canvas))
        let slot = slot
        view.hooks = CanvasView.Hooks(
            shown: { TimelineStage.shared.shown(slot, $0) },
            viewed: { TimelineStage.shared.viewed(slot) },
            playhead: { TimelineStage.shared.playheadMoved(slot, settled: $0) }
        )
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        TimelineStage.shared.mount(view, slot: slot)
        view.setActive(active && context.environment.panelIsPresented)
    }

    static func dismantleNSView(_ view: CanvasView, coordinator _: ()) {
        TimelineStage.shared.unmount(view)
        view.teardown()
    }
}
