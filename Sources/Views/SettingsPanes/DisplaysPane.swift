import SwiftUI

/// Settings ▸ Displays (docs/specs/2026-09-06-display-presets-decisions.md,
/// drag semantics in docs/specs/2026-09-10-display-preset-drag-decisions.md):
/// the named brightness presets the palette and the vitals-dock button apply.
///
/// Edits a copy. A slider drag `preview`s — in memory, live on the monitors —
/// and only the drop `commit`s to disk; every discrete edit commits directly.
struct DisplaysPane: View {
    private typealias Preset = Preferences.DisplayPreset

    private let store = BrightnessStore.shared
    @State private var presets = BrightnessStore.shared.presets
    @State private var nightShiftNow = NightShift.isEnabled

    var body: some View {
        Form {
            Section {
                // Keyed on the preset's stable id, not its offset: rows carry
                // escaping bindings that close over `index`, and positional
                // identity means a delete re-identifies every row below it
                // while those bindings are still live.
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, _ in
                    row(index)
                }
                HStack {
                    Button("Add preset") {
                        presets.append(Preset(name: uniqueName("Preset"), brightness: 50, nightShift: .keep))
                        commit()
                    }
                    Spacer()
                    Button("Reset to defaults") {
                        presets = Preset.defaults
                        commit()
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Each preset is a name you can type in the palette, an absolute brightness for every display, and what to do with Night Shift. The sun/moon beside “This Mac” in the vitals dock cycles through them in this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Night Shift") {
                    if NightShift.isAvailable {
                        Toggle("", isOn: Binding(
                            get: { nightShiftNow ?? false },
                            set: { on in
                                NightShift.setEnabled(on)
                                nightShiftNow = NightShift.isEnabled
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    } else {
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(NightShift.isAvailable
                     ? "The Mac's current Night Shift state — the same switch as Control Center. Presets set to Keep leave it alone."
                     : "CoreBrightness could not be loaded on this Mac; presets still apply brightness and the Night Shift column is ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The settings window outlives its panes' first appearance: re-read
        // what the palette may have changed since.
        .onAppear {
            presets = store.presets
            nightShiftNow = NightShift.isEnabled
        }
        .onChange(of: store.isApplying) { _, applying in
            if !applying { nightShiftNow = NightShift.isEnabled }
        }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let isActive = store.activeIndex == index
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: Binding(
                    get: { presets[index].name },
                    set: { presets[index].name = $0 }
                ), onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 140)
                if isActive {
                    Text("active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                // A grouped Form on macOS has no swipe or drag handles, so the
                // list verbs are explicit buttons.
                Button { presets.swapAt(index, index - 1); commit() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move \(presets[index].name) up")
                Button { presets.swapAt(index, index + 1); commit() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == presets.count - 1)
                .help("Move down")
                .accessibilityLabel("Move \(presets[index].name) down")
                Button(role: .destructive) { presets.remove(at: index); commit() } label: {
                    Image(systemName: "trash")
                }
                .help("Remove preset")
                .accessibilityLabel("Remove \(presets[index].name)")
            }
            HStack {
                // The drag itself never persists: `preview` moves the list in
                // memory and lets the monitors follow, and the drop commits
                // once. Same shape as the fan-curve chart, which has always
                // written on `.onEnded` only (FanCurveChart.dragGesture).
                Slider(value: Binding(
                    get: { Double(presets[index].brightness) },
                    set: { presets[index].brightness = Int($0.rounded()); preview() }
                ), in: 0...100, step: 1, onEditingChanged: { editing in
                    if !editing { commit() }
                })
                .accessibilityLabel("\(presets[index].name) brightness")
                .accessibilityValue("\(presets[index].brightness) percent")
                Text("\(presets[index].brightness)%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Picker("Night Shift", selection: Binding(
                    get: { presets[index].nightShift },
                    set: { presets[index].nightShift = $0; commit() }
                )) {
                    ForEach(Preset.NightShift.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(!NightShift.isAvailable)
                Button("Apply") { store.apply(index: index) }
                    .disabled(store.isApplying)
            }
            keyboardRow(index)
        }
        .padding(.vertical, 2)
    }

    /// The keyboard backlight column (spec 2026-09-10 decision 3): Keep, or
    /// an absolute percent. Disabled without a backlit keyboard.
    @ViewBuilder
    private func keyboardRow(_ index: Int) -> some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .help("Keyboard backlight")
            Toggle("Set keyboard backlight", isOn: Binding(
                get: { presets[index].keyboard != nil },
                set: { on in presets[index].keyboard = on ? 0 : nil; commit() }
            ))
            .toggleStyle(.checkbox)
            .accessibilityLabel("\(presets[index].name) sets the keyboard backlight")
            if let keys = presets[index].keyboard {
                // Previews during the drag and commits on the drop, exactly
                // like the brightness slider above it — same defect, same cure.
                Slider(value: Binding(
                    get: { Double(keys) },
                    set: { presets[index].keyboard = Int($0.rounded()); preview() }
                ), in: 0...100, step: 1, onEditingChanged: { editing in
                    if !editing { commit() }
                })
                .accessibilityLabel("\(presets[index].name) keyboard backlight")
                .accessibilityValue("\(keys) percent")
                Text("\(keys)%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Text("kept as it is")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .disabled(!KeyboardBacklight.isAvailable)
    }

    /// Names are the palette keywords, so two presets never share one.
    private func uniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while presets.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Mid-drag: in-memory only, so the monitors track the slider without a
    /// settings write per frame.
    private func preview() {
        store.previewPresets(presets)
    }

    private func commit() {
        store.setPresets(presets)
    }
}
