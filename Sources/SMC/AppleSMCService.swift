// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/SMC/AppleSMCService.swift) — do not hand-drift; re-vendor on upstream change.
//
//  AppleSMCService.swift
//  GenesisFanControlCore
//
//  Real System Management Controller backend via IOKit. Talks to the
//  AppleSMC IOService using the standard 80-byte SMCParamStruct.
//
//  - Reads are unprivileged.
//  - Writes (mode/target RPM) require root on most Macs; we attempt them
//    anyway and log the SMC `result` byte on failure so the caller can
//    surface "needs sudo / privileged helper" in the UI.
//

import Foundation
import IOKit

// MARK: - Wire-level SMC types

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Explicit trailing pad — the C struct is 12 bytes; Swift would
    // otherwise pack it down to 9 and the kernel rejects the call.
    var _pad0: UInt8 = 0
    var _pad1: UInt8 = 0
    var _pad2: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: SMCVersion = .init()
    var pLimitData: SMCPLimitData = .init()
    var keyInfo: SMCKeyInfoData = .init()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                              0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMCCall: UInt8 {
    case readKey    = 5
    case writeKey   = 6
    case getKeyInfo = 9
}

private let kSMCHandleYPCEvent: UInt32 = 2

// MARK: - Helpers

@inline(__always)
private func fourCC(_ s: String) -> UInt32 {
    precondition(s.utf8.count == 4, "SMC keys are 4 bytes")
    var v: UInt32 = 0
    for b in s.utf8 { v = (v << 8) | UInt32(b) }
    return v
}

@inline(__always)
private func fourCCString(_ k: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((k >> 24) & 0xFF),
        UInt8((k >> 16) & 0xFF),
        UInt8((k >> 8) & 0xFF),
        UInt8(k & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

/// Decode the 32-byte payload by type tag.
private enum SMCDecoder {
    static func toDouble(type: UInt32, size: UInt32, bytes: SMCBytes32) -> Double? {
        var b = bytes
        return withUnsafeBytes(of: &b) { raw -> Double? in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            switch fourCCString(type) {
            case "ui8 ":
                return Double(p[0])
            case "ui16":
                let v = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(v)
            case "ui32":
                let v = (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
                return Double(v)
            case "si8 ":
                return Double(Int8(bitPattern: p[0]))
            case "si16":
                let raw = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(Int16(bitPattern: raw))
            case "fpe2":
                let raw = (UInt16(p[0]) << 8) | UInt16(p[1])
                return Double(raw) / 4.0     // 14-bit int, 2-bit fraction
            case "sp78":
                let raw = Int16(bitPattern: (UInt16(p[0]) << 8) | UInt16(p[1]))
                return Double(raw) / 256.0   // signed 8.8 fixed-point
            case "flt ":
                var f: Float = 0
                memcpy(&f, p, 4)
                return Double(f)
            default:
                return nil
            }
        }
    }

    /// Encode an integer RPM into the 2-byte fpe2 payload most fan targets use.
    static func encodeFPE2(_ value: Int) -> (UInt8, UInt8) {
        let raw = UInt16(max(0, min(0x3FFF, value))) << 2   // 14.2 fixed
        return (UInt8(raw >> 8), UInt8(raw & 0xFF))
    }
}

// MARK: - AppleSMCService

public final class AppleSMCService: SMCService, @unchecked Sendable {
    public let backendName = "AppleSMC"
    public let isSimulated = false

    private var connection: io_connect_t = 0
    private var fanIndices: [Int] = []
    private var sensorKeys: [(key: String, name: String, kind: SensorKind)] = []
    private var cachedFans: [Fan] = []
    private var cachedSensors: [TempSensor] = []
    /// Routes writes through the privileged helper when direct SMC writes
    /// hit `kIOReturnNotPrivileged`. nil inside the helper process itself
    /// (we ARE the helper — connecting to our own socket would deadlock).
    private let helperClient: HelperClient?
    /// Per-fan cached mode-key case (F0Md vs F0md — varies by machine).
    private var modeKeyCache: [Int: String] = [:]

    /// Convenience init that returns nil if AppleSMC can't be opened
    /// (e.g. running in a sandbox without the kext, headless CI, etc.).
    /// `forceSafeReset` (default true) drops every fan we find in
    /// F0Md=1 back to F0Md=0 (auto) before the first snapshot. This
    /// closes review HIGH #5: if a previous run crashed mid-constant,
    /// thermalmonitord left F0Tg at whatever it last clamped, and a
    /// fresh init would otherwise adopt that value as "user intent"
    /// and re-assert it forever. Opt-out path exists for tests.
    /// `helperClient = nil` is the helper-process knob — without it
    /// the helper's own AppleSMCService would recursively connect to
    /// itself on every fallback path.
    public init?(helperClient: HelperClient? = HelperClient(),
                 forceSafeReset: Bool = true) {
        self.helperClient = helperClient
        // Catch struct-layout regressions before they corrupt SMC writes.
        precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                     "SMCParamStruct layout is wrong (expected 80 bytes, got \(MemoryLayout<SMCParamStruct>.stride)).")
        guard openSMC() else {
            Log.smc.error("AppleSMC could not be opened — falling back to mock backend")
            return nil
        }
        Log.smc.info("AppleSMC opened (connection=\(connection))")
        discoverFans()
        discoverSensors()
        Log.smc.info("AppleSMC discovered \(fanIndices.count) fans, \(sensorKeys.count) temperature sensors")
        if forceSafeReset {
            safeResetAllFansToAuto()
        }
        primeSnapshot()
    }

    /// Drop every fan currently in CONSTANT mode back to AUTO. Called
    /// at the start of every launch so a crashed previous run can't
    /// strand a fan pinned at the wrong RPM. Best-effort: failures are
    /// logged but don't block startup (helper might not be installed
    /// yet on first launch — user has to opt in via the elevation
    /// banner anyway).
    private func safeResetAllFansToAuto() {
        for i in fanIndices {
            let md = readDouble(modeKey(forFan: i)) ?? 0
            guard md >= 1 else { continue }
            // Use the same .auto path setMode does — direct then helper
            // fallback. Errors are logged inside.
            let fanID = "F\(i)"
            let ok = setMode(.auto, for: fanID)
            Log.fans.info("safeResetAllFansToAuto: \(fanID) was in CONSTANT, reset → \(ok ? "OK" : "failed (helper not yet available?)")")
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: SMCService

    public func snapshot() -> (fans: [Fan], sensors: [TempSensor]) {
        return (cachedFans, cachedSensors)
    }

    public func refresh() {
        primeSnapshot()
    }

    @discardableResult
    public func setMode(_ mode: FanMode, for fanID: String) -> Bool {
        guard let idx = Int(fanID.dropFirst()) else {
            Log.fans.error("setMode: invalid fanID '\(fanID)'")
            return false
        }
        // Per-call request ID so a single user click can be traced from
        // here into the helper (or the direct path) and out to the
        // cached-mode update. Search the log for r=NNN to follow one
        // click end-to-end.
        let r = nextRequestID()
        Log.fans.info("setMode r=\(r) fan=\(fanID) idx=\(idx) mode=\(modeDescription(mode)) hasHelper=\(helperClient != nil)")

        // HELPER-FIRST. On the unprivileged GUI/CLI the kernel rejects
        // EVERY direct SMC write (kIOReturnNotPrivileged — observe the
        // endless "writeRPM IOConnect returned nil" in the logs), so the
        // root helper is the ONLY process that can actually move a fan.
        // Route through it and trust its result. The direct path below
        // only runs when we ARE the helper (helperClient == nil) or when
        // no helper is installed and the helper call fails — in which
        // case a direct attempt is the last resort (and will succeed if
        // this process happens to be privileged, e.g. an Intel Mac or
        // root CLI).
        if let helper = helperClient {
            if setModeViaHelper(mode, for: fanID, idx: idx, helper: helper, r: r) {
                return true
            }
            Log.fans.warning("setMode r=\(r) fan=\(fanID) helper path failed — last-resort direct attempt")
        }

        return setModeDirect(mode, for: fanID, idx: idx, r: r)
    }

    /// Route a mode change through the privileged helper and update the
    /// local cache on success. Returns false if the helper is
    /// unreachable or rejects the write (caller then tries direct).
    private func setModeViaHelper(_ mode: FanMode, for fanID: String,
                                  idx: Int, helper: HelperClient, r: UInt32) -> Bool {
        switch mode {
        case .auto:
            guard helper.setMode(.auto, for: fanID) else { return false }
            Log.fans.info("setMode r=\(r) fan=\(fanID) AUTO OK (helper)")
            updateCachedMode(for: fanID, to: .auto)
            lastReleaseAt[idx] = Date()   // settle-window guard in primeSnapshot
            return true
        case .constant(let rpm):
            guard helper.setMode(.constant(rpm: rpm), for: fanID) else { return false }
            Log.fans.info("setMode r=\(r) fan=\(fanID) CONSTANT \(rpm) OK (helper)")
            updateCachedMode(for: fanID, to: .constant(rpm: rpm), targetRPM: rpm)
            return true
        case .sensorBased:
            // Sensor-based is host-driven: the GUI computes a target each
            // tick and the per-tick re-assertion sends it to the helper.
            // To get the fan into constant/unlocked NOW, seed the helper
            // with the current target (or a safe floor).
            let seed = cachedFans.first(where: { $0.id == fanID })?.targetRPM ?? minSafeRPM(forFan: idx)
            guard helper.setMode(.constant(rpm: seed), for: fanID) else { return false }
            Log.fans.info("setMode r=\(r) fan=\(fanID) SENSOR OK (helper, seeded \(seed))")
            updateCachedMode(for: fanID, to: mode)
            return true
        }
    }

    /// Direct SMC write path — used inside the helper process (root) or
    /// as a last resort when no helper is available. On the unprivileged
    /// GUI these writes fail and the method returns false.
    @discardableResult
    private func setModeDirect(_ mode: FanMode, for fanID: String, idx: Int, r: UInt32) -> Bool {
        switch mode {
        case .auto:
            // Apple-Silicon-correct release: F0Md → 0 first, then Ftst → 0
            // only if this is the last non-auto fan (handled inside
            // autoReleaseDirect). On a privileged process these writes
            // land; on the unprivileged GUI they fail and we return false
            // (the helper path in setMode() already ran first).
            if autoReleaseDirect(fanIdx: idx, r: r) {
                Log.fans.info("setMode r=\(r) fan=\(fanID) AUTO OK (direct)")
                updateCachedMode(for: fanID, to: .auto)
                return true
            }
            Log.fans.error("setMode r=\(r) fan=\(fanID) AUTO FAILED (direct path, no privilege)")
            return false
        case .constant(let rpm):
            if unlockFanControl(fanIdx: idx, r: r) && writeRPM(fanIdx: idx, rpm: rpm, r: r) {
                Log.fans.info("setMode r=\(r) fan=\(fanID) CONSTANT \(rpm) OK (direct)")
                updateCachedMode(for: fanID, to: .constant(rpm: rpm), targetRPM: rpm)
                return true
            }
            Log.fans.error("setMode r=\(r) fan=\(fanID) CONSTANT \(rpm) FAILED (direct path, no privilege)")
            return false
        case .sensorBased:
            // Sensor-based is host-driven (target computed per tick), but
            // the SMC still needs to be unlocked into CONSTANT so the
            // per-tick writeRPM actually moves the fan.
            if unlockFanControl(fanIdx: idx, r: r) {
                updateCachedMode(for: fanID, to: mode)
                Log.fans.info("setMode r=\(r) fan=\(fanID) SENSOR OK (direct unlock)")
                return true
            }
            Log.fans.error("setMode r=\(r) fan=\(fanID) SENSOR FAILED (direct path, no privilege)")
            return false
        }
    }

    /// Monotonic request id used in fan logs. Wraps trivially; only
    /// needed for human readability when scanning. Not thread-safe per
    /// se but setMode/primeSnapshot/per-tick are all funneled through
    /// AppState's smcQueue (and the helper is single-threaded).
    private static var _nextReqID: UInt32 = 0
    @inline(__always)
    private func nextRequestID() -> UInt32 {
        Self._nextReqID &+= 1
        return Self._nextReqID
    }

    /// Stable, debugger-friendly description of a mode.
    private func modeDescription(_ m: FanMode) -> String {
        switch m {
        case .auto: return ".auto"
        case .constant(let rpm): return ".constant(\(rpm))"
        case .sensorBased(let sid, let pts):
            let edges = pts.map { "\(Int($0.tempC))°→\($0.rpm)" }.joined(separator: ",")
            return ".sensorBased(\(sid), [\(edges)])"
        }
    }

    /// Canonical Apple Silicon AUTO release — cross-validated against
    /// exelban/stats, agoodkind/macos-smc-fan, leaperone/smctl. The
    /// firmware-resting state for an auto fan is F{i}Md == 3 (System,
    /// owned by thermalmonitord/AppleCLPC), NOT 0. Mode 0 is a
    /// transient unlock-dance value that never stably reads back.
    /// Therefore:
    ///   1. F{i}Md = 0 is hygiene — issue once, do NOT readback-verify
    ///      (the readback may legitimately settle to 3, not 0).
    ///   2. Ftst = 0 is the load-bearing write. It releases the global
    ///      veto on thermalmonitord's reclaim loop. The daemon then
    ///      repolls within ~250ms (thermal load) to ~4s (idle) and
    ///      settles F{i}Md back to 3.
    ///   3. Only lower Ftst when EVERY other fan is also auto — the
    ///      "Ftst is global" invariant. Otherwise constants on other
    ///      fans get silently re-locked by the firmware (review
    ///      finding "Ftst is global, treated as per-fan").
    /// See [[2026-06-30-Canonical-Auto-Release-Synthesis]] for the
    /// research that informed this rewrite.
    private func autoReleaseDirect(fanIdx: Int, r: UInt32) -> Bool {
        let mKey = modeKey(forFan: fanIdx)
        let initMd = readDouble(mKey) ?? -1
        let initFtst = readDouble("Ftst") ?? -1
        Log.fans.debug("autoReleaseDirect r=\(r) fan=F\(fanIdx) key=\(mKey) — initial md=\(initMd) ftst=\(initFtst)")

        // 1. Hygiene write: mode → 0. This is the LOAD-BEARING write
        //    when other fans are still constant (we keep Ftst=1).
        //    If it FAILS — which is the normal case from the
        //    unprivileged GUI — we must return false so the caller
        //    falls through to the helper, which has root and can
        //    actually write F0Md. Previously we returned true
        //    unconditionally and setMode silently skipped the helper
        //    fallback, leaving F0Md=1 in SMC; next primeSnapshot read
        //    md=1, the UI reverted .auto → .constant, and the AUTO
        //    button appeared to do nothing. (User logs r=4,r=6,r=7,
        //    r=8,r=9 all hit this path at 03:26.)
        let modeWrote = writeUInt8(key: mKey, value: 0)
        if !modeWrote {
            Log.fans.debug("autoReleaseDirect r=\(r) fan=F\(fanIdx) \(mKey)=0 write rejected (likely unprivileged) — will fall through to helper")
        }

        // 2. Ftst gate: only drop the global lock when no other fan is
        //    still user-forced. If any other fan is in .constant or
        //    .sensorBased, leaving Ftst=1 keeps thermalmonitord
        //    inhibited so they stay where the user pinned them.
        let othersStillConstant = cachedFans.contains { other in
            guard let oi = Int(other.id.dropFirst()), oi != fanIdx else { return false }
            switch other.mode {
            case .auto: return false
            case .constant, .sensorBased: return true
            }
        }
        if othersStillConstant {
            if modeWrote {
                Log.fans.info("autoReleaseDirect r=\(r) fan=F\(fanIdx) \(mKey)=0 ok; keeping Ftst=1 (other fans still non-auto)")
                lastReleaseAt[fanIdx] = Date()
                return true
            }
            // Direct mode-write rejected — let caller route through helper.
            return false
        }

        // 3. Last non-auto fan going home — release the global veto.
        //    Single attempt, no readback (matches agoodkind's
        //    resetFanControl() and Stats's writeWithRetry pattern).
        //    The firmware's next thermalmonitord poll (~250ms–4s) will
        //    flip F{i}Md from 1 to 3, and primeSnapshot's md==1
        //    classifier maps 3 → .auto so the UI won't flicker.
        let ftstOk = writeUInt8(key: "Ftst", value: 0)
        Log.fans.info("autoReleaseDirect r=\(r) fan=F\(fanIdx) modeWrote=\(modeWrote) Ftst=0 wrote=\(ftstOk) (last non-auto fan home; expecting md=3 within ~4s)")
        if !modeWrote || !ftstOk {
            // Either critical write failed — fall through to helper.
            return false
        }
        lastReleaseAt[fanIdx] = Date()
        return true
    }

    /// Per-fan timestamp of the most recent autoReleaseDirect call.
    /// primeSnapshot consults this to hold the UI in .auto for ~4.5s
    /// after release — the worst-case thermalmonitord repoll window.
    /// Without this hold, a snapshot landing in the brief md=1→3
    /// transition would briefly flash .constant in the UI.
    private var lastReleaseAt: [Int: Date] = [:]

    /// Per-sensor last value that passed the ghost-value filter. Used
    /// to hold the UI steady when M-series firmware power-gates a core
    /// (sensor cache returns sentinel 1.9°C or -4°C) — without this
    /// the temperature column would jitter wildly every tick.
    private var lastValidSensor: [String: TempSensor] = [:]

    /// Floor used when we have to ask the helper to enter constant mode
    /// before sensor-based takes over driving — we don't want to spike
    /// the fan during the brief moment between the helper write and the
    /// next poll-tick target push.
    private func minSafeRPM(forFan idx: Int) -> Int {
        let minR = readDouble("F\(idx)Mn") ?? 1200
        return Int(minR)
    }


    // MARK: - Apple Silicon fan-control dance

    /// Apple Silicon firmware silently rejects `F0Md = 1` unless `Ftst`
    /// is unlocked first. Sequence cribbed from exelban/stats SMC.swift.
    /// Now READBACK-VERIFIED at each step so a stale-cache or
    /// firmware-reject doesn't silently return success.
    private func unlockFanControl(fanIdx: Int, r: UInt32 = 0) -> Bool {
        let mKey = modeKey(forFan: fanIdx)
        Log.fans.debug("unlockFanControl r=\(r) fan=F\(fanIdx) key=\(mKey) — initial md=\(readDouble(mKey) ?? -1) ftst=\(readDouble("Ftst") ?? -1)")

        // Fast path: direct mode write (works on Intel + M5+). Verify
        // by readback — kSMCSuccess from writeKey can lie.
        if writeUInt8(key: mKey, value: 1) {
            usleep(20_000)
            let rb = readDouble(mKey) ?? -1
            if rb >= 1 {
                Log.fans.info("unlockFanControl r=\(r) fan=F\(fanIdx) FAST PATH ok (\(mKey) readback=\(rb))")
                return true
            }
            Log.fans.debug("unlockFanControl r=\(r) fan=F\(fanIdx) fast path write ack but readback=\(rb) — falling to slow path")
        }

        // Slow path: read Ftst, write it to 1, wait, retry.
        let alreadyUnlocked: Bool
        if let v = readDouble("Ftst") {
            alreadyUnlocked = v >= 1
            Log.fans.debug("unlockFanControl r=\(r) fan=F\(fanIdx) Ftst=\(v) alreadyUnlocked=\(alreadyUnlocked)")
        } else {
            // No Ftst key — give up; either firmware is locking us out
            // some other way, or we're going through the helper anyway.
            Log.fans.warning("unlockFanControl r=\(r) fan=F\(fanIdx) no Ftst key — giving up")
            return false
        }

        if alreadyUnlocked {
            for attempt in 0..<20 {
                if writeUInt8(key: mKey, value: 1) {
                    usleep(20_000)
                    let rb = readDouble(mKey) ?? -1
                    if rb >= 1 {
                        Log.fans.info("unlockFanControl r=\(r) fan=F\(fanIdx) ok via Ftst-already-unlocked retry=\(attempt) (\(mKey) readback=\(rb))")
                        return true
                    }
                }
                usleep(50_000)
            }
            Log.fans.warning("unlockFanControl r=\(r) fan=F\(fanIdx) Ftst already 1 but \(mKey)=1 still not landing after 20 retries")
            return false
        }

        var pushed = false
        for attempt in 0..<100 {
            if writeUInt8(key: "Ftst", value: 1) { pushed = true; break }
            if attempt == 99 { Log.fans.error("unlockFanControl r=\(r) fan=F\(fanIdx) Ftst=1 write rejected 100 times") }
            usleep(50_000)
        }
        if !pushed { return false }
        Log.fans.debug("unlockFanControl r=\(r) fan=F\(fanIdx) Ftst=1 pushed; sleeping 3s for thermalmonitord")

        // Give thermalmonitord up to 3 s to yield control.
        usleep(3_000_000)
        for attempt in 0..<300 {
            if writeUInt8(key: mKey, value: 1) {
                usleep(20_000)
                let rb = readDouble(mKey) ?? -1
                if rb >= 1 {
                    Log.fans.info("unlockFanControl r=\(r) fan=F\(fanIdx) ok after Ftst-dance retry=\(attempt) (\(mKey) readback=\(rb))")
                    return true
                }
            }
            usleep(100_000)
        }
        Log.fans.error("unlockFanControl r=\(r) fan=F\(fanIdx) GAVE UP after full Ftst dance — \(mKey) never went to 1")
        return false
    }

    /// Safety floor for any RPM write. The UI clamps in
    /// `AppState.applyOptimisticMode` but that's display-only; raw CLI /
    /// helper / programmatic calls bypass it. Anything below 800 RPM
    /// will be silently bumped — most Apple Silicon Macs spin their
    /// fans at 1200+ RPM minimum, and an actual 0 written into F0Tg can
    /// stall the bearing (review HIGH #2).
    private static let absoluteMinSafeRPM: Int = 800

    /// Write a target RPM honoring the key's actual data type. On
    /// Apple Silicon `F\(i)Tg` is `flt ` (4-byte IEEE 754); on Intel
    /// it's `fpe2` (2-byte 14.2 fixed-point). Caller-supplied `rpm` is
    /// clamped against the absolute floor BEFORE encoding so no path
    /// (CLI, helper, host re-assertion) can hit zero.
    private func writeRPM(fanIdx: Int, rpm rawRPM: Int, r: UInt32 = 0) -> Bool {
        let rpm = max(Self.absoluteMinSafeRPM, rawRPM)
        if rpm != rawRPM {
            Log.fans.debug("writeRPM r=\(r) fan=F\(fanIdx) clamped \(rawRPM) → \(rpm) (safety floor)")
        }
        let key = "F\(fanIdx)Tg"
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else {
            Log.smc.error("writeRPM r=\(r) fan=F\(fanIdx) getKeyInfo(\(key)) FAILED")
            return false
        }

        var write = SMCParamStruct()
        write.key = fourCC(key)
        write.keyInfo = infoOut.keyInfo
        write.data8 = SMCCall.writeKey.rawValue

        let typeStr = fourCCString(infoOut.keyInfo.dataType)
        switch typeStr {
        case "fpe2":
            let (hi, lo) = SMCDecoder.encodeFPE2(rpm)
            write.bytes.0 = hi
            write.bytes.1 = lo
        case "flt ":
            let f = Float(rpm)
            let bits = f.bitPattern
            // SMC stores flt little-endian — matches how we decode it.
            write.bytes.0 = UInt8(bits & 0xFF)
            write.bytes.1 = UInt8((bits >> 8) & 0xFF)
            write.bytes.2 = UInt8((bits >> 16) & 0xFF)
            write.bytes.3 = UInt8((bits >> 24) & 0xFF)
        case "ui16":
            let v = UInt16(max(0, min(Int(UInt16.max), rpm)))
            write.bytes.0 = UInt8(v >> 8)
            write.bytes.1 = UInt8(v & 0xFF)
        default:
            Log.smc.error("writeRPM r=\(r) fan=F\(fanIdx) unsupported \(key) type '\(typeStr)' — refusing to write")
            return false
        }

        guard let writeOut = call(input: write) else {
            Log.smc.error("writeRPM r=\(r) fan=F\(fanIdx) IOConnect call returned nil")
            return false
        }
        if writeOut.result != 0 {
            Log.smc.warning("writeRPM r=\(r) fan=F\(fanIdx) \(key)=\(rpm) (type=\(typeStr)) result=\(writeOut.result)")
            return false
        }
        return true
    }

    /// Probes both `F\(i)Md` (uppercase) and `F\(i)md` (lowercase) and
    /// caches whichever one the SMC answers. Different machines expose
    /// different case.
    private func modeKey(forFan idx: Int) -> String {
        if let cached = modeKeyCache[idx] { return cached }
        let upper = "F\(idx)Md"
        let lower = "F\(idx)md"
        if readDouble(upper) != nil { modeKeyCache[idx] = upper; return upper }
        if readDouble(lower) != nil { modeKeyCache[idx] = lower; return lower }
        modeKeyCache[idx] = upper
        return upper
    }

    // MARK: - SMC primitives

    private func openSMC() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return kr == KERN_SUCCESS
    }

    /// Look up data type + size for a key, then read the payload.
    private func readKey(_ key: String) -> (type: UInt32, size: UInt32, bytes: SMCBytes32)? {
        // Phase 1: getKeyInfo
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        let type = infoOut.keyInfo.dataType
        guard size > 0 else { return nil }

        // Phase 2: readKey
        var read = SMCParamStruct()
        read.key = fourCC(key)
        read.keyInfo.dataSize = size
        read.data8 = SMCCall.readKey.rawValue
        guard let readOut = call(input: read) else { return nil }
        if readOut.result != 0 {
            Log.smc.debug("SMC read \(key) result=\(readOut.result)")
            return nil
        }
        return (type, size, readOut.bytes)
    }

    /// Read a key and pull the numeric value as a Double — works for
    /// fpe2 / sp78 / flt / ui* / si* tagged payloads.
    private func readDouble(_ key: String) -> Double? {
        guard let r = readKey(key) else { return nil }
        return SMCDecoder.toDouble(type: r.type, size: r.size, bytes: r.bytes)
    }

    private func writeUInt8(key: String, value: UInt8) -> Bool {
        // Get the existing key info first so the kernel accepts the write.
        var info = SMCParamStruct()
        info.key = fourCC(key)
        info.data8 = SMCCall.getKeyInfo.rawValue
        guard let infoOut = call(input: info) else { return false }
        var write = SMCParamStruct()
        write.key = fourCC(key)
        write.keyInfo = infoOut.keyInfo
        write.data8 = SMCCall.writeKey.rawValue
        write.bytes.0 = value
        guard let writeOut = call(input: write) else { return false }
        return writeOut.result == 0
    }

    private func call(input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let inputSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input, inputSize,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS else {
            Log.smc.debug("IOConnectCallStructMethod kr=\(kr)")
            return nil
        }
        return output
    }

    // MARK: - Discovery

    private func discoverFans() {
        guard let n = readDouble("FNum") else {
            fanIndices = []
            return
        }
        fanIndices = (0..<Int(n)).map { $0 }
    }

    /// Known SMC keys that resolve on Apple Silicon Macs (M1/M2/M3/M4)
    /// plus a few Intel-era keys for backward compatibility. We probe each
    /// at discovery time and only keep the ones the chip actually answers.
    private static let candidateSensors: [(String, String, SensorKind)] = [
        // CPU
        ("TC0E", "CPU Die Temperature", .cpu),
        ("TC0F", "CPU Die Filtered", .cpu),
        ("TC0P", "CPU Proximity", .cpu),
        ("TC0H", "CPU Heatpipe", .cpu),
        ("TC1C", "CPU Core 1", .cpu),
        ("TC2C", "CPU Core 2", .cpu),
        ("TC3C", "CPU Core 3", .cpu),
        ("TC4C", "CPU Core 4", .cpu),
        // Apple-Silicon performance cores (M1/M2/M3/M4 — up to 8 per cluster)
        ("Tp09", "CPU Performance Core 1", .cpu),
        ("Tp0T", "CPU Performance Core 2", .cpu),
        ("Tp0b", "CPU Performance Core 3", .cpu),
        ("Tp0d", "CPU Performance Core 4", .cpu),
        ("Tp01", "CPU Performance Core 5", .cpu),
        ("Tp05", "CPU Performance Core 6", .cpu),
        ("Tp0D", "CPU Performance Core 7", .cpu),
        ("Tp0X", "CPU Performance Core 8", .cpu),
        // Apple-Silicon efficiency cores
        ("Tp0f", "CPU Efficiency Core 1", .cpu),
        ("Tp0n", "CPU Efficiency Core 2", .cpu),
        ("Tp0r", "CPU Efficiency Core 3", .cpu),
        ("Tp0t", "CPU Efficiency Core 4", .cpu),
        ("Tp0v", "CPU Efficiency Core 5", .cpu),
        ("Tp0z", "CPU Efficiency Core 6", .cpu),
        // GPU
        ("TG0D", "GPU Die", .gpu),
        ("TG0P", "GPU Proximity", .gpu),
        ("TG0H", "GPU Heatpipe", .gpu),
        ("Tg05", "GPU Cluster 1", .gpu),
        ("Tg0D", "GPU Cluster 2", .gpu),
        ("Tg0L", "GPU Cluster 3", .gpu),
        ("Tg0T", "GPU Cluster 4", .gpu),
        ("Tg0V", "GPU Cluster 5", .gpu),
        ("Tg0d", "GPU Cluster 6", .gpu),
        // Battery
        ("TB0T", "Battery", .battery),
        ("TB1T", "Battery Cell 1", .battery),
        ("TB2T", "Battery Cell 2", .battery),
        // Storage
        ("TH0a", "NVMe SSD", .storage),
        ("TH0b", "NVMe SSD Drive", .storage),
        ("TH0x", "SSD Hottest", .storage),
        // Airport / Thunderbolt / Misc proximities
        ("TW0P", "Airport Proximity", .airport),
        ("TTLD", "Thunderbolt Left", .thunderbolt),
        ("TTRD", "Thunderbolt Right", .thunderbolt),
        ("TPCD", "Platform Controller", .proximity),
        ("Ts0S", "Palm Rest", .proximity),
        // Power
        ("TPDA", "Power Manager Die Avg", .power),
        ("TPSP", "Power Supply Proximity", .power),
        // Trackpad — different M-series machines expose different keys.
        ("TTPD", "Trackpad", .trackpad),
        ("Ttp0", "Trackpad", .trackpad),
        ("TaaP", "Trackpad", .trackpad),
        ("TaaS", "Trackpad Surface", .trackpad),
    ]

    private func discoverSensors() {
        var found: [(String, String, SensorKind)] = []
        for (key, name, kind) in Self.candidateSensors {
            if readDouble(key) != nil {
                found.append((key, name, kind))
            }
        }
        sensorKeys = found
    }

    // MARK: - Snapshot

    private func primeSnapshot() {
        // Fans
        var newFans: [Fan] = []
        for i in fanIndices {
            let actual = readDouble("F\(i)Ac") ?? 0
            let minR   = readDouble("F\(i)Mn") ?? 0
            let maxR   = readDouble("F\(i)Mx") ?? max(actual, 6000)
            let target = readDouble("F\(i)Tg") ?? actual
            let md     = readDouble(modeKey(forFan: i)) ?? 0

            let existing = cachedFans.first(where: { $0.id == "F\(i)" })
            // Apple-Silicon mode-key semantics (cross-validated against
            // exelban/stats, agoodkind/macos-smc-fan, leaperone/smctl):
            //   0 = auto (transient state during unlock dance)
            //   1 = user-forced (we wrote F0Md=1 + Ftst=1)
            //   3 = "System" — thermalmonitord/AppleCLPC are actively
            //       managing the fan. This IS the firmware-resting auto
            //       state on M1–M4; reading md=3 means our AUTO release
            //       succeeded and the system has taken back control.
            // Bug we were hitting: treating `md >= 1` as constant lumped
            // 1 (forced) and 3 (system) into the same bucket, so a
            // successful AUTO release → firmware reclaim → next snapshot
            // reads md=3 → UI flips back to CONSTANT and the gauge looks
            // like the AUTO click "didn't take". Fix: ONLY md == 1 is
            // user-forced; everything else (0, 3, and any future state)
            // is firmware-managed and presented as .auto.
            // Settle window: for ~4.5s after autoReleaseDirect, treat
            // any md value as .auto. Thermalmonitord's reclaim poll can
            // take up to 4s under idle load, and during the transition
            // md may briefly still read 1 before settling to 3. Without
            // this hold, a snapshot landing in that window would flicker
            // the UI to .constant. Matches Stats's implicit 1–3s settle
            // via slow sensor polling.
            let inReleaseSettle: Bool = {
                guard let t = lastReleaseAt[i] else { return false }
                return Date().timeIntervalSince(t) < 4.5
            }()
            let baseMode: FanMode = (md == 1 && !inReleaseSettle)
                ? .constant(rpm: Int(target))
                : .auto
            // Preserve host-driven modes — SMC doesn't reliably report
            // them back to us:
            //  • .sensorBased: SMC has no concept of it, so we keep ours.
            //  • .constant: Apple Silicon's thermalmonitord can clamp F0Tg
            //    back to whatever it thinks the current load needs (e.g.
            //    we wrote 5500, readback returns 4142). Trust the value
            //    we last wrote, not the firmware's claw-back. The host
            //    loop at the bottom of this method re-asserts the write
            //    on every tick so the physical fan stays where we put it.
            // Note: the `md == 1` gate matches baseMode's classification —
            // a firmware-System (md=3) readback is NOT user-forced and
            // must fall through to baseMode (.auto) regardless of what
            // the prior cached mode said.
            let mode: FanMode
            let displayedTarget: Int
            if case .sensorBased = existing?.mode {
                mode = existing!.mode
                displayedTarget = existing?.targetRPM ?? Int(target)
            } else if case .constant(let cachedRPM) = existing?.mode, md == 1, !inReleaseSettle {
                // Cached + SMC agree we're user-forced — preserve the
                // exact RPM the user pinned (firmware claw-back on
                // F0Tg can return a lower value; we trust our cache).
                //
                // CRITICAL: this branch is gated on md == 1. If the
                // user calls setMode(.auto), the helper drops F0Md=0
                // and Ftst=0; thermalmonitord reclaims and md flips
                // 1 → 3 within ~250ms-4s. From that moment onward,
                // md != 1, this branch is skipped, and baseMode
                // (.auto) wins. PREVIOUSLY this branch lacked the
                // md == 1 gate and ran on EVERY tick, holding the
                // cached .constant forever regardless of SMC state —
                // the bug that killed the temperature feedback loop
                // and made AUTO appear no-op.
                mode = .constant(rpm: cachedRPM)
                displayedTarget = cachedRPM
            } else {
                mode = baseMode
                displayedTarget = Int(target)
            }
            Log.fans.debug("primeSnapshot fan=F\(i) actual=\(Int(actual)) target=\(Int(target)) md=\(md) → mode=\(modeDescription(mode)) displayedTarget=\(displayedTarget)")

            newFans.append(Fan(
                id: "F\(i)",
                name: fanName(for: i),
                minRPM: Int(minR),
                maxRPM: Int(maxR),
                currentRPM: Int(actual),
                targetRPM: displayedTarget,
                mode: mode
            ))
        }

        // Real sensors. On Apple Silicon (verified on M4 — sensors
        // jumping 40 ↔ 1.9°C every tick), the firmware writes constant
        // SENTINEL values into per-core SoC sensors when individual
        // cores power-gate: 1.9°C (Float32 0x3FF33333), -4.0°C
        // (Float32 0xC0800000), 0.0°C, and on some firmware revs 40.0°C
        // (the M4 Mac16,5 "idle floor" — looks legit, never updates).
        // They're not real temperatures — the cache holds them whenever
        // the core hasn't woken in the last few ms.
        //
        // Two-pass ghost filter:
        //
        //   PASS 1: read every readable Tp*/Tg*/off-chip sensor into
        //           a raw[] array. Read failures and hard out-of-band
        //           values hold last-valid (or are dropped) right away.
        //
        //   GHOST CLUSTER DETECTION: within the Tp* prefix and the
        //           Tg* prefix SEPARATELY, bucket every raw reading
        //           to 1/100 °C precision (Int(value * 100)). Any
        //           bucket with ≥4 members is a power-gated cache
        //           stamp — real diode reads have ≥0.1 °C of noise
        //           across cores even at deep idle, so 4 cores hitting
        //           the same 0.01 °C bucket is astronomically improbable
        //           in real data. This catches the 40.0 °C sentinel
        //           (which the old `raw < 10` floor missed entirely).
        //
        //   PASS 2: per-sensor — if the key is in a detected ghost
        //           cluster OR is a sub-10 °C CPU/GPU core reading
        //           (legacy 1.9 / -4 / 0 sentinels, catches the case
        //           where only 1 core is gated and the cluster test
        //           doesn't fire), hold lastValidSensor[key], or omit
        //           entirely if no prior valid exists. Off-chip sensors
        //           (battery, airport, storage, power) never ghost and
        //           pass through unchanged.
        struct RawReading {
            let key: String
            let name: String
            let kind: SensorKind
            let c: Double
        }
        var newSensors: [TempSensor] = []
        var raw: [RawReading] = []
        var rawByKey: [String: Double] = [:]
        for (key, name, kind) in sensorKeys {
            guard let v = readDouble(key) else { continue }
            // Hard out-of-band guard (real sensor never reports outside this).
            guard v > -20, v < 130 else { continue }
            raw.append(RawReading(key: key, name: name, kind: kind, c: v))
            rawByKey[key] = v
        }

        // Bucket Tp* and Tg* prefixes separately. Any 0.01 °C bucket
        // with ≥3 members is a power-gated ghost cluster — lowered from
        // ≥4 because the M4 ghost stamp can affect just 3 cores at a
        // time as clusters wake asymmetrically (screenshot #33 had
        // exactly 3 perf cores stuck at 40.00 °C).
        func clusterGhosts<S: Sequence>(_ readings: S) -> Set<String>
        where S.Element == RawReading {
            let arr = Array(readings)
            guard arr.count >= 3 else { return [] }
            let buckets = Dictionary(grouping: arr, by: { Int($0.c * 100) })
            var out: Set<String> = []
            for (_, members) in buckets where members.count >= 3 {
                out.formUnion(members.map(\.key))
            }
            return out
        }
        let ghostKeys: Set<String> =
            clusterGhosts(raw.lazy.filter { $0.key.hasPrefix("Tp") })
            .union(clusterGhosts(raw.lazy.filter { $0.key.hasPrefix("Tg") }))
        if !ghostKeys.isEmpty {
            Log.smc.warning("Ghost cluster filter suppressed \(ghostKeys.count) sensors: \(ghostKeys.sorted().joined(separator: ",")) — power-gated cache stamp")
        }

        // Known firmware sentinel values for Tp*/Tg* per-core sensors.
        // These EXACT two-decimal values are deterministic cache stamps,
        // not real diode readings. Real per-core temps have thermal
        // noise of ≥0.05 °C, so a reading that lands EXACTLY on one of
        // these to the hundredth is a ghost regardless of cluster size
        // — catches the case where only 1 or 2 cores ghost while
        // others are awake (cluster detector below requires ≥3).
        let knownSentinels: Set<Int> = [
            -400,   // -4.00 °C — observed on Tp0d
               0,   //  0.00 °C — observed on Eff cores
             190,   //  1.90 °C — Float32 0x3FF33333, most common
            4000,   // 40.00 °C — M4 "idle floor" cache stamp
        ]

        // Pass 2: emit sensors in original sensorKeys order.
        for (key, name, kind) in sensorKeys {
            // Read failure or out-of-band: hold last valid (or omit).
            guard let v = rawByKey[key] else {
                if let prev = lastValidSensor[key] {
                    newSensors.append(prev)
                }
                continue
            }
            let isCoreCpu = key.hasPrefix("Tp") || key.hasPrefix("Tg")
            let bucket = Int(v * 100)
            let isKnownSentinel = isCoreCpu && knownSentinels.contains(bucket)
            let isGhost = ghostKeys.contains(key)
                       || isKnownSentinel
                       || (isCoreCpu && v < 10)
            if isGhost {
                // Prefer the last good value — smooths a transient
                // single-tick ghost while the chip is active. But NEVER
                // hide the sensor: if we have no prior good value (deep
                // idle right after launch, all cores power-gated at
                // once), show the raw reading anyway. An occasionally
                // wrong number beats an empty CPU section. We do NOT
                // seed lastValidSensor with a ghost, so the moment a
                // real read lands it takes over.
                //
                // (Proper fix tracked for follow-up: read live
                // cluster temps via IOHIDEventSystemClient — pACC MTR /
                // eACC MTR / GPU MTR — which the firmware keeps awake
                // and never power-gate. The SMC Tp*/Tg* per-core keys
                // are fundamentally unreliable at idle on Apple Silicon.)
                let shown = lastValidSensor[key]
                    ?? TempSensor(id: key, name: name, kind: kind, celsius: v)
                newSensors.append(shown)
                continue
            }
            let s = TempSensor(id: key, name: name, kind: kind, celsius: v)
            newSensors.append(s)
            lastValidSensor[key] = s
        }

        // Virtual aggregates — avg/max across logical groups. These appear
        // in both the right rail and the sensor-based mode picker so the
        // user can target "hottest CPU core" with a single selection.
        newSensors.append(contentsOf: virtualSensors(from: newSensors))

        cachedFans = newFans
        cachedSensors = newSensors

        // Per-tick fan driving. Re-assertion of CONSTANT is now OWNED BY
        // THE HELPER (it holds heldTargets and re-pushes every second as
        // root). So the GUI does NOTHING here for .constant — set-once via
        // setMode is enough; the helper keeps it pinned. This removes the
        // 1 Hz socket spam + the Ftst-bounce that fought AUTO.
        //
        // .sensorBased stays host-driven: only the GUI knows the chosen
        // sensor + curve, so we compute the target each tick and send it
        // to the helper (which holds + re-asserts it between our updates).
        // Inside the helper process (helperClient == nil) the helper's own
        // re-assertion timer drives it, so we skip here.
        guard helperClient != nil else { return }   // helper drives itself
        for fan in cachedFans {
            guard case .sensorBased(let sid, let pts) = fan.mode else { continue }
            if let s = newSensors.first(where: { $0.id == sid }) {
                let rpm = rpmForTemp(s.celsius, fan: fan, points: pts)
                _ = helperClient?.setMode(.constant(rpm: rpm), for: fan.id)
            } else {
                // Sensor disappeared — leaving the fan unlocked at a stale
                // target with nothing observing temperature is dangerous.
                // Drop to AUTO.
                Log.fans.warning("Fan \(fan.id) sensor '\(sid)' missing — falling back to AUTO")
                _ = setMode(.auto, for: fan.id)
            }
        }
    }

    private func fanName(for index: Int) -> String {
        switch index {
        case 0: return "Left side"
        case 1: return "Right side"
        case 2: return "Fan 3"
        case 3: return "Fan 4"
        default: return "Fan \(index + 1)"
        }
    }

    /// Piecewise-linear interpolation over the user's ramp. Points are
    /// sorted by tempC; outside the range, the endpoint rpm is held.
    /// Returned rpm is clamped into the fan's [minRPM, maxRPM] envelope.
    private func rpmForTemp(_ c: Double, fan: Fan, points: [RampPoint]) -> Int {
        let sorted = points.sorted(by: { $0.tempC < $1.tempC })
        guard let first = sorted.first else { return fan.minRPM }
        guard sorted.count >= 2 else { return clampRPM(first.rpm, fan: fan) }
        if c <= first.tempC { return clampRPM(first.rpm, fan: fan) }
        if c >= sorted.last!.tempC { return clampRPM(sorted.last!.rpm, fan: fan) }
        // Find the segment [a, b] enclosing c.
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if c >= a.tempC && c <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return clampRPM(a.rpm, fan: fan) }
                let t = (c - a.tempC) / span
                let rpm = Double(a.rpm) + t * Double(b.rpm - a.rpm)
                return clampRPM(Int(rpm.rounded()), fan: fan)
            }
        }
        return clampRPM(sorted.last!.rpm, fan: fan)
    }

    private func clampRPM(_ rpm: Int, fan: Fan) -> Int {
        max(fan.minRPM, min(fan.maxRPM, rpm))
    }

    // MARK: - Virtual sensors

    /// Compute aggregate temperatures for the picker / right rail. IDs
    /// are prefixed with "__" so they can't collide with real SMC keys.
    /// `sensorBased` mode picks them up automatically because the host
    /// loop in `primeSnapshot()` looks the chosen sensor up by ID inside
    /// the returned list (which now includes these aggregates).
    private func virtualSensors(from real: [TempSensor]) -> [TempSensor] {
        var out: [TempSensor] = []

        // CPU performance cores
        let perf = real.filter { isPerformanceCore($0.id) }
        if let avg = avg(perf), let mx = mx(perf) {
            out.append(.init(id: "__cpu_perf_avg",
                             name: "CPU Performance · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_perf_max",
                             name: "CPU Performance · Max",
                             kind: .cpu, celsius: mx))
        }

        // CPU efficiency cores
        let eff = real.filter { isEfficiencyCore($0.id) }
        if let avg = avg(eff), let mx = mx(eff) {
            out.append(.init(id: "__cpu_eff_avg",
                             name: "CPU Efficiency · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_eff_max",
                             name: "CPU Efficiency · Max",
                             kind: .cpu, celsius: mx))
        }

        // Whole-CPU rollup (all cores combined)
        let allCPU = real.filter { $0.kind == .cpu }
        if let avg = avg(allCPU), let mx = mx(allCPU) {
            out.append(.init(id: "__cpu_all_avg",
                             name: "CPU All Cores · Avg",
                             kind: .cpu, celsius: avg))
            out.append(.init(id: "__cpu_all_max",
                             name: "CPU All Cores · Max",
                             kind: .cpu, celsius: mx))
        }

        // GPU clusters
        let gpu = real.filter { $0.kind == .gpu && $0.id.hasPrefix("Tg") }
        if let avg = avg(gpu), let mx = mx(gpu) {
            out.append(.init(id: "__gpu_avg",
                             name: "GPU Clusters · Avg",
                             kind: .gpu, celsius: avg))
            out.append(.init(id: "__gpu_max",
                             name: "GPU Clusters · Max",
                             kind: .gpu, celsius: mx))
        }

        // DIVERGED ON PURPOSE (2026-08-02, annotated 2026-08-20): the
        // __hottest virtual sensor below is pultik's protocol-v9 addition
        // with no upstream counterpart — same convention as
        // HelperHoldState.swift. Upstreaming a virtual-sensor hook is
        // tracked with the HelperClient timeout in the vault item
        // re-vendor-helperclient-write-timeout-upstream-in-genesisfancontrol.
        //
        // Hottest die, CPU or GPU — what pultik's fan curves are driven by
        // (decision D3, 2026-08-02). Whichever is about to throttle is what
        // the fans should be answering to, and a CPU-only curve ramps late
        // on a long GPU-bound session.
        if let hottest = mx(real.filter { $0.kind == .cpu || $0.kind == .gpu }) {
            out.append(.init(id: FanCurve.defaultSensorID,
                             name: "Hottest die · CPU or GPU",
                             kind: .cpu, celsius: hottest))
        }
        return out
    }

    private func isPerformanceCore(_ id: String) -> Bool {
        // 4-char keys starting with "Tp" and ending in 9 / T / b / d (M1/M2)
        // or 1 / 5 / D / X (M3/M4 extensions).
        guard id.hasPrefix("Tp"), id.count == 4 else { return false }
        let suffix = id.suffix(1)
        return ["9", "T", "b", "d", "1", "5", "D", "X"].contains(String(suffix))
    }

    private func isEfficiencyCore(_ id: String) -> Bool {
        // Efficiency cores use Tp0{f,n,r,t,v,z} on M-series.
        guard id.hasPrefix("Tp0"), id.count == 4 else { return false }
        let suffix = id.suffix(1)
        return ["f", "n", "r", "t", "v", "z"].contains(String(suffix))
    }

    private func avg(_ xs: [TempSensor]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.map(\.celsius).reduce(0, +) / Double(xs.count)
    }

    private func mx(_ xs: [TempSensor]) -> Double? {
        xs.map(\.celsius).max()
    }

    // MARK: - In-memory mode bookkeeping

    private func updateCachedMode(for fanID: String, to mode: FanMode, targetRPM: Int? = nil) {
        guard let i = cachedFans.firstIndex(where: { $0.id == fanID }) else {
            Log.fans.debug("updateCachedMode fan=\(fanID) not in cache — no-op")
            return
        }
        let prev = modeDescription(cachedFans[i].mode)
        cachedFans[i].mode = mode
        if let t = targetRPM { cachedFans[i].targetRPM = t }
        Log.fans.debug("updateCachedMode fan=\(fanID) \(prev) → \(modeDescription(mode))\(targetRPM.map { " target=\($0)" } ?? "")")
    }
}
