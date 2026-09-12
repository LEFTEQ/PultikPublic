import AppKit
import CoreGraphics
import Foundation
import Observation

/// Display presets (docs/specs/2026-09-06-display-presets-decisions.md).
///
/// Each preset is an absolute brightness percent plus a Night Shift setting.
/// Applying one puts every controllable display at that level and Night
/// Shift where the preset says; there is no snapshot and no restore — the
/// next preset is the way back. `cycle()` is what the vitals-dock button runs,
/// `apply(_:)` what a preset's quick command runs.
///
/// Two display families: Apple panels (built-in, Studio Display, Pro Display
/// XDR) through `DisplayServices`, third-party monitors through `DDCDisplays`;
/// Night Shift through `NightShift`. Every write runs off the main actor —
/// DDC is I2C with sleeps in it — and a request arriving mid-pass is coalesced
/// into a single `pending` slot and run when the pass ends, so the last value
/// always lands. (This said "dropped, not queued" until 2026-09-10; the code
/// has queued since the feature shipped.)
///
/// Failures are silent by law: a display that refuses a write is skipped,
/// and with nothing controllable the store reports `isAvailable == false`
/// and the dock button is not drawn.
@Observable
@MainActor
final class BrightnessStore {
    typealias Preset = Preferences.DisplayPreset

    static let shared = BrightnessStore()

    /// Cached from settings at launch and on every edit. `QuickCommands.all`
    /// reads it on each palette keystroke, so it must never hit the disk.
    private(set) var presets: [Preset]

    /// Id of the last applied preset, nil until one is applied this run.
    /// Not persisted: a relaunch cannot know what the displays are at.
    /// An id, not an offset, so reorder and delete never move "active".
    private(set) var activeID: String?

    /// True while a pass is talking to the monitors.
    private(set) var isApplying = false

    /// A preset asked for during a pass (a slider still moving while DDC is
    /// mid-write). Applied when the pass ends, so the last value always lands.
    private var pending: Preset?

    /// Trailing write for a drag that never sends a drop — see `previewPresets`.
    private var persistDebounce: Task<Void, Never>?

    private init() {
        presets = Preferences.load().displayPresets ?? Preset.defaults
    }

    var activeIndex: Int? { presets.firstIndex { $0.id == activeID } }

    var active: Preset? { activeIndex.map { presets[$0] } }

    /// The preset the dock button will apply on its next click.
    var next: Preset? {
        guard !presets.isEmpty else { return nil }
        guard let activeIndex else { return presets[0] }
        return presets[(activeIndex + 1) % presets.count]
    }

    /// At least one Apple display answers DisplayServices. Deliberately does
    /// not probe DDC — that costs I2C round trips and this is read by a view.
    var isAvailable: Bool { !DisplayServices.controllableDisplays().isEmpty }

    // MARK: Applying

    func cycle() {
        guard !presets.isEmpty else { return }
        apply(index: ((activeIndex ?? -1) + 1) % presets.count)
    }

    func apply(index: Int) {
        guard presets.indices.contains(index) else { return }
        let preset = presets[index]
        // A preset applied while dark is the way back too: the display levels
        // it writes replace the remembered ones. The keyboard is only replaced
        // when the preset sets it; a "keep" preset would otherwise leave the
        // keys at the blackout's 0, so those come back from the snapshot.
        //
        // Deliberately BEFORE the coalescing guard: a request that arrives
        // mid-pass must still disarm the blackout now, or the wake monitor
        // survives and the next mouse move restores the snapshot on top of the
        // preset that is about to land.
        let keyboardsToRestore = preset.keyboardLevel == nil ? (snapshot?.keyboards ?? []) : []
        endBlackout()
        // Coalesce first, publish second. Writing `activeID` before this guard
        // moved "active" for a request that had not run yet, so the dock
        // button's next-preset glyph could name a preset the displays were not
        // at.
        guard !isApplying else { pending = preset; return }
        // @Observable has no equality guard: an unconditional write dirties
        // every view reading `activeID` even when nothing moved, and during a
        // drag that is one redundant invalidation of the whole pane per frame.
        if activeID != preset.id { activeID = preset.id }
        isApplying = true
        Task.detached(priority: .userInitiated) {
            Self.push(preset)
            for (keyboard, level) in keyboardsToRestore { KeyboardBacklight.setBrightness(level, of: keyboard) }
            await MainActor.run { self.finishPass() }
        }
    }

    private func finishPass() {
        isApplying = false
        guard let queued = pending else { return }
        pending = nil
        if let index = presets.firstIndex(where: { $0.id == queued.id }) {
            apply(index: index)
        }
    }

    private nonisolated static func push(_ preset: Preset) {
        switch preset.nightShift {
        case .on: NightShift.setEnabled(true)
        case .off: NightShift.setEnabled(false)
        case .keep: break
        }
        for display in DisplayServices.controllableDisplays() {
            DisplayServices.setBrightness(preset.level, of: display)
        }
        for display in DDCDisplays.displays() {
            DDCDisplays.setBrightness(preset.level, of: display)
        }
        if let keys = preset.keyboardLevel {
            for keyboard in KeyboardBacklight.keyboards() {
                KeyboardBacklight.setBrightness(keys, of: keyboard)
            }
        }
    }

    // MARK: Screens off (spec 2026-09-10 decisions 2 and 7)

    /// Every level the blackout will put back. Keyed the way the bridges
    /// key their displays; a DDC monitor is `DDCDisplays.Display`.
    private struct Snapshot: @unchecked Sendable {
        var apple: [(CGDirectDisplayID, Double)] = []
        var ddc: [(DDCDisplays.Display, Double)] = []
        var keyboards: [(UInt64, Double)] = []
    }

    private var snapshot: Snapshot?
    private var wakeMonitor: Any?

    /// True while the screens are blacked out and a mouse move will wake them.
    var isBlackedOut: Bool { snapshot != nil }

    /// Brightness 0 on every display and keyboard without ever sleeping a
    /// display — display sleep is what starts the lock timer. Levels are
    /// remembered and `wake()` puts them back; a mouse move or the ⌥Space
    /// summon calls it. A preset applied while dark also ends the blackout.
    func blackout() {
        guard snapshot == nil, !isApplying else { return }
        isApplying = true
        Task.detached(priority: .userInitiated) {
            let taken = Self.takeSnapshot()
            Self.pushDark(taken)
            await MainActor.run {
                self.snapshot = taken
                self.installWakeMonitor()
                self.finishPass()
            }
        }
    }

    /// Restores every remembered level. Safe to call when not blacked out.
    func wake() {
        guard let taken = snapshot else { return }
        endBlackout()
        Task.detached(priority: .userInitiated) {
            Self.restore(taken)
        }
    }

    private func endBlackout() {
        snapshot = nil
        if let wakeMonitor { NSEvent.removeMonitor(wakeMonitor) }
        wakeMonitor = nil
    }

    /// A mouse monitor needs no permission; a key monitor would need
    /// Accessibility, so the keyboard's way back is the ⌥Space summon.
    private func installWakeMonitor() {
        guard wakeMonitor == nil else { return }
        wakeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }
    }

    private nonisolated static func takeSnapshot() -> Snapshot {
        var taken = Snapshot()
        for display in DisplayServices.controllableDisplays() {
            if let level = DisplayServices.brightness(of: display) { taken.apple.append((display, level)) }
        }
        for display in DDCDisplays.displays() {
            // A live read, NOT `display.brightness`: discovery caches its probe
            // so that an apply pass costs 0.32 ms instead of 176 ms, which
            // leaves `current` frozen at whatever it was when the monitor was
            // first seen. The blackout is the one caller that must know where
            // the monitor is right now, because it is about to put it back.
            taken.ddc.append((display, DDCDisplays.currentBrightness(of: display) ?? display.brightness))
        }
        for keyboard in KeyboardBacklight.keyboards() {
            if let level = KeyboardBacklight.brightness(of: keyboard) { taken.keyboards.append((keyboard, level)) }
        }
        return taken
    }

    private nonisolated static func pushDark(_ taken: Snapshot) {
        for (display, _) in taken.apple { DisplayServices.setBrightness(0, of: display) }
        for (display, _) in taken.ddc { DDCDisplays.setBrightness(0, of: display) }
        for (keyboard, _) in taken.keyboards { KeyboardBacklight.setBrightness(0, of: keyboard) }
    }

    private nonisolated static func restore(_ taken: Snapshot) {
        for (display, level) in taken.apple { DisplayServices.setBrightness(level, of: display) }
        for (display, level) in taken.ddc { DDCDisplays.setBrightness(level, of: display) }
        for (keyboard, level) in taken.keyboards { KeyboardBacklight.setBrightness(level, of: keyboard) }
    }

    // MARK: Editing (Settings ▸ Displays)

    /// Adopts a new list in memory and re-applies the active preset when its
    /// values moved, so an edit is live on the monitors rather than a promise
    /// for next time. Persistence is the caller's business — see
    /// `previewPresets` versus `setPresets`.
    private func adopt(_ new: [Preset]) {
        let previous = active
        presets = new
        guard let previous else { return }
        guard let index = new.firstIndex(where: { $0.id == previous.id }) else {
            activeID = nil
            return
        }
        if new[index] != previous { apply(index: index) }
    }

    /// A drag in progress: the list moves in memory and the monitors follow,
    /// but nothing touches the disk. The drop calls `setPresets` exactly once.
    ///
    /// This split is the whole point of the 2026-09-10 pass. `setPresets` per
    /// slider frame meant a decode + 5 migrations + a pretty-printed encode +
    /// an atomic file replace on the main actor for every pixel of the drag —
    /// ~1.1 ms of blocking filesystem work at whatever rate AppKit could
    /// deliver mouse events, which is to say "as fast as the main thread can
    /// finish the last one".
    func previewPresets(_ new: [Preset]) {
        adopt(new)
        // Safety net, not the main path: a keyboard or VoiceOver adjustment of
        // a Slider does not reliably bracket with `onEditingChanged`, so a
        // preview that never gets its commit must still land. One write after
        // the value settles, and the drop cancels it by committing first.
        persistDebounce?.cancel()
        persistDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persist()
        }
    }

    /// Replaces the whole list and persists it: add, remove, reorder, rename,
    /// Night Shift, and the end of a slider drag.
    func setPresets(_ new: [Preset]) {
        persistDebounce?.cancel()
        persistDebounce = nil
        adopt(new)
        persist()
    }

    private func persist() {
        let snapshot = presets
        Preferences.update { $0.displayPresets = snapshot }
    }

    func resetToDefaults() {
        setPresets(Preset.defaults)
    }
}
