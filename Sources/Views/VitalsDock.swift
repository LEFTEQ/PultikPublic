import SwiftUI

// MARK: - This Mac (overview column; the vitals dock until 2026-09-27)

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
///
/// Since 2026-09-23 (spec D2/D11) the estate tier lives in the overview
/// column's Estate widget; the dock is this Mac alone. Since 2026-09-27 it
/// is no dock at all: the This Mac widget closes the overview column, in the
/// gauge grammar of the Devbox widget above it — the same kind of reading
/// about the machine under your hands.
struct MacWidget: View {
    let store: StatusStore
    let fanStore: FanStore
    var onHealth: () -> Void = {}
    var health: MacHealthStore = .shared

    /// Host stats need no SMC, so the system row always has something to
    /// say; only the sensors row waits for a sensor or a fan.
    static func isShown(store: StatusStore, fanStore _: FanStore) -> Bool {
        store.isSectionVisible("fans")
    }

    var body: some View {
        if Self.isShown(store: store, fanStore: fanStore) {
            GlanceGrid.tile {
                MacTier(fanStore: fanStore, onHealth: onHealth, health: health)
            }
        }
    }
}

// MARK: - Tier 1: this Mac

/// The machine under your hands, in the Estate widget's row grammar: a
/// `MachineVitals` row (cpu · memory · disk) like every server's, then a
/// sensors row — hottest die temp and the fans — in the same columns, and
/// thermal pressure when the OS is throttling on the tooltip. The full
/// `FanStrip` reading set; nothing was dropped in any move.
private struct MacTier: View {
    let fanStore: FanStore
    let onHealth: () -> Void
    let health: MacHealthStore
    private let brightness = BrightnessStore.shared
    private let awake = AwakeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // toolkit's report makes the heading the Mac health page's
                // door, like every other widget's; the count is what it
                // flags, tinted by the worst. No report → a plain heading.
                if case .hidden = health.status {
                    Kicker(text: "This Mac")
                } else {
                    let report = health.status.fresh
                    Kicker(text: "This Mac", count: report?.headline.flagged ?? 0,
                           tone: report.flatMap { $0.headline.flagged > 0 ? MacHealthTone.color($0.headline.severity) : nil }
                               ?? .secondary,
                           action: onHealth,
                           actionHelp: health.status.chip?.help ?? "Open Mac health — .mac")
                }
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
            .padding(.horizontal, RailRowMetrics.inset)
            .padding(.bottom, 2)

            GlanceHeads(titles: ["cpu", "memory", "disk"])
            let disk = diskUsage
            // memTone, not percentTone: used-% over-alarms on a healthy Mac
            // where inactive pages keep "used" high while kernel pressure is
            // nominal.
            MachineVitals(name: "system", cpuCount: ProcessInfo.processInfo.activeProcessorCount,
                          cpuPercent: fanStore.cpuLoad.map { $0 * 100 },
                          memoryUsed: fanStore.memUsedBytes, memoryTotal: fanStore.memTotalBytes,
                          diskUsed: disk?.used, diskTotal: disk?.total,
                          memoryTone: fanStore.memUsedFraction.map { memTone(fanStore, percent: $0 * 100) })

            if hasSensors || !thermalHelp.isEmpty {
                sensors
                    // The row, not the temperature cell, carries the OS thermal
                    // state: a machine with no readable sensor has no temperature
                    // cell to hang it on, and that is exactly a machine whose
                    // thermal pressure you would want to know about.
                    .help(thermalHelp)
            }
        }
    }

    private var hasSensors: Bool {
        fanStore.hottest != nil || !fanStore.fans.isEmpty
    }

    /// Temp under cpu, fans under memory and disk — the grid's tracks, so the
    /// two rows read as one table (D5).
    private var sensors: some View {
        var cells: [GlanceCell] = []
        if let hottest = fanStore.hottest {
            cells.append(GlanceCell(String(format: "%.0f°", hottest.celsius),
                                    tone: Self.loud(tempTone(hottest.celsius)),
                                    help: "\(hottest.name) — hottest sensor"))
        }
        if fanStore.fans.count <= Self.maxFanCells {
            for fan in fanStore.fans {
                cells.append(GlanceCell("\(fan.currentRPM) rpm", tone: Self.loud(fanTone(fan)), help: fanHelp(fan)))
            }
        } else if let fastest = fanStore.fans.max(by: { $0.currentRPM < $1.currentRPM }) {
            // One cell for the fastest fan and the count says more than
            // half-visible numbers; the full list is on the tooltip.
            cells.append(GlanceCell("\(fastest.currentRPM)×\(fanStore.fans.count)",
                                    tone: Self.loud(fanTone(fastest)), help: allFansHelp))
        }
        if !hasSensors {
            // No SMC reading to carry it: the OS thermal state in words.
            cells.append(GlanceCell(fanStore.thermalState == .fair ? "warm" : "throttling", tone: .orange))
        }
        return GlanceRow(name: "sensors", cells: cells)
    }

    /// A calm reading is plain text on the grid; only warm and hot colour it.
    private static func loud(_ tone: Color) -> Color? {
        tone == .secondary ? nil : tone
    }

    /// The startup volume as `FanStore` last sampled it — never read here,
    /// the body re-evaluates on every fan tick.
    private var diskUsage: (used: Double, total: Double)? {
        guard let total = fanStore.diskTotalBytes, total > 0, let free = fanStore.diskFreeBytes else { return nil }
        return (Double(total - free), Double(total))
    }

    /// The sensors row has two cells for fans — the memory and disk columns.
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
