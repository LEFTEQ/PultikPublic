import SwiftUI

// MARK: - Vitals dock (right rail, welded to the bottom edge)

/// Every machine this operator runs, in one place (decisions D1/D2, 2026-08-27).
///
/// It replaces two surfaces that used to sit across the panel's bottom edge —
/// the full-bleed `FanStrip` and the bottom bar's VPS cell — because they said
/// the same kind of thing in two grammars a screen-width apart. Here the Mac
/// and the estate read as one dock.
///
/// Two tiers, not one table (decision D2=B): this Mac has fans, a die temp and
/// OS thermal pressure; a VPS has cpu, ram and disk. Forcing them into shared
/// columns would have cost the Mac a fan and the thermal state, which are the
/// readings the machine under your hands actually needs.
///
/// The dock lives OUTSIDE the rail's ScrollView and is not collapsible: it is
/// the one thing that must be legible without a prior decision about it.
struct VitalsDock: View {
    let store: StatusStore
    let fanStore: FanStore

    /// Off-mesh the estate tier is empty and only the Mac tier renders — the
    /// rail-hides-when-unreachable law, applied within one card.
    private var showEstate: Bool {
        store.isSectionVisible("servers") && !store.serverMetrics.isEmpty
    }
    private var showMac: Bool {
        store.isSectionVisible("fans") && (fanStore.hottest != nil || !fanStore.fans.isEmpty)
    }

    var body: some View {
        if showMac || showEstate {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 7) {
                    if showMac {
                        MacTier(fanStore: fanStore)
                    }
                    if showMac && showEstate {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    if showEstate {
                        EstateTier(metrics: store.serverMetrics)
                    }
                }
                .padding(10)
            }
            .background(.white.opacity(0.02))
        }
    }
}

// MARK: - Tier 1: this Mac

/// The machine under your hands, in its own grammar: hottest die temp, every
/// fan, cpu, memory, and thermal pressure when the OS is throttling. This is
/// the full `FanStrip` reading set in a quarter of the width — nothing was
/// dropped in the move, which is what made the two-tier shape worth its
/// hairline.
private struct MacTier: View {
    let fanStore: FanStore
    private let brightness = BrightnessStore.shared
    private let awake = AwakeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Kicker(text: "This Mac")
                Spacer(minLength: 0)
                AwakeToggle(awake: awake)
                if brightness.isAvailable {
                    DimToggle(brightness: brightness)
                }
                if fanStore.isSimulated {
                    Text("sim")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("No AppleSMC on this machine — simulated readings")
                }
                if !fanStore.heldRPM.isEmpty {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .help("\(fanStore.heldRPM.count) fan(s) pinned to a constant RPM — .fans to release")
                }
            }
            .padding(.horizontal, 2)

            // ONE line, always. A wrapping dock is not a cosmetic problem:
            // its height feeds the right rail's scroll budget
            // (StatusPanelView.columnBudget), so a second row silently steals
            // a row of rails. Text shrinks to fit rather than wrapping or
            // truncating — on a many-fan Mac the numbers get smaller, never
            // clipped, never a second line.
            HStack(spacing: 9) {
                if let hottest = fanStore.hottest {
                    Vital(symbol: "thermometer.medium",
                          text: String(format: "%.0f°", hottest.celsius),
                          tone: tempTone(hottest.celsius),
                          help: "\(hottest.name) — hottest sensor")
                }
                if fanStore.fans.count <= Self.maxFanCells {
                    ForEach(fanStore.fans) { fan in
                        Vital(symbol: "fanblades", text: "\(fan.currentRPM)",
                              tone: fanTone(fan), help: fanHelp(fan))
                    }
                } else if let fastest = fanStore.fans.max(by: { $0.currentRPM < $1.currentRPM }) {
                    // Shrinking text alone cannot save a row of eight fans —
                    // the icons and spacing keep their intrinsic width, so the
                    // cells at the end would simply be clipped away. One cell
                    // for the fastest fan and the count says more than four
                    // half-visible numbers; the full list is on the tooltip.
                    Vital(symbol: "fanblades",
                          text: "\(fastest.currentRPM)×\(fanStore.fans.count)",
                          tone: fanTone(fastest), help: allFansHelp)
                }
                if let load = fanStore.cpuLoad {
                    Vital(symbol: "cpu", text: "\(Int((load * 100).rounded()))%",
                          tone: percentTone(load * 100), help: "CPU load, all cores")
                }
                if let mem = fanStore.memUsedFraction {
                    // memTone, not percentTone: used-% over-alarms on a healthy
                    // Mac where inactive pages keep "used" high while kernel
                    // pressure is nominal.
                    Vital(symbol: "memorychip", text: "\(Int((mem * 100).rounded()))%",
                          tone: memTone(fanStore, percent: mem * 100), help: memHelp)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 2)
            // The tier, not the temperature cell, carries the OS thermal
            // state: a machine with no readable sensor has no temperature cell
            // to hang it on, and that is exactly a machine whose thermal
            // pressure you would want to know about.
            .help(thermalHelp)
        }
    }

    /// Beyond this the fan cells stop fitting the rail-width line next to the
    /// temperature, cpu and memory cells.
    private static let maxFanCells = 2

    private func fanHelp(_ fan: Fan) -> String {
        let held = fanStore.heldRPM[fan.id].map { " — held at \($0)" } ?? ""
        return "\(fan.name) (\(fan.id)) \(fan.currentRPM) rpm\(held)"
    }

    /// Reuses `fanHelp` per fan: when the cells collapse, the tooltip is the
    /// ONLY place the fan id and any held RPM still show, so it must not say
    /// less than the individual cells did.
    private var allFansHelp: String {
        fanStore.fans.map(fanHelp).joined(separator: " · ")
    }

    private var memHelp: String {
        guard let used = fanStore.memUsedBytes else { return "Memory used" }
        return String(format: "Memory %.1f / %.0f GB", used / 1e9, fanStore.memTotalBytes / 1e9)
    }

    /// The OS thermal state used to have its own cell ("warm"/"hot"). The
    /// numbers already say it and the row must stay one line, so it lives on
    /// the tier's tooltip now (2026-08-29).
    private var thermalHelp: String {
        switch fanStore.thermalState {
        case .fair: "macOS thermal pressure: warm"
        case .serious: "macOS thermal pressure: hot — the OS is throttling"
        case .critical: "macOS thermal pressure: critical — the OS is throttling"
        default: ""
        }
    }
}

// MARK: - Tier 2: the estate

/// One row per box: name, then cpu / ram / disk. Column widths are fixed and
/// sized to the widest value each can hold — "AppServer", "100%",
/// "147/251 GB" — because ragged numeric columns are unreadable at 9.5pt.
private struct EstateTier: View {
    let metrics: [ServerMetrics]

    private enum Column {
        static let name: CGFloat = 60
        static let percent: CGFloat = 26
        static let size: CGFloat = 58
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Kicker(text: "Estate")
                .padding(.horizontal, 2)
                .padding(.bottom, 1)
            ForEach(metrics) { server in
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: Column.name, alignment: .leading)
                    Vital(symbol: "cpu", percent: server.cpu,
                          text: percentText(server.cpu), width: Column.percent)
                    Vital(symbol: "memorychip", percent: server.ram,
                          text: sizeText(used: server.ramUsedBytes, total: server.ramTotalBytes)
                              ?? percentText(server.ram),
                          width: Column.size)
                    Vital(symbol: "internaldrive", percent: server.disk,
                          text: percentText(server.disk), width: Column.percent)
                }
                .padding(.horizontal, 2)
                .help(diskHelp(server))
            }
        }
    }

    private func percentText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func sizeText(used: Double?, total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return formatSize(used: used, total: total)
    }

    /// The disk cell shows a percentage to stay narrow; the absolute figure is
    /// a hover away rather than lost.
    private func diskHelp(_ server: ServerMetrics) -> String {
        guard let used = server.diskUsedBytes, let total = server.diskTotalBytes, total > 0 else {
            return server.name
        }
        return "\(server.name) — disk \(formatSize(used: used, total: total))"
    }
}

// MARK: - Shared vital cell

/// Icon + number, tinted by load. Two initialisers because the two tiers know
/// different things: the Mac tier has already chosen a tone (a fan's tone comes
/// from its own min/max, not a percentage), the estate tier has a percentage
/// and wants the shared tiering applied to it.
private struct Vital: View {
    let symbol: String
    let text: String
    let tone: Color
    var width: CGFloat?
    var help: String?

    init(symbol: String, text: String, tone: Color, help: String? = nil) {
        self.symbol = symbol
        self.text = text
        self.tone = tone
        self.help = help
    }

    init(symbol: String, percent: Double?, text: String, width: CGFloat) {
        self.symbol = symbol
        self.text = text
        self.width = width
        guard let percent else { self.tone = .secondary; return }
        switch LoadTier(percent: percent) {
        case .calm: self.tone = .secondary
        case .warm: self.tone = .orange
        case .hot: self.tone = .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .frame(width: 10)
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: width == nil ? .leading : .trailing)
        }
        .foregroundStyle(tone)
        .help(help ?? "")
    }
}

// MARK: - Display preset cycle

/// Never Sleep (docs/specs/2026-09-10-never-sleep-decisions.md, decisions 4
/// and 6): the cup is the visible "this Mac is being held awake" indicator
/// and, since a glyph is a button at no extra cost, the toggle too. Same
/// `AwakeStore` the `awake` quick command flips.
private struct AwakeToggle: View {
    let awake: AwakeStore

    var body: some View {
        Button {
            awake.toggle()
        } label: {
            Image(systemName: awake.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 9.5))
                .foregroundStyle(awake.isAwake ? Color.orange : Color.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(awake.isAwake ? "Turn Never Sleep off" : "Turn Never Sleep on")
    }

    private var help: String {
        if let since = awake.since {
            return "Never Sleep on since \(since.formatted(date: .omitted, time: .shortened)) — "
                + "the Mac stays running and unlocked (lid close still sleeps); click to allow sleep"
        }
        return "Never Sleep off — click to keep this Mac running and unlocked; also “awake” in the palette"
    }
}

/// The display-presets button (docs/specs/2026-09-06-display-presets-decisions.md).
/// Each click applies the next preset in Settings ▸ Displays order; the glyph
/// names what the click will do next (moon for a dark preset, sun for a
/// bright one) and its tint says whether a preset is currently applied.
/// Same `BrightnessStore` the preset quick commands run.
private struct DimToggle: View {
    let brightness: BrightnessStore

    var body: some View {
        Button {
            brightness.cycle()
        } label: {
            Image(systemName: (brightness.next?.brightness ?? 100) <= 30 ? "moon.fill" : "sun.max")
                .font(.system(size: 9.5))
                .foregroundStyle(brightness.active != nil ? Color.orange : Color.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(brightness.next.map { "Apply display preset \($0.name)" } ?? "Display presets")
    }

    private var help: String {
        guard let next = brightness.next else { return "No display presets — add one in Settings ▸ Displays" }
        let now = brightness.active.map { "Displays at “\($0.name)” — " } ?? ""
        return "\(now)click for “\(next.name)” (\(next.brightness)%) — also “\(next.name.lowercased())” in the palette"
    }
}
