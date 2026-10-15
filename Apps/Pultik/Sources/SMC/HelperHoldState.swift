// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/Privileged/HelperHoldState.swift).
// DIVERGED ON PURPOSE (2026-08-02): `curves` + `holdCurve` are pultik's
// protocol-v9 addition (helper-owned temperature curves) and have no upstream
// counterpart. Re-vendor the hold/release/idle logic; keep the curve state.
//
//  HelperHoldState.swift
//
//  Pure hold/release state transitions for the privileged helper.
//  Threading (stateQueue.sync gating), DispatchSourceTimer (1 Hz
//  re-assertion), and the watchdog DispatchSourceTimer STAY in
//  the daemon's main.swift so performance characteristics are unchanged.
//  Only the pure dictionary mutations and idle/auth decisions live here.
//

import Foundation
#if canImport(Darwin)
import Darwin   // uid_t
#endif

// MARK: - HelperHoldState

/// Value-type store of fanID → target RPM. The helper's stateQueue
/// serialises all mutations; only the pure state transitions live here.
public struct HelperHoldState: Sendable {
    public private(set) var reassertTargets: [String: Int] = [:]

    /// Fans handed to a temperature curve (protocol v9). Separate from
    /// `reassertTargets` because the two are re-asserted differently — a
    /// held fan gets its fixed rpm re-pushed, a curved fan gets a freshly
    /// interpolated one — and because only these are watchdog-exempt.
    public private(set) var curves: [String: FanCurveHold] = [:]

    public struct FanCurveHold: Sendable, Hashable {
        public var sensorId: String
        public var points: [CurvePoint]
        /// `TempSmoother` time constant for this curve (protocol v10). The
        /// filter's running value is NOT here — it belongs to the tick loop,
        /// and this type stays a pure description of what was asked for.
        public var smoothingSeconds: Double

        public init(sensorId: String, points: [CurvePoint], smoothingSeconds: Double) {
            self.sensorId = sensorId
            self.points = points
            self.smoothingSeconds = smoothingSeconds
        }
    }

    public init() {}

    /// Register or update a hold for `fanID` at `rpm`.
    ///
    /// A hold and a curve are mutually exclusive: the last writer wins, or
    /// the 1 Hz timer would push a fixed rpm and an interpolated one at the
    /// same fan in the same tick.
    public mutating func hold(_ fanID: String, rpm: Int) {
        curves.removeValue(forKey: fanID)
        reassertTargets[fanID] = rpm
    }

    /// Hand `fanID` to a curve, dropping any fixed hold it had.
    public mutating func holdCurve(_ fanID: String, sensorId: String,
                                   points: [CurvePoint], smoothingSeconds: Double) {
        reassertTargets.removeValue(forKey: fanID)
        curves[fanID] = FanCurveHold(sensorId: sensorId, points: points,
                                     smoothingSeconds: smoothingSeconds)
    }

    /// Remove the hold AND the curve for `fanID`. No-op if neither is set.
    public mutating func release(_ fanID: String) {
        reassertTargets.removeValue(forKey: fanID)
        curves.removeValue(forKey: fanID)
    }

    /// Every fan this helper is driving, by either mechanism — what SIGTERM
    /// and shutdown have to revert.
    public var allDrivenFanIDs: Set<String> {
        Set(reassertTargets.keys).union(curves.keys)
    }

    /// True when `lastActivity` is more than `threshold` seconds before
    /// `now` — i.e. the app has been silent long enough to be presumed dead.
    public func shouldRevertIdle(lastActivity: Date, now: Date,
                                 threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(lastActivity) >= threshold
    }
}

// MARK: - HelperPeerAuth

public enum HelperPeerAuth {
    /// Allow root (uid 0) always; allow the active console user when their
    /// uid matches.
    public static func isAuthorized(uid: uid_t, consoleUID: uid_t?) -> Bool {
        if uid == 0 { return true }
        if let consoleUID, uid == consoleUID { return true }
        return false
    }
}
