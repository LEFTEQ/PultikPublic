import Foundation
import Observation

/// This Mac's vitals + fan control, backed by the vendored AppleSMC bridge.
///
/// Reads are unprivileged and tick at 1 Hz only while the panel is open.
/// Writes go through pultik's own pultik-fan-control-helper daemon, which the
/// fan deck installs on demand (see HelperInstaller). The helper owns
/// re-assertion of constant setpoints, but idle-reverts to auto after 60 s of
/// client silence, so a 20 s keep-alive ping runs for as long as any fan is
/// held — panel open or not. Quit releases every hold.
///
/// Temperature CURVES are a different contract (protocol v9, 2026-08-02): the
/// helper reads the die and drives the fans itself, so pultik sends the ramp
/// once and then has no further part in it. Curved fans need no keep-alive
/// (they're watchdog-exempt) and are not released on quit.
@Observable
@MainActor
final class FanStore {
    /// Lazy on purpose, and observable-from-outside on purpose: constructing
    /// the store opens AppleSMC, discovers sensors and safe-resets stale
    /// holds — quit paths must consult `instance` instead of `shared` so a
    /// run that never showed fan UI doesn't open the hardware just to close it.
    static private(set) var instance: FanStore?
    static var shared: FanStore {
        if let instance { return instance }
        let store = FanStore()
        instance = store
        return store
    }

    private(set) var fans: [Fan] = []
    private(set) var sensors: [TempSensor] = []
    /// 0…1 across all cores, nil until the second tick (delta-based).
    private(set) var cpuLoad: Double?
    /// 0…1 of physical memory in use (active + wired + compressed).
    private(set) var memUsedFraction: Double?
    private(set) var memUsedBytes: Double?
    private(set) var memTotalBytes = Double(ProcessInfo.processInfo.physicalMemory)
    /// Kernel memory-pressure level (1 normal · 2 warning · 4 critical) —
    /// D5's "RAM pressure". The used-% is the number; this drives the tone.
    private(set) var memPressureLevel: Int32?
    private(set) var diskFreeBytes: Int64?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var uptime: TimeInterval = 0
    private(set) var helperHealth: HelperClient.Health = .down

    /// Fans pultik has pinned to a constant RPM — drives the keep-alive and
    /// the quit release. The snapshot's Fan.mode is the SMC's view; this is
    /// ours, and survives the panel closing (when ticks stop).
    private(set) var heldRPM: [String: Int] = [:]

    /// The curve preset id currently driving the fans, or nil for OS-managed.
    ///
    /// This is a MIRROR, not the source of truth — the running curve lives in
    /// the helper (protocol v9), which is exactly why it keeps working after
    /// pultik quits. Persisted only so a relaunch shows the right chip lit.
    private(set) var activeCurveID: String?

    /// The edited-or-default shape for each preset. Mirrors
    /// `Preferences.fanCurves`; the chart edits this and saves through.
    private(set) var curves: [String: FanCurve] = [:]

    /// Seconds of low-pass on the temperature the curve is driven by, so a
    /// five-second spike doesn't spin the fans up. Sent to the helper with the
    /// curve — the filter runs there, next to the readings.
    private(set) var smoothingSeconds: Double = TempSmoother.defaultSeconds

    /// True while a privileged write is in flight — drives the "Applying…"
    /// affordances. Never a modal block: the fans are the slow part, the UI
    /// isn't allowed to be.
    private(set) var isApplying = false

    /// Bumped by every control intent (pin, auto, curve). Completions capture
    /// it at enqueue and check it before touching state: writes land on a
    /// serial queue, so an old apply's completion — especially its partial-
    /// failure ROLLBACK — can arrive after a newer intent is already queued,
    /// and must not undo it.
    private var controlGeneration = 0

    /// EVERY AppleSMC read and EVERY privileged write happens on this queue,
    /// never on the main thread.
    ///
    /// The helper's unlock dance is genuinely slow: `unlockFanControl` sleeps
    /// a flat 3 s waiting for thermalmonitord to hand over `Ftst`, then retries
    /// for up to 30 s more — and the caller blocks on the socket for all of it.
    /// Two fans of that is the ten-second beachball "Use this curve" used to
    /// cause. The dance only runs cold (first write after the OS holds the
    /// lock), which is why the second click always felt fine.
    ///
    /// Serial, not concurrent: the 1 Hz refresh must never read the service's
    /// cache while a write is mutating it.
    private nonisolated let smcQueue = DispatchQueue(label: "dev.example.pultik.smc")
    private nonisolated(unsafe) let smc: SMCService
    private nonisolated let helper = HelperClient()
    var isSimulated: Bool { smc.isSimulated }

    private var tickTimer: Timer?
    private var keepAliveTimer: Timer?
    private var tickCount = 0
    /// How many views want live readings right now. The panel and the Settings
    /// window can be open at once, and the panel closing must not freeze the
    /// curve chart — so start/stop are balanced, not a plain on/off.
    private var tickHolders = 0

    private init() {
        // forceSafeReset: false — the constructor's blanket sweep routed
        // .auto through the helper, whose setAuto DROPS a stored curve:
        // reopening pultik killed the ramp deliberately left running on
        // quit (D2). Crash safety is NOT lost: `crashSafeSweep()` below
        // re-does the sweep curve-aware, sparing helper-owned fans.
        smc = AppleSMCService(forceSafeReset: false) ?? MockSMCService()
        let prefs = Preferences.load()
        activeCurveID = prefs.activeFanCurve
        smoothingSeconds = prefs.fanCurveSmoothing
        curves = Dictionary(uniqueKeysWithValues:
            FanCurve.presets.map { ($0.id, prefs.fanCurve($0.id) ?? $0) })
        crashSafeSweep()
    }

    /// The crash safety `forceSafeReset` used to provide, made curve-aware.
    ///
    /// A fan the SMC reports forced that the helper does NOT account for is
    /// an orphan: a helper killed without its SIGTERM cleanup respawns with
    /// empty state and re-asserts nothing, so that pin would stand forever —
    /// reset it. Helper-owned fans are spared: fixed holds are covered by
    /// the helper's idle watchdog, curves are deliberately long-lived (D2).
    ///
    /// Ownership is three-valued on purpose: a live pre-v11 helper answers
    /// pings but cannot report the curves it may be holding, so `unknown`
    /// SKIPS the sweep (sweeping blind is how a curve dies) — the outdated
    /// badge drives the reinstall that unblocks it. Only `down` (nobody home
    /// to own anything) falls back to the old reset-everything-forced.
    private func crashSafeSweep() {
        guard !isSimulated else { return }
        let generation = controlGeneration
        let smc = smc, helper = helper
        smcQueue.async { [weak self] in
            smc.refresh()
            let fans = smc.snapshot().fans
            let forced = fans.filter { fan in
                if case .auto = fan.mode { return false } else { return true }
            }.map(\.id)
            let orphans: [String]
            var curveRunning: Bool?
            switch helper.fanOwnership() {
            case .owned(let curved, let held):
                curveRunning = !curved.isEmpty
                orphans = forced.filter { !curved.contains($0) && !held.contains($0) }
            case .unknown:
                NSLog("pultik: crashSafeSweep — helper predates ownership reporting; skipping (reinstall to re-enable)")
                orphans = []
            case .down:
                curveRunning = false   // nobody home — nothing is driving a curve
                orphans = forced
            }
            for id in orphans {
                NSLog("pultik: crashSafeSweep — %@ forced with no helper owner, resetting to AUTO", id)
                _ = smc.setMode(.auto, for: id)
            }
            // The chip is a MIRROR of helper state — a reinstalled/restarted
            // helper holds no curve, so a persisted activeCurveID would lie.
            // Reconciled only when the helper answered definitively, and only
            // if no newer control intent has raced this startup pass.
            if curveRunning == false {
                Task { @MainActor in
                    guard let self, generation == self.controlGeneration else { return }
                    if self.activeCurveID != nil {
                        NSLog("pultik: crashSafeSweep — helper holds no curve, clearing the persisted chip")
                        self.setActiveCurveID(nil)
                    }
                }
            }
        }
    }

    // MARK: - Ticking (panel open only)

    /// Every caller must pair this with exactly one `stopTicking()`.
    func startTicking() {
        tickHolders += 1
        guard tickTimer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in FanStore.shared.tick() }
        }
        // .common so the readout keeps moving while a slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        tickHolders = max(0, tickHolders - 1)
        guard tickHolders == 0 else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        cpuPrev = nil
        cpuLoad = nil
    }

    private func tick() {
        // Host stats are mach calls — microseconds, safe to keep on main.
        sampleCPU()
        sampleMemory()
        uptime = ProcessInfo.processInfo.systemUptime
        thermalState = ProcessInfo.processInfo.thermalState
        // Slow movers — every 30 s is plenty.
        let slow = tickCount % 30 == 0
        if slow {
            sampleDisk()
            sampleMemoryPressure()
        }
        tickCount += 1

        // The SMC snapshot and the health probe both go to the queue: reads
        // are ioctl round-trips and health() opens a socket with 5 s timeouts.
        // A hung helper must cost a stale badge, never a beachball. Landing
        // them together also means the readout can't show fans from one tick
        // and sensors from another.
        //
        // At most ONE snapshot job waits in the queue at a time: a cold
        // privileged write can hold the serial queue for tens of seconds,
        // and without this gate every 1 Hz tick would stack another stale
        // refresh behind it — a burst of identical work when it clears.
        guard !snapshotQueued else { return }
        snapshotQueued = true
        let smc = smc, helper = helper
        smcQueue.async { [weak self] in
            smc.refresh()
            let snap = smc.snapshot()
            let health = slow ? helper.health() : nil
            Task { @MainActor in
                guard let self else { return }
                self.snapshotQueued = false
                self.fans = snap.fans
                self.sensors = snap.sensors
                if let health { self.helperHealth = health }
            }
        }
    }

    /// True while a tick's snapshot job is queued or running — the coalescing
    /// gate above. MainActor-only, so no lock.
    private var snapshotQueued = false

    /// Hottest CPU/GPU reading — the strip's headline number.
    var hottest: TempSensor? {
        sensors
            .filter { $0.kind == .cpu || $0.kind == .gpu }
            .max(by: { $0.celsius < $1.celsius })
    }

    /// Re-poll the helper now instead of waiting for the 30 s tick — used
    /// right after an install/remove, where the badge must not lie.
    /// On `smcQueue` like every other helper touch — a detached task would
    /// race the serial refresh/write traffic this store promises to order.
    func refreshHelperHealth() {
        let helper = helper
        smcQueue.async { [weak self] in
            let health = helper.health()
            Task { @MainActor in self?.helperHealth = health }
        }
    }

    var canWrite: Bool {
        if isSimulated { return true }
        if case .healthy = helperHealth { return true }
        return false
    }

    // MARK: - Control (writes via the shared helper)

    /// Pin every fan to the same fraction of its own min…max range — the deck's
    /// single slider. Fans can carry different ranges, so percent (not RPM) is
    /// the shared unit; each fan gets the RPM that fraction maps to on its scale.
    ///
    /// Dragging the slider is an explicit "this speed, now", so it DROPS any
    /// running curve (decision D11) — one control is authoritative at a time.
    func setAllConstant(fraction: Double) {
        setActiveCurveID(nil)
        controlGeneration += 1
        let generation = controlGeneration
        let f = max(0, min(1, fraction))
        let targets = fans.map { fan in
            (id: fan.id, rpm: fan.minRPM + Int((Double(fan.maxRPM - fan.minRPM) * f).rounded()))
        }
        // Registered BEFORE the async write: a quit while the pin is still
        // in flight must release these fans too — releaseAllOnQuit's sync
        // hop lands after this write on the serial queue, so the release
        // follows the pin instead of missing it.
        for id in targets.map(\.id) { inFlightPins[id, default: 0] += 1 }
        offMain { smc, _ in
            // Only the writes that actually landed become holds — a fan whose
            // write was rejected must not be treated as ours to release.
            targets.filter { smc.setMode(.constant(rpm: $0.rpm), for: $0.id) }
        } then: { landed in
            for id in targets.map(\.id) {
                if let count = self.inFlightPins[id] {
                    if count <= 1 { self.inFlightPins.removeValue(forKey: id) }
                    else { self.inFlightPins[id] = count - 1 }
                }
            }
            // Recorded REGARDLESS of staleness: these fans were pinned by
            // this write, and completions run in enqueue order, so a newer
            // intent's completion adjusts the books after ours. Skipping the
            // record when stale is how a landed pin whose superseding
            // release then failed escaped the quit sweep entirely.
            for target in landed { self.heldRPM[target.id] = target.rpm }
            self.syncKeepAlive()
        }
    }

    /// Pins whose privileged write is queued but not yet confirmed, COUNTED
    /// per fan — two rapid slider drags overlap on the same IDs, and the
    /// first (stale) completion must only retire its own registration, not
    /// the second write's still-queued one. Part of the quit release
    /// alongside `heldRPM`.
    private var inFlightPins: [String: Int] = [:]

    /// Where the single slider sits: what the curve is asking for when one is
    /// running, else the held setpoint when pultik is holding, else the fans'
    /// live speed — all as a fraction of range. Averaged; the fans are driven
    /// together, so they only diverge mid-spin-up.
    var speedFraction: Double {
        if let target = curveTargetFraction { return target }
        guard !fans.isEmpty else { return 0 }
        let sum = fans.reduce(0.0) { acc, fan in
            guard fan.maxRPM > fan.minRPM else { return acc }
            let rpm = Double(heldRPM[fan.id] ?? fan.currentRPM)
            let f = (rpm - Double(fan.minRPM)) / Double(fan.maxRPM - fan.minRPM)
            return acc + max(0, min(1, f))
        }
        return sum / Double(fans.count)
    }

    func setAllAuto() {
        controlGeneration += 1
        let generation = controlGeneration
        let ids = Set(fans.map(\.id)).union(heldRPM.keys)
        offMain { smc, _ in
            ids.filter { smc.setMode(.auto, for: $0) }
        } then: { released in
            // Only forget holds whose release actually landed — a fan whose
            // write failed stays "held", so the keep-alive and the quit release
            // keep covering it instead of stranding it pinned. Bookkeeping is
            // unconditional (reality; later completions adjust) — only the
            // chip write below is generation-guarded.
            for id in released { self.heldRPM.removeValue(forKey: id) }
            self.syncKeepAlive()
            guard generation == self.controlGeneration else { return }
            // The chip clears only when EVERY release landed: a rejected
            // .setAuto means the helper restored its hold/curve and is still
            // driving that fan — reporting OS-managed there would be a lie,
            // and quit would then skip a release the helper still expects.
            if released.count == ids.count { self.setActiveCurveID(nil) }
        }
    }

    func fullBlast() {
        setAllConstant(fraction: 1)
    }

    // MARK: - Curves (helper-owned, protocol v9)

    /// Hand every fan to `curveID`'s ramp. Sent once — from here the helper
    /// reads the die temperature and drives the fans itself, panel open or
    /// closed, pultik running or not.
    ///
    /// Passing nil releases to OS control, which is the Auto chip.
    func applyCurve(_ curveID: String?) {
        guard let curveID else {
            setAllAuto()
            return
        }
        guard let curve = curves[curveID] ?? FanCurve.preset(curveID) else { return }
        // Simulated Macs have no socket and no hardware; still light the chip
        // so the settings pane and the chart are explorable off a real SMC.
        guard !isSimulated else {
            setActiveCurveID(curveID)
            return
        }
        // Light the chip now, not when the fans answer. The curve is what the
        // user chose; if a write is rejected the `then` block takes it back.
        setActiveCurveID(curveID)
        controlGeneration += 1
        let generation = controlGeneration
        let points = curve.guarded().points
        let ids = fans.map(\.id)
        let tau = smoothingSeconds
        offMain { _, helper in
            ids.filter { helper.setCurve(fanID: $0,
                                         sensorId: FanCurve.defaultSensorID,
                                         points: points,
                                         smoothingSeconds: tau) }
        } then: { landed in
            // Bookkeeping reflects reality regardless of staleness — landed
            // fans are helper-curve-owned right now, and a newer intent's
            // completion runs after ours and adjusts again.
            for id in landed { self.heldRPM.removeValue(forKey: id) }
            self.syncKeepAlive()
            // The rollback and chip writes below belong to the newest intent
            // only — a stale apply must not undo what a later one queued.
            guard generation == self.controlGeneration else { return }
            // One curve is a machine-wide promise: the chip and the persisted
            // activeCurveID describe ALL fans, so a partial landing is a
            // failure, not a lesser success. Roll the landed ones back to
            // AUTO and clear the chip rather than display a curve that only
            // half the machine is running.
            guard landed.count == ids.count else {
                self.setActiveCurveID(nil)
                if !landed.isEmpty {
                    self.offMain { smc, _ in
                        landed.filter { smc.setMode(.auto, for: $0) }
                    } then: { released in
                        guard generation == self.controlGeneration else { return }
                        for id in released { self.heldRPM.removeValue(forKey: id) }
                        self.syncKeepAlive()
                    }
                }
                return
            }
            // Full landing: nothing left to do — the unconditional
            // bookkeeping above already dropped the landed fans out of
            // heldRPM (a curved fan is the helper's to re-assert, not ours —
            // decision D2).
        }
    }

    /// Replace a preset's shape — the chart's drag handler. Guarded on the
    /// way in, saved immediately, and re-sent if this curve is the live one.
    func updateCurve(_ curve: FanCurve) {
        let guarded = curve.guarded()
        curves[guarded.id] = guarded
        var prefs = Preferences.load()
        prefs.fanCurves[guarded.id] = guarded.points
        prefs.save()
        if activeCurveID == guarded.id { applyCurve(guarded.id) }
    }

    /// Throw away the user's edits to `curveID` and go back to the shipped
    /// shape. The only way back — presets are edited in place (D6).
    func restoreCurveDefault(_ curveID: String) {
        guard let preset = FanCurve.preset(curveID) else { return }
        curves[curveID] = preset
        var prefs = Preferences.load()
        prefs.fanCurves.removeValue(forKey: curveID)
        prefs.save()
        if activeCurveID == curveID { applyCurve(curveID) }
    }

    /// Change how heavily the driving temperature is filtered. Re-sends the
    /// live curve so the new time constant takes effect at once rather than at
    /// the next time the user happens to pick a preset.
    func setSmoothing(_ seconds: Double) {
        guard smoothingSeconds != seconds else { return }
        smoothingSeconds = seconds
        var prefs = Preferences.load()
        prefs.fanCurveSmoothing = seconds
        prefs.save()
        if let activeCurveID { applyCurve(activeCurveID) }
    }

    /// True when `curveID` carries user edits — drives the Restore button.
    func curveIsEdited(_ curveID: String) -> Bool {
        Preferences.load().fanCurves[curveID] != nil
    }

    /// Where the active curve is asking the fans to sit right now, 0…1 —
    /// the live dot on the chart and the deck slider's position under a curve.
    var curveTargetFraction: Double? {
        guard let activeCurveID, let curve = curves[activeCurveID],
              let temp = hottestCelsius else { return nil }
        return curve.pct(at: temp)
    }

    /// The temperature curves are driven by (decision D3) — the `__hottest`
    /// virtual sensor, falling back to the hottest real CPU/GPU reading when
    /// the aggregate hasn't been computed yet.
    var hottestCelsius: Double? {
        sensors.first { $0.id == FanCurve.defaultSensorID }?.celsius
            ?? hottest?.celsius
    }

    private func setActiveCurveID(_ id: String?) {
        guard activeCurveID != id else { return }
        activeCurveID = id
        var prefs = Preferences.load()
        prefs.activeFanCurve = id
        prefs.save()
    }

    /// Called from app termination — a machine whose fans stay pinned because
    /// the controller quit is the one failure mode this feature must not have.
    /// (The helper's own SIGTERM/idle watchdog is the backstop, not the plan.)
    ///
    /// An active CURVE is deliberately left running (decision D2): it is the
    /// helper's, it reads the die every second, and stopping it on quit would
    /// undo the whole reason the loop moved into the daemon. Curved fans are
    /// not in `heldRPM`, so this loop already skips them — that is load-bearing.
    func releaseAllOnQuit() {
        // Union with the in-flight pins: a pin whose write is still queued
        // is a hold the moment it lands — quitting between the click and
        // the completion must not strand it.
        let ids = Array(Set(heldRPM.keys).union(inFlightPins.keys))
        guard !ids.isEmpty else { return }
        heldRPM.removeAll()
        inFlightPins.removeAll()
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        // The ONE place that stays synchronous: this runs from
        // applicationWillTerminate, and the process must not exit before the
        // releases land. `sync` on the serial queue also means it waits behind
        // any write already in flight, which is exactly right.
        let smc = smc
        smcQueue.sync {
            for id in ids { _ = smc.setMode(.auto, for: id) }
        }
    }

    /// The helper reverts every hold after 60 s without a client request; a
    /// 20 s ping keeps the hold alive while the panel is closed.
    private func syncKeepAlive() {
        if heldRPM.isEmpty {
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
        } else if keepAliveTimer == nil {
            let helper = helper, queue = smcQueue
            let timer = Timer(timeInterval: 20, repeats: true) { _ in
                // A socket call with 5 s timeouts — off the main thread, same
                // as everything else that touches the helper.
                queue.async { _ = helper.ping() }
            }
            RunLoop.main.add(timer, forMode: .common)
            keepAliveTimer = timer
        }
    }

    /// Run SMC / helper work on `smcQueue` and land the result back on the
    /// main actor. `isApplying` is raised for the duration so the UI can say
    /// "working" instead of just stopping.
    private func offMain<T: Sendable>(
        _ work: @escaping @Sendable (SMCService, HelperClient) -> T,
        then apply: @escaping @MainActor (T) -> Void
    ) {
        isApplying = true
        let smc = smc, helper = helper
        smcQueue.async { [weak self] in
            let result = work(smc, helper)
            Task { @MainActor in
                guard let self else { return }
                self.isApplying = false
                apply(result)
            }
        }
    }

    // MARK: - Host stats

    private var cpuPrev: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    private func sampleCPU() {
        var cpuCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            user += UInt64(info[base + Int(CPU_STATE_USER)])
            system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        // Per-core tick counters are UInt32 on the wire and wrap; a wrap shows
        // as a negative delta — skip that sample rather than clamp it.
        if let prev = cpuPrev,
           user >= prev.user, system >= prev.system,
           idle >= prev.idle, nice >= prev.nice {
            let busy = (user - prev.user) + (system - prev.system) + (nice - prev.nice)
            let total = busy + (idle - prev.idle)
            if total > 0 { cpuLoad = Double(busy) / Double(total) }
        }
        cpuPrev = (user, system, idle, nice)
    }

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let pageSize = Double(vm_kernel_page_size)
        // Matches Activity Monitor's "memory used": app + wired + compressed.
        let used = (Double(stats.internal_page_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * pageSize
        memUsedBytes = used
        memUsedFraction = memTotalBytes > 0 ? used / memTotalBytes : nil
    }

    private func sampleMemoryPressure() {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            memPressureLevel = level
        }
    }

    private func sampleDisk() {
        let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        diskFreeBytes = values?.volumeAvailableCapacityForImportantUsage
    }
}
