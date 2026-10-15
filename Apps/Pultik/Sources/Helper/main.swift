// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlHelper/main.swift).
// DIVERGED ON PURPOSE (2026-08-01): this is pultik's own daemon now — names,
// queue labels and log lines are pultik's, and the types it needs live in the
// same target rather than in GenesisFanControlCore. The logic is untouched;
// re-vendor behavior changes from upstream, never the identity.
//
//  main.swift
//  pultik-fan-control-helper
//
//  Privileged daemon. Runs as root via launchd, owns AppleSMCService
//  writes, listens on a Unix domain socket for JSON requests from the
//  unprivileged app:
//   • Socket is root:admin 0660 (so non-admin UIDs can't even connect).
//   • Every accepted connection is checked via getpeereid(2) — must be
//     root or the active console user.
//   • Every non-auto fan write is tracked. SIGTERM / SIGINT revert every
//     tracked fan to .auto before unlink + exit, so a daemon kill
//     (launchctl bootout, system shutdown, manual kill) can't strand the
//     fan at a pinned RPM.
//   • Idle watchdog: if no client has talked to us in >60s AND we hold
//     locked fans, revert them. Guards against a crashed app that would
//     otherwise leave fans pinned forever.
//

import Foundation
import Darwin
import SystemConfiguration

let stderrStream = FileHandle.standardError

func log(_ message: String) {
    let line = "[helper] \(Date()) \(message)\n"
    if let data = line.data(using: .utf8) { stderrStream.write(data) }
}

log("pultik-fan-control-helper starting (uid=\(getuid()))")

// helperClient: nil — we ARE the helper. Without this the helper's own
// AppleSMCService would try to connect to its own socket on any
// fallback path and deadlock.
// forceSafeReset: false — launchd respawns the helper on every crash
// (KeepAlive=true). With forceSafeReset=true every respawn would call
// safeResetAllFansToAuto(), silently wiping the user's pinned CONSTANT
// back to AUTO and producing the "constant speed jumping around" bug.
// Cold-start safety is the app's job (its AppleSMCService default IS
// true); the helper just executes commands.
guard let smc = AppleSMCService(helperClient: nil, forceSafeReset: false) else {
    log("FATAL: AppleSMCService failed to open")
    exit(1)
}
log("AppleSMC opened — backend=\(smc.backendName)")

let listenFD: Int32
do {
    listenFD = try UnixSocket.listen(atPath: HelperConstants.socketPath)
} catch {
    log("FATAL: bind/listen on \(HelperConstants.socketPath): \(error)")
    exit(2)
}
log("listening on \(HelperConstants.socketPath) (root:admin 0660)")

// MARK: - Held-fan state + re-assertion (helper OWNS the hold)

/// Fans this helper is actively holding at a constant RPM, fanID → rpm.
/// The helper RE-ASSERTS these on its own 1 Hz timer (it's root and
/// persistent), so a pinned fan holds regardless of whether the app is
/// running. This is the core of the design: the unprivileged app cannot
/// write SMC and cannot reliably re-assert; the root helper can and does.
///   • setConstant adds/updates an entry + writes once immediately.
///   • setAuto removes the entry + releases the fan.
///   • the re-assertion timer re-pushes every held target each second to
///     defeat thermalmonitord's claw-back.
///   • SIGTERM/SIGINT + idle watchdog revert every held fan (safety).
///
/// All touches gated by stateQueue (the accept loop, the re-assertion
/// timer, and the watchdog all run on different queues).
let stateQueue = DispatchQueue(label: "dev.example.pultik.fan-helper.state")
nonisolated(unsafe) var holdState = HelperHoldState()
nonisolated(unsafe) var lastActivity: Date = Date()

@Sendable func recordActivity() {
    stateQueue.sync { lastActivity = Date() }
}

@Sendable func hold(_ fanID: String, rpm: Int) {
    stateQueue.sync { holdState.hold(fanID, rpm: rpm) }
}

@Sendable func holdCurve(_ fanID: String, sensorId: String, points: [CurvePoint],
                         smoothingSeconds: Double) {
    stateQueue.sync {
        holdState.holdCurve(fanID, sensorId: sensorId, points: points,
                            smoothingSeconds: smoothingSeconds)
    }
}

@Sendable func release(_ fanID: String) {
    stateQueue.sync { holdState.release(fanID) }
}

/// EVERY AppleSMCService touch is serialized on this one queue. The accept
/// loop (requests), the 1 Hz reassert/curve tick and the watchdog's reverts
/// all drive the same mutable service; before this queue they hit it from
/// three different threads at once, and the unlock dance mid-write with a
/// snapshot mid-read is exactly the torn state that could mis-target a fan.
/// The 1 Hz timer runs ON this queue; everyone else hops on with `sync`.
let smcQueue = DispatchQueue(label: "dev.example.pultik.fan-helper.smc")

/// Revert fans to auto. Best-effort.
///
/// `fanIDs` is the caller's decision, and that distinction is the whole of
/// protocol v9's lifecycle rule: SIGTERM passes everything (the daemon is
/// going away, nothing will be left driving), while the idle watchdog passes
/// only the fixed holds — a curve keeps tracking temperature after pultik
/// quits, which is the point of it.
func revertFans(_ fanIDs: some Collection<String>, reason: String) {
    guard !fanIDs.isEmpty else { return }
    smcQueue.sync { revertFansOnSMCQueue(fanIDs, reason: reason) }
}

/// The body of `revertFans`, for callers already ON `smcQueue` (the curve
/// tick) — a `sync` hop from there would trap on re-entrancy.
func revertFansOnSMCQueue(_ fanIDs: some Collection<String>, reason: String) {
    guard !fanIDs.isEmpty else { return }
    log("revertFans: \(reason) — reverting \(fanIDs.sorted())")
    for fanID in fanIDs {
        let ok = smc.setMode(.auto, for: fanID)
        log("  revert \(fanID) -> \(ok ? "AUTO" : "FAILED")")
        if ok { release(fanID) }
    }
}

/// Everything this helper is driving, by either mechanism.
func revertAllDrivenFans(reason: String) {
    revertFans(stateQueue.sync { holdState.allDrivenFanIDs }, reason: reason)
}

// MARK: - Re-assertion timer (defeats thermalmonitord claw-back)

/// Every 1s, re-push each held fan's target. setMode(.constant) re-does
/// the unlock fast-path (cheap once already unlocked) + the F{i}Tg write,
/// so the physical fan stays where the user pinned it even as the
/// firmware tries to claw F{i}Tg back. No IPC — this is all in-process
/// root SMC writes.
///
/// The same tick drives temperature CURVES (protocol v9). The helper is
/// the only process that can both read sensors and write fans without
/// asking anyone, so the whole loop closes in here: read the die temp,
/// interpolate the user's ramp, write the rpm. The app sends `.setCurve`
/// once and is then free to close its panel, or exit entirely.
/// The timer runs directly on `smcQueue` — its whole body is SMC traffic,
/// and putting it anywhere else would just be a second thread to serialize.
let reassertTimer = DispatchSource.makeTimerSource(queue: smcQueue)

/// Temperature filters, keyed by driving sensor (protocol v10). Touched only
/// from `smcQueue` — the timer handler is the sole reader and writer, so
/// no lock. Cleared whenever no curve is running, so a curve applied an hour
/// later seeds from today's die temperature instead of a stale one.
var smoothers: [String: TempSmoother] = [:]
var lastCurveTick: Date?

reassertTimer.schedule(deadline: .now() + 1, repeating: 1)
reassertTimer.setEventHandler {
    let (targets, curves) = stateQueue.sync {
        (holdState.reassertTargets, holdState.curves)
    }
    for (fanID, rpm) in targets {
        _ = smc.setMode(.constant(rpm: rpm), for: fanID)
    }
    guard !curves.isEmpty else {
        smoothers.removeAll()
        lastCurveTick = nil
        return
    }

    // A full sensor sweep costs real SMC round-trips, so it only happens
    // when a curve is actually asking for one — a plain pinned fan pays
    // nothing for this branch.
    smc.refresh()
    let (fans, sensors) = smc.snapshot()

    // Real elapsed time, not the nominal 1 s: the timer slips under load and
    // during sleep/wake, and a filter fed the wrong dt lags by that much.
    let now = Date()
    let dt = lastCurveTick.map { now.timeIntervalSince($0) } ?? 0
    lastCurveTick = now

    // Filter ONCE PER SENSOR PER TICK, before the fan loop — not inside it.
    // Both fans read the same die, and stepping the same filter once per fan
    // would advance it at twice the real rate and hand the second fan a
    // different temperature than the first.
    var driving: [String: Double] = [:]
    for hold in curves.values where driving[hold.sensorId] == nil {
        guard let sensor = sensors.first(where: { $0.id == hold.sensorId }) else { continue }
        var smoother = smoothers[hold.sensorId] ?? TempSmoother(tau: hold.smoothingSeconds)
        smoother.tau = hold.smoothingSeconds
        driving[hold.sensorId] = smoother.update(raw: sensor.celsius, dt: dt)
        smoothers[hold.sensorId] = smoother
    }
    // Drop filters for sensors nothing is driven by any more, so their state
    // can't come back stale if a curve on that sensor is applied again later.
    smoothers = smoothers.filter { driving[$0.key] != nil }

    for (fanID, curveHold) in curves {
        guard let fan = fans.first(where: { $0.id == fanID }) else { continue }
        guard let temp = driving[curveHold.sensorId] else {
            // The driving sensor vanished. A curve with nothing observing
            // temperature is an unlocked fan at a stale target — strictly
            // worse than letting the firmware have it back.
            log("curve \(fanID): sensor '\(curveHold.sensorId)' missing — reverting to AUTO")
            revertFansOnSMCQueue([fanID], reason: "curve sensor missing")
            continue
        }
        let curve = FanCurve(id: "active", name: "active", points: curveHold.points)
        let rpm = curve.rpm(at: temp, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
        _ = smc.setMode(.constant(rpm: rpm), for: fanID)
    }
}
reassertTimer.resume()

// MARK: - Signal cleanup

// `signal(_:_:)` with a Swift closure that captures globals can't be
// formed into a C function pointer, and a signal handler doing real
// Swift work isn't async-signal-safe anyway. Use DispatchSourceSignal
// instead: ignore the signal at the libc layer (so default-terminate
// behavior doesn't fire), then the dispatch source delivers it as a
// normal queue event where we can safely call Swift, log, and revert.
//
// Don't trap SIGKILL — kernel doesn't deliver it; that's the failure
// mode the next helper boot's safeResetAllFansToAuto defends against.
// Background queue — main thread is pinned in the blocking accept() loop,
// so a main-queue signal source would never fire.
let signalQueue = DispatchQueue(label: "dev.example.pultik.fan-helper.signals")
func installSignalCleanup(_ sig: Int32, name: String) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        // Everything, curves included — after this process there is nothing
        // left to track temperature, so a curve is just a stranded pin.
        revertAllDrivenFans(reason: name)
        unlink(HelperConstants.socketPath)
        _exit(0)
    }
    src.resume()
    return src
}
let sigterm = installSignalCleanup(SIGTERM, name: "SIGTERM")
let sigint  = installSignalCleanup(SIGINT,  name: "SIGINT")
_ = sigterm; _ = sigint   // retain past end of statement

// MARK: - Idle watchdog

/// Tick every 10s. If we're holding locks AND no client has talked to
/// us in >IDLE_REVERT_SECONDS, the app is presumed dead — revert. This
/// is the safety net for a crashed unprivileged process; the SIGTERM
/// path covers ordered shutdown.
///
/// CURVED FANS ARE EXEMPT (protocol v9, decision D2). The watchdog exists
/// because a fixed rpm has no feedback: nobody is watching the temperature,
/// so a dead controller leaves the fan wrong forever. A curve is the
/// opposite — it reads the die every second and backs off on its own, so
/// "the app went away" is not a hazard, it is the expected steady state.
/// Reverting it would mean the cooling you asked for stops the moment you
/// quit pultik, which is exactly what moving the loop in here was for.
///
/// IMPORTANT: the timer source runs on a DEDICATED queue, NOT stateQueue.
/// If it ran on stateQueue, the handler would already be on stateQueue
/// when it tries `stateQueue.sync { ... }` to peek at the held targets —
/// libdispatch detects the re-entrant dispatch_sync and traps with
/// "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already
/// owned by current thread", crashing the helper every IDLE_REVERT
/// interval.
let IDLE_REVERT_SECONDS: TimeInterval = 60
let watchdogQueue = DispatchQueue(label: "dev.example.pultik.fan-helper.watchdog")
let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    let (targets, last) = stateQueue.sync { (holdState.reassertTargets, lastActivity) }
    guard !targets.isEmpty else { return }
    let now = Date()
    // shouldRevertIdle is pure (uses only its parameters, not self state),
    // so calling it on a throw-away instance is correct and avoids touching
    // holdState from outside stateQueue.
    if HelperHoldState().shouldRevertIdle(lastActivity: last,
                                          now: now,
                                          threshold: IDLE_REVERT_SECONDS) {
        let idle = now.timeIntervalSince(last)
        // Do the revert OUTSIDE stateQueue.sync — setMode can take
        // seconds (Ftst unlock dance). The watchdog timer fires every
        // 10s and would otherwise pile up.
        DispatchQueue.global(qos: .userInitiated).async {
            revertFans(targets.keys,
                       reason: "idle \(Int(idle))s > \(Int(IDLE_REVERT_SECONDS))s")
        }
    }
}
watchdog.resume()

// MARK: - Per-request processing

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func process(_ req: HelperRequest) -> HelperResponse {
    recordActivity()
    switch req {
    case .ping:
        let (curved, held) = stateQueue.sync {
            (Array(holdState.curves.keys), Array(holdState.reassertTargets.keys))
        }
        return HelperResponse(ok: true,
                              backendName: smc.backendName,
                              protocolVersion: HelperConstants.protocolVersion,
                              curvedFanIDs: curved,
                              heldFanIDs: held)
    case .setAuto(let fanID):
        // Stop holding FIRST so the re-assertion timer can't re-pin it
        // between our setMode(.auto) and the next tick — but remember what
        // was held: a rejected AUTO write must not strand an untracked fan
        // at its last target, invisible to the reassert loop, the watchdog
        // and the SIGTERM cleanup.
        let (savedRPM, savedCurve) = stateQueue.sync {
            (holdState.reassertTargets[fanID], holdState.curves[fanID])
        }
        release(fanID)
        let ok = smcQueue.sync { smc.setMode(.auto, for: fanID) }
        if !ok {
            if let savedCurve {
                holdCurve(fanID, sensorId: savedCurve.sensorId,
                          points: savedCurve.points,
                          smoothingSeconds: savedCurve.smoothingSeconds)
            } else if let savedRPM {
                hold(fanID, rpm: savedRPM)
            }
        }
        log("setAuto \(fanID) -> \(ok) (\(ok ? "released hold" : "AUTO rejected — hold kept"))")
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    case .setConstant(let fanID, let rpm):
        let ok = smcQueue.sync { smc.setMode(.constant(rpm: rpm), for: fanID) }
        // Register the hold even if this one write was rejected — the
        // re-assertion timer will keep retrying, and a transient reject
        // (firmware busy) shouldn't drop the user's intent.
        if ok { hold(fanID, rpm: rpm) }
        log("setConstant \(fanID) \(rpm) -> \(ok) (holding)")
        return HelperResponse(ok: ok, error: ok ? nil : "SMC write rejected")
    case .setCurve(let fanID, let sensorId, let points, let smoothingSeconds):
        guard points.count >= 2 else {
            return HelperResponse(ok: false, error: "curve needs at least 2 points")
        }
        // Re-guard on THIS side of the socket too. The app guards on every
        // edit, but the app is not the only thing that can open this socket —
        // anything running as the console user can, and a descending ramp is
        // the one payload here that could actually cook something.
        let curve = FanCurve(id: "wire", name: "wire", points: points).guarded()
        // One smcQueue block for the whole refresh→snapshot→seed-write: the
        // 1 Hz tick must never interleave with a half-done curve apply.
        enum SeedResult {
            case ok(rpm: Int, celsius: Double)
            case rejected(rpm: Int, celsius: Double)
            case unknownFan, unknownSensor
        }
        let seed: SeedResult = smcQueue.sync {
            smc.refresh()
            let (fans, sensors) = smc.snapshot()
            guard let fan = fans.first(where: { $0.id == fanID }) else { return .unknownFan }
            guard let sensor = sensors.first(where: { $0.id == sensorId }) else { return .unknownSensor }
            // Seed at the curve's value for the temperature RIGHT NOW, so the
            // fan is correct within this request rather than a tick later.
            let rpm = curve.rpm(at: sensor.celsius, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
            return smc.setMode(.constant(rpm: rpm), for: fanID)
                ? .ok(rpm: rpm, celsius: sensor.celsius)
                : .rejected(rpm: rpm, celsius: sensor.celsius)
        }
        switch seed {
        case .unknownFan:
            return HelperResponse(ok: false, error: "unknown fan \(fanID)")
        case .unknownSensor:
            return HelperResponse(ok: false, error: "unknown sensor \(sensorId)")
        case .ok(let rpm, let celsius):
            holdCurve(fanID, sensorId: sensorId, points: curve.points,
                      smoothingSeconds: smoothingSeconds)
            log("setCurve \(fanID) sensor=\(sensorId) \(String(format: "%.1f", celsius))°C"
                + " -> \(rpm) rpm true (curving, \(curve.points.count) pts,"
                + " smoothing \(Int(smoothingSeconds))s)")
            return HelperResponse(ok: true)
        case .rejected(let rpm, let celsius):
            log("setCurve \(fanID) sensor=\(sensorId) \(String(format: "%.1f", celsius))°C"
                + " -> \(rpm) rpm false (rejected)")
            return HelperResponse(ok: false, error: "SMC write rejected")
        }
    }
}

/// Resolve the console user (the one logged in at the GUI). Falls back
/// to the SCDynamicStore copy; if that's empty, allow only root. This
/// is the standard macOS pattern for "is the request coming from the
/// person sitting at the screen" — the un-signed-dev replacement for
/// SMAppService + connection auditing.
func consoleUserUID() -> uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    if let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? {
        if !user.isEmpty && user != "loginwindow" { return uid }
    }
    return nil
}

func handle(client fd: Int32) {
    // Snap timeouts on every accepted fd — a malicious or stuck client
    // can't pin the helper indefinitely. 5s covers a worst-case Ftst
    // dance with comfortable headroom.
    UnixSocket.setTimeouts(fd, seconds: 5)

    // Cred check FIRST. Reject anything that isn't root or the console
    // user before reading a single byte.
    if let peer = UnixSocket.peerEUID(fd) {
        if !HelperPeerAuth.isAuthorized(uid: peer.uid, consoleUID: consoleUserUID()) {
            log("REJECT connection from euid=\(peer.uid) egid=\(peer.gid) — not root or console user")
            // Still write a response so the (hostile) caller doesn't
            // see EOF and silently retry — they get an explicit "no".
            if let payload = try? encoder.encode(
                HelperResponse(ok: false, error: "unauthorized peer")) {
                _ = try? UnixSocket.writeLine(fd, payload: payload)
            }
            return
        }
    } else {
        log("REJECT connection — getpeereid failed (errno=\(errno))")
        return
    }

    let response: HelperResponse
    do {
        let raw = try UnixSocket.readLine(fd)
        let req = try decoder.decode(HelperRequest.self, from: raw)
        response = process(req)
    } catch {
        response = HelperResponse(ok: false, error: "\(error)")
    }
    do {
        let payload = try encoder.encode(response)
        try UnixSocket.writeLine(fd, payload: payload)
    } catch {
        log("response write failed: \(error)")
    }
}

while true {
    let client = accept(listenFD, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        log("accept(): \(String(cString: strerror(errno)))")
        continue
    }
    handle(client: client)
    close(client)
}
