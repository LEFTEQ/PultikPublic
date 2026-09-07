import SwiftUI

/// Fan curves — pick a preset, see its shape, drag it into the shape you want.
///
/// A curve is handed to the privileged helper once and then driven there
/// (protocol v9), so it keeps working with this window shut, the HUD closed,
/// and Pultík quit. That's why this pane can be a picker plus a chart and
/// nothing else: there is no loop here to babysit.
struct FansPane: View {
    let fanStore: FanStore

    /// Which curve the chart is showing. Starts on the running one, falls
    /// back to Balanced when the fans are OS-managed — you should be able to
    /// look at a curve before committing to it.
    @State private var shown: String = FanStore.instance?.activeCurveID ?? FanCurve.balanced.id
    @State private var helperBusy = false
    @State private var helperError: String?

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $shown) {
                    ForEach(FanCurve.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                FanCurveChart(fanStore: fanStore, curveID: shown)
                    .padding(.vertical, 4)

                HStack(spacing: 8) {
                    if fanStore.activeCurveID == shown {
                        Label("Driving the fans", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 11))
                    } else {
                        Button("Use this curve") { fanStore.applyCurve(shown) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!fanStore.canWrite || fanStore.isApplying)
                    }
                    // The first write after macOS has the fans takes seconds —
                    // the helper has to wait out thermalmonitord. Say so.
                    if fanStore.isApplying {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                        Text("Taking the fans from macOS…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Back to macOS control") { fanStore.applyCurve(nil) }
                        .controlSize(.small)
                        .disabled(fanStore.activeCurveID == nil || !fanStore.canWrite
                                  || fanStore.isApplying)
                }
            } header: {
                Text("Fan curve")
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Smoothing", selection: smoothingBinding) {
                    ForEach(TempSmoother.choices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Spike smoothing")
            } footer: {
                Text(smoothingFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Driven by") {
                    Text(sensorText)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Fans") {
                    Text(fansText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Helper") {
                    HStack(spacing: 8) {
                        Text(helperText)
                            .foregroundStyle(helperTone)
                        if !fanStore.canWrite {
                            Button(helperBusy ? "Installing…" : "Install…") {
                                runPrivileged(HelperInstaller.install)
                            }
                            .controlSize(.small)
                            .disabled(helperBusy)
                        }
                    }
                }
                if let helperError {
                    Text(helperError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Hardware")
            } footer: {
                Text("Writes go through pultik-fan-control-helper, a root launchd daemon. Installing it asks for your admin password once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fanStore.startTicking()
            fanStore.refreshHelperHealth()
        }
        .onDisappear { fanStore.stopTicking() }
    }

    private var footerText: String {
        if fanStore.activeCurveID != nil {
            return "Drag a handle to reshape the curve — edits are saved and sent to the helper straight away. Moving the deck slider by hand drops the curve."
        }
        return "Drag a handle to reshape the curve. Nothing reaches the fans until you press Use this curve."
    }

    private var smoothingBinding: Binding<Double> {
        Binding(get: { fanStore.smoothingSeconds },
                set: { fanStore.setSmoothing($0) })
    }

    private var smoothingFooter: String {
        let seconds = Int(fanStore.smoothingSeconds)
        guard seconds > 0 else {
            return "The curve follows every reading. A five-second jump to 80°C spins the fans up for as long as it lasts."
        }
        return "The curve is driven by a \(seconds)-second average instead of the raw reading, so a brief spike — a build finishing, a Spotlight reindex — passes without the fans noticing. Sustained heat still gets air within about \(seconds) seconds, and anything at \(Int(TempSmoother.bypassTempC))°C or above skips the filter entirely."
    }

    private var sensorText: String {
        guard let temp = fanStore.hottestCelsius else { return "Hottest die · CPU or GPU" }
        return String(format: "Hottest die · CPU or GPU — %.0f°C now", temp)
    }

    private var fansText: String {
        guard !fanStore.fans.isEmpty else { return "none detected" }
        return fanStore.fans
            .map { "\($0.name) \($0.minRPM)–\($0.maxRPM)" }
            .joined(separator: " · ")
    }

    private var helperText: String {
        if fanStore.isSimulated { return "simulated — no AppleSMC on this Mac" }
        switch fanStore.helperHealth {
        case .healthy(let version): return "installed · protocol v\(version)"
        case .outdated(let installed, let current):
            return "v\(installed) installed, Pultík speaks v\(current) — reinstall"
        case .down: return "not installed — readings only"
        }
    }

    private var helperTone: Color {
        if fanStore.isSimulated { return .secondary }
        if case .healthy = fanStore.helperHealth { return .secondary }
        return .orange
    }

    /// Blocks on an osascript password prompt, so it runs off the main actor.
    private func runPrivileged(_ work: @escaping @Sendable () throws -> Void) {
        helperBusy = true
        helperError = nil
        Task {
            let failure: Error? = await Task.detached {
                do { try work(); return nil } catch { return error }
            }.value
            helperBusy = false
            fanStore.refreshHelperHealth()
            // A dismissed password prompt is the user saying no, not an error.
            if let failure, case HelperInstallError.cancelled = failure { return }
            helperError = failure.map { ($0 as? HelperInstallError)?.description
                                        ?? $0.localizedDescription }
        }
    }
}
