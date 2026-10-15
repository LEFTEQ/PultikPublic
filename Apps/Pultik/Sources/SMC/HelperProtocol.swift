// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/Privileged/HelperProtocol.swift).
// DIVERGED ON PURPOSE (2026-08-01): pultik ships and installs its OWN daemon,
// so every identity constant below is pultik's. The wire format is untouched —
// re-vendor the types from upstream, never the paths.
//
//  HelperProtocol.swift
//
//  Wire types shared by the unprivileged app and the privileged helper
//  daemon. Plain JSON over a Unix domain socket — one request per line,
//  one response per line. Codable on both ends.
//

import Foundation

public enum HelperConstants {
    /// Unix domain socket the helper binds and the client connects to.
    public static let socketPath = "/var/run/pultik-fan-control.sock"
    /// Where the privileged binary lives once installed.
    public static let installedHelperPath = "/usr/local/sbin/pultik-fan-control-helper"
    /// launchd label + plist path.
    public static let helperLabel = "dev.example.pultik.fan-helper"
    public static let launchDaemonPath = "/Library/LaunchDaemons/dev.example.pultik.fan-helper.plist"
    /// Filename of the helper binary as embedded in Pultik.app/Contents/MacOS.
    public static let helperBinaryName = "pultik-fan-control-helper"
    public static let logPath = "/var/log/pultik-fan-control-helper.log"
    public static let errorLogPath = "/var/log/pultik-fan-control-helper.err.log"

    /// The GenesisFanControl-era daemon pultik replaces. Two root SMC writers
    /// with independent 1 Hz re-assertion loops would fight over setpoints, so
    /// installing ours sweeps this one — the same way GenesisFanControl swept
    /// up its own MacsFanControl-era predecessor.
    public enum Legacy {
        public static let label = "dev.example.legacy-fan-control.helper"
        public static let launchDaemonPath = "/Library/LaunchDaemons/dev.example.legacy-fan-control.helper.plist"
        public static let installedHelperPath = "/usr/local/sbin/genesis-fan-control-helper"
        public static let socketPath = "/var/run/genesis-fan-control.sock"
    }
    /// Bumped whenever the helper's behavior changes in a way the GUI
    /// needs to know about — even bug-fix-only changes (like the AUTO
    /// unlock order inversion). When this constant differs from what
    /// the installed helper returns, HelperClient.health() reports
    /// `.outdated` and the GUI raises the elevation banner so the user
    /// can re-install. Bump on every helper-side fix.
    ///
    /// v3 (2026-06-30): cred-check on accept, 0660 socket, locked-fan
    /// tracking + SIGTERM revert, idle watchdog. Old v2 helper has no
    /// safety net for a crashed GUI; everyone should upgrade.
    /// v4 (2026-06-30): canonical AUTO release — drop F0Md=0 readback
    /// retry (mode 0 is transient on AS, never stably reads back),
    /// classify md==3 as auto (firmware-System resting state), settle
    /// window after release. The old helper still does the readback
    /// retry which fails on every M-series Mac — must upgrade.
    /// v5 (2026-06-30): fix re-entrant dispatch_sync deadlock in the
    /// watchdog timer — the source was scheduled on stateQueue and its
    /// handler called stateQueue.sync, crashing libdispatch every ~60s.
    /// Watchdog now has its own dedicated queue.
    /// v6 (2026-06-30): pass `forceSafeReset: false` to the helper's own
    /// AppleSMCService. The old v5 helper called safeResetAllFansToAuto
    /// on every respawn (KeepAlive=true), silently wiping the user's
    /// pinned CONSTANT back to AUTO whenever launchd restarted it —
    /// manifesting in the GUI as the "constant speed jumping around"
    /// bug. v6 helpers leave user state alone on respawn.
    /// v7 (2026-06-30): the cached-.constant preservation branch in
    /// primeSnapshot was held regardless of SMC md value — so once a
    /// fan was set to CONSTANT, setMode(.auto) could never take effect
    /// (the per-tick reassertion would immediately re-push CONSTANT,
    /// and thermalmonitord, locked out, would let temperatures crash
    /// to ~1°C as feedback loops broke). v7 gates the cache hold on
    /// md == 1; firmware reclaim to md=3 now correctly flips us back
    /// to .auto. EMERGENCY upgrade.
    /// v8 (2026-06-30): ARCHITECTURE FIX. The helper now OWNS the hold:
    /// it tracks heldTargets and re-asserts CONSTANT on its own 1 Hz
    /// timer (root, persistent). The unprivileged GUI no longer
    /// re-asserts (it can't write SMC at all) — it set-once and the
    /// helper holds. This fixes AUTO (no GUI re-assertion fighting the
    /// release), constant-not-holding-via-CLI, and the 1 Hz socket
    /// spam / Ftst-bounce. The v7 helper has no re-assertion timer and
    /// would let CONSTANT drift; must upgrade.
    ///
    /// Still 8 after the 2026-08-01 rename: the daemon's behavior and wire
    /// format are byte-identical, only its name and paths moved. Nothing but
    /// pultik's own helper can answer pultik's socket now, so this only ever
    /// catches an app updated past a stale installed helper.
    ///
    /// v9 (2026-08-02): THE HELPER OWNS THE CURVE. New `.setCurve` request —
    /// the daemon reads the driving sensor on its own 1 Hz timer, interpolates
    /// the user's ramp and writes the resulting RPM as root. A curved fan is
    /// also EXEMPT from the idle watchdog: a curve tracks temperature and backs
    /// off on its own, unlike a pinned RPM with no feedback, so it is allowed
    /// to keep running after pultik quits. A v8 helper doesn't know `.setCurve`
    /// and answers it as a decode failure — must upgrade.
    ///
    /// v10 (2026-08-02): `.setCurve` carries `smoothingSeconds`. The daemon
    /// low-passes the driving temperature before interpolating, so a brief
    /// spike no longer spins the fans up; readings at or above
    /// `TempSmoother.bypassTempC` bypass the filter upward. A v9 helper
    /// ignores the field and reacts to every spike — upgrade for quiet, not
    /// for safety.
    /// v11 (2026-08-20): `.ping` reports `curvedFanIDs`/`heldFanIDs` so the
    /// app's crash-safe sweep can tell an orphaned pin from a helper-owned
    /// fan. The bump matters for SAFETY: a v9/v10 helper holds curves but
    /// cannot report them, so the app must treat its ownership as unknown
    /// (and skip the sweep) rather than sweep a curve it can't see.
    public static let protocolVersion = 11
}

public enum HelperRequest: Codable {
    case ping
    case setAuto(fanID: String)
    case setConstant(fanID: String, rpm: Int)
    /// Hand the fan to a temperature curve. The helper resolves `sensorId`
    /// against its own snapshot every tick, so the app sends this ONCE and
    /// then goes quiet — including all the way through its own termination.
    /// `.setAuto` is what clears it.
    /// `smoothingSeconds` is the `TempSmoother` time constant; 0 means react
    /// to every reading. Decoded with a default so a client that predates it
    /// still parses (the version check catches the mismatch anyway).
    case setCurve(fanID: String, sensorId: String, points: [CurvePoint],
                  smoothingSeconds: Double)
}

public struct HelperResponse: Codable {
    public let ok: Bool
    public let error: String?
    public let backendName: String?
    public let protocolVersion: Int?
    /// Fans the helper is driving, by mechanism — filled on `.ping` so the
    /// app's crash-safe sweep can tell an orphaned pin (reset it) from a
    /// helper-owned fan (leave it alone). Optional on the wire: absent from
    /// a pre-v11 helper — which CAN be holding curves it cannot report, so
    /// absence means "ownership unknown, do not sweep", never "owns nothing".
    public let curvedFanIDs: [String]?
    public let heldFanIDs: [String]?

    public init(ok: Bool, error: String? = nil, backendName: String? = nil,
                protocolVersion: Int? = nil,
                curvedFanIDs: [String]? = nil, heldFanIDs: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.backendName = backendName
        self.protocolVersion = protocolVersion
        self.curvedFanIDs = curvedFanIDs
        self.heldFanIDs = heldFanIDs
    }
}
