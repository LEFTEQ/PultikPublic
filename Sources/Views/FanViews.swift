import SwiftUI

/// Shared tone scales — temps against die limits, percents via LoadTier.
/// Internal, not file-private: the vitals dock's Mac tier reads the same scale,
/// and two copies would drift the day a threshold moves.
func tempTone(_ celsius: Double) -> Color {
    switch celsius {
    case ..<70: .secondary
    case ..<90: .orange
    default: .red
    }
}

func percentTone(_ percent: Double) -> Color {
    switch LoadTier(percent: percent) {
    case .calm: .secondary
    case .warm: .orange
    case .hot: .red
    }
}

/// Memory colors by the kernel's pressure level (1 normal · 2 warning ·
/// 4 critical) — used-% alone over-alarms on a healthy Mac, where inactive
/// pages keep "used" high while pressure is nominal. Percent is the fallback
/// when the sysctl is unavailable.
@MainActor
func memTone(_ fanStore: FanStore, percent: Double) -> Color {
    switch fanStore.memPressureLevel {
    case .some(4): .red
    case .some(2): .orange
    case .some: .secondary
    case nil: percentTone(percent)
    }
}

func fanTone(_ fan: Fan) -> Color {
    switch fan.loadFraction {
    case ..<0.4: .secondary
    case ..<0.75: .orange
    default: .red
    }
}

// MARK: - .fans mode — the fan deck

/// Control + the full readout: presets, one slider driving every fan,
/// every temp sensor, and this Mac's vitals. The palette query filters
/// the sensor list.
struct FanDeckView: View {
    let fanStore: FanStore
    let filter: String
    let onBack: () -> Void

    @State private var helperBusy = false
    @State private var helperError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header
                if !fanStore.canWrite {
                    helperHint
                }
                if let helperError {
                    Text(helperError)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
                presets
                if !fanStore.fans.isEmpty {
                    FanSpeedRow(fanStore: fanStore)
                }
                Kicker(text: "Sensors", count: filteredSensors.count)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                sensorGrid
                Kicker(text: "This Mac")
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                macStats
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .onAppear { fanStore.startTicking() }
        .onDisappear { fanStore.stopTicking() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Fan deck")
                .font(.system(size: 14, weight: .semibold))
            Text(fanStore.isSimulated ? "simulated" : backendBlurb)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var backendBlurb: String {
        switch fanStore.helperHealth {
        case .healthy: "AppleSMC · helper ok"
        case .outdated: "AppleSMC · helper outdated"
        case .down: "AppleSMC · read-only"
        }
    }

    private var helperHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(helperBusy ? "Installing…" : "Install helper") { runHelperInstall() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(helperBusy)
                .help("Asks for your admin password, then installs pultik-fan-control-helper as a launchd daemon")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var hintText: String {
        switch fanStore.helperHealth {
        case .outdated(let installed, let current):
            "The installed fan helper is v\(installed), pultik speaks v\(current) — reinstall to control fans. Readings work either way."
        default:
            "Fan writes need pultik's helper daemon — install it once. Readings work without it."
        }
    }

    /// Both privileged calls block on an osascript password prompt, so they
    /// run off the main actor; only the resulting state lands back on it.
    private func runHelperInstall() { runPrivileged(HelperInstaller.install) }
    private func runHelperRemove() { runPrivileged(HelperInstaller.uninstall) }

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

    /// Curve chips + the two blunt instruments. The chips hand the fans to a
    /// temperature ramp the helper drives on its own; "Full blast" is a plain
    /// pin, and picking it drops whatever curve was running (decision D11).
    private var presets: some View {
        HStack(spacing: 6) {
            curveChip(id: nil, label: "Auto",
                      help: "Release every fan back to macOS control")
            ForEach(FanCurve.presets) { preset in
                curveChip(id: preset.id, label: preset.name,
                          help: "\(preset.name) curve — the helper drives the fans from the hottest die, HUD open or not")
            }
            Button("Full blast") { fanStore.fullBlast() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!fanStore.canWrite || fanStore.fans.isEmpty)
                .help("Pin every fan at its maximum RPM")
            Spacer()
            if case .healthy = fanStore.helperHealth {
                Button("Remove helper") { runHelperRemove() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(helperBusy)
                    .help("Boots out and deletes the privileged daemon. It releases every held fan on the way down.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func curveChip(id: String?, label: String, help: String) -> some View {
        let active = fanStore.activeCurveID == id
        return Button {
            fanStore.applyCurve(id)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((active ? Color.accentColor : Color.secondary).opacity(active ? 0.22 : 0.12),
                            in: Capsule())
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!fanStore.canWrite || fanStore.fans.isEmpty || fanStore.isApplying)
        .opacity(fanStore.isApplying && !active ? 0.5 : 1)
        .help(help)
    }

    private var filteredSensors: [TempSensor] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return fanStore.sensors }
        return fanStore.sensors.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    private var sensorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(filteredSensors) { sensor in
                HStack(spacing: 4) {
                    Image(systemName: sensor.kind.sfSymbol)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 11)
                    Text(sensor.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(String(format: "%.1f°", sensor.celsius))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(tempTone(sensor.celsius))
                }
                .help("\(sensor.id) — \(sensor.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var macStats: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let load = fanStore.cpuLoad {
                statRow(symbol: "cpu", label: "CPU load",
                        value: "\(Int((load * 100).rounded()))%",
                        tone: percentTone(load * 100))
            }
            if let mem = fanStore.memUsedFraction, let used = fanStore.memUsedBytes {
                statRow(symbol: "memorychip", label: "Memory",
                        value: String(format: "%.1f / %.0f GB · %d%%",
                                      used / 1e9, fanStore.memTotalBytes / 1e9,
                                      Int((mem * 100).rounded())),
                        tone: memTone(fanStore, percent: mem * 100))
            }
            if let free = fanStore.diskFreeBytes {
                statRow(symbol: "internaldrive", label: "Disk free",
                        value: String(format: "%.0f GB", Double(free) / 1e9),
                        tone: .secondary)
            }
            statRow(symbol: "clock", label: "Uptime", value: uptimeText, tone: .secondary)
            statRow(symbol: "flame", label: "Thermal pressure", value: thermalText,
                    tone: fanStore.thermalState == .nominal ? .secondary : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func statRow(symbol: String, label: String, value: String, tone: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tone)
        }
    }

    private var uptimeText: String {
        let total = Int(fanStore.uptime)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var thermalText: String {
        switch fanStore.thermalState {
        case .nominal: "nominal"
        case .fair: "fair — mild throttle"
        case .serious: "serious — throttling"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Fan speed row

/// One slider for every fan. Fans are driven as a pair — nobody wants the left
/// one at 3000 and the right at 5000 — so the control is a single percentage of
/// each fan's own min…max range, with the live per-fan RPM read out beneath it.
/// The drag writes once on release (the helper holds and re-asserts it); the
/// chip releases every fan back to auto.
private struct FanSpeedRow: View {
    let fanStore: FanStore

    @State private var dragFraction: Double?

    private var held: Bool { !fanStore.heldRPM.isEmpty }
    /// The chip has three states, not two: OS-managed, pinned by us, or handed
    /// to a curve the helper is driving. A curve is not a pin — the number
    /// under it moves on its own.
    private var curveName: String? {
        guard let id = fanStore.activeCurveID else { return nil }
        return (FanCurve.preset(id)?.name ?? id).lowercased()
    }
    private var fraction: Double { dragFraction ?? fanStore.speedFraction }

    private var chipLabel: String { curveName ?? (held ? "held" : "auto") }
    private var chipTone: Color {
        if curveName != nil { return .accentColor }
        return held ? .orange : .secondary
    }
    private var chipHelp: String {
        if let curveName {
            return "Following the \(curveName) curve — click to release every fan to macOS control"
        }
        return held ? "Pinned — click to release every fan to auto" : "OS-managed"
    }

    private var tone: Color {
        switch fraction {
        case ..<0.4: .secondary
        case ..<0.75: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "fanblades")
                    .font(.system(size: 10))
                    .foregroundStyle(tone)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fan speed")
                        .font(.system(size: 11, weight: .medium))
                    Text("all \(fanStore.fans.count) fans")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 92, alignment: .leading)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tone)
                    .frame(width: 40, alignment: .trailing)
                Slider(
                    value: Binding(get: { fraction }, set: { dragFraction = $0 }),
                    in: 0...1,
                    onEditingChanged: { editing in
                        guard !editing, let f = dragFraction else { return }
                        fanStore.setAllConstant(fraction: f)
                        dragFraction = nil
                    }
                )
                .controlSize(.mini)
                .disabled(!fanStore.canWrite)
                .accessibilityLabel("Fan speed, all fans")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                Button {
                    fanStore.setAllAuto()
                } label: {
                    Text(chipLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(chipTone.opacity(0.15), in: Capsule())
                        .foregroundStyle(chipTone)
                }
                .buttonStyle(.plain)
                .disabled((!held && curveName == nil) || !fanStore.canWrite)
                .help(chipHelp)
            }
            HStack(spacing: 10) {
                ForEach(fanStore.fans) { fan in
                    HStack(spacing: 3) {
                        Text(fan.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text("\(fan.currentRPM)")
                            .font(.system(size: 9, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(fanTone(fan))
                        if let target = fanStore.heldRPM[fan.id] {
                            Text("→\(target)")
                                .font(.system(size: 9, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                    .help("\(fan.name) (\(fan.id)) — \(fan.minRPM)–\(fan.maxRPM) rpm")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
