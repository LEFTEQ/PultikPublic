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
/// DDC is I2C with sleeps in it — and a click during a pass is dropped, not
/// queued.
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
        activeID = preset.id
        guard !isApplying else { pending = preset; return }
        isApplying = true
        Task.detached(priority: .userInitiated) {
            Self.push(preset)
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
    }

    // MARK: Editing (Settings ▸ Displays)

    /// Replaces the whole list; the pane edits a copy and pushes it here.
    /// Re-applies the active preset at once when its values moved, so a
    /// slider drag is live feedback rather than a promise for next time.
    func setPresets(_ new: [Preset]) {
        let previous = active
        presets = new
        var prefs = Preferences.load()
        prefs.displayPresets = new
        prefs.save()
        guard let previous else { return }
        guard let index = new.firstIndex(where: { $0.id == previous.id }) else {
            activeID = nil
            return
        }
        if new[index] != previous { apply(index: index) }
    }

    func resetToDefaults() {
        setPresets(Preset.defaults)
    }
}
