//
//  FanCurve.swift
//  Pultik — NOT vendored. This is pultik's own type (decisions 2026-08-02).
//
//  A fan curve maps die temperature to a fraction of each fan's own
//  min…max range. Percent, not RPM, is the unit on purpose: fans carry
//  different envelopes, and the deck drives them in lockstep, so one
//  curve has to mean the same thing on a 1200–4600 fan and a 1300–5000
//  one (fan-deck D2).
//
//  Compiled into BOTH targets — the app draws the curve, the helper
//  evaluates it at 1 Hz as root. One definition, no drift.
//

import Foundation

// MARK: - Point

/// One vertex of a curve. `pct` is 0…1 of the fan's own range.
///
/// Deliberately not `RampPoint` (which is temp → absolute rpm, the
/// vendored `.sensorBased` unit): mixing the two units in one type is
/// how you end up sending 45 rpm to a fan because someone meant 45%.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var tempC: Double
    public var pct: Double

    public init(tempC: Double, pct: Double) {
        self.tempC = tempC
        self.pct = pct
    }
}

// MARK: - Curve

public struct FanCurve: Codable, Hashable, Sendable, Identifiable {
    /// Stable key — persisted in settings.json and sent on the wire.
    public var id: String
    public var name: String
    /// Sorted by `tempC`. Below the first point the first pct is held;
    /// above the last, the last pct is held.
    public var points: [CurvePoint]

    public init(id: String, name: String, points: [CurvePoint]) {
        self.id = id
        self.name = name
        self.points = points
    }

    // MARK: Evaluation

    /// Fraction of range this curve asks for at `tempC`. Piecewise-linear
    /// between points, flat outside them.
    public func pct(at tempC: Double) -> Double {
        let sorted = points.sorted { $0.tempC < $1.tempC }
        guard let first = sorted.first else { return 0 }
        guard let last = sorted.last, sorted.count >= 2 else {
            return clamp01(first.pct)
        }
        if tempC <= first.tempC { return clamp01(first.pct) }
        if tempC >= last.tempC { return clamp01(last.pct) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard tempC >= a.tempC, tempC <= b.tempC else { continue }
            let span = b.tempC - a.tempC
            guard span > 0 else { return clamp01(a.pct) }
            let t = (tempC - a.tempC) / span
            return clamp01(a.pct + t * (b.pct - a.pct))
        }
        return clamp01(last.pct)
    }

    /// The RPM this curve asks of a fan with that envelope, clamped into it.
    public func rpm(at tempC: Double, minRPM: Int, maxRPM: Int) -> Int {
        guard maxRPM > minRPM else { return minRPM }
        let rpm = Double(minRPM) + pct(at: tempC) * Double(maxRPM - minRPM)
        return max(minRPM, min(maxRPM, Int(rpm.rounded())))
    }

    // MARK: Guards (decision D7)

    /// Temperature at or above which the fans are not allowed to idle.
    public static let floorTempC: Double = 90
    /// The floor itself — 60% of range is audible and moves real air.
    public static let floorPct: Double = 0.6

    /// Repair a curve into a legal shape: sorted, strictly increasing in
    /// temperature, never descending in percent, and never asking for less
    /// than `floorPct` once the die is at `floorTempC`.
    ///
    /// Applied on every edit and again before the curve goes on the wire —
    /// a hand-drawn curve that tells the fans to back off as things heat up
    /// is the one way this feature could actually cook something.
    public func guarded() -> FanCurve {
        var out: [CurvePoint] = []
        for var p in points.sorted(by: { $0.tempC < $1.tempC }) {
            p.pct = clamp01(p.pct)
            if let prev = out.last {
                // Strictly increasing temp: a duplicate x has no slope and
                // makes interpolation ambiguous. Nudge rather than drop, so
                // dragging a point past its neighbour doesn't delete it.
                if p.tempC <= prev.tempC { p.tempC = prev.tempC + 1 }
                p.pct = max(p.pct, prev.pct)
            }
            if p.tempC >= Self.floorTempC { p.pct = max(p.pct, Self.floorPct) }
            out.append(p)
        }
        // A curve whose last point sits below the floor temperature says
        // nothing about what happens at 95°C — hold the floor explicitly.
        if let last = out.last, last.tempC < Self.floorTempC {
            out.append(CurvePoint(tempC: Self.floorTempC,
                                  pct: max(last.pct, Self.floorPct)))
        }
        // Vertices straddling the floor with none AT it break the invariant
        // pointwise: (85, 0.0) → (95, 0.6) interpolates to 30% at 90°C. Pin
        // a vertex at the floor itself so every temperature ≥ floorTempC
        // reads ≥ floorPct, not just the vertices. Skipping is allowed ONLY
        // for a vertex at exactly floorTempC (which the loop above floored) —
        // any tolerance would let a fractional vertex just under 90°C, which
        // the loop did NOT floor, stand in for the floor point.
        if let nextIndex = out.firstIndex(where: { $0.tempC >= Self.floorTempC }),
           out[nextIndex].tempC > Self.floorTempC,
           nextIndex > 0 {
            let interp = FanCurve(id: id, name: name, points: out).pct(at: Self.floorTempC)
            out.insert(CurvePoint(tempC: Self.floorTempC,
                                  pct: max(interp, Self.floorPct)), at: nextIndex)
        }
        return FanCurve(id: id, name: name, points: out)
    }

    // MARK: Presets (decision D4)

    public static let quiet = FanCurve(id: "quiet", name: "Quiet", points: [
        CurvePoint(tempC: 45, pct: 0.00),
        CurvePoint(tempC: 70, pct: 0.15),
        CurvePoint(tempC: 80, pct: 0.30),
        CurvePoint(tempC: 85, pct: 0.45),
        CurvePoint(tempC: 95, pct: 1.00),
    ])

    public static let balanced = FanCurve(id: "balanced", name: "Balanced", points: [
        CurvePoint(tempC: 45, pct: 0.05),
        CurvePoint(tempC: 60, pct: 0.20),
        CurvePoint(tempC: 70, pct: 0.40),
        CurvePoint(tempC: 80, pct: 0.60),
        CurvePoint(tempC: 85, pct: 0.80),
        CurvePoint(tempC: 95, pct: 1.00),
    ])

    /// The one this feature was asked for: leads the heat instead of
    /// chasing it — already moving air at 45°C, flat out by 85°C.
    public static let aggressive = FanCurve(id: "aggressive", name: "Aggressive", points: [
        CurvePoint(tempC: 45, pct: 0.25),
        CurvePoint(tempC: 60, pct: 0.45),
        CurvePoint(tempC: 70, pct: 0.70),
        CurvePoint(tempC: 80, pct: 0.90),
        CurvePoint(tempC: 85, pct: 1.00),
    ])

    public static let presets: [FanCurve] = [quiet, balanced, aggressive]

    public static func preset(_ id: String) -> FanCurve? {
        presets.first { $0.id == id }
    }

    /// The sensor every curve is driven by (decision D3) — see
    /// `AppleSMCService.virtualSensors`.
    public static let defaultSensorID = "__hottest"
}

// MARK: - Smoothing

/// Low-pass filter on the temperature a curve is driven by, so a brief spike
/// doesn't spin the fans up.
///
/// A five-second jump to 80°C is a build finishing, not a Mac in trouble: the
/// die is back down long before moving more air would have changed anything,
/// so chasing it is pure noise — which is the entire complaint.
///
/// The INPUT is smoothed, not the output. Rate-limiting the RPM would make the
/// curve mean something different from what it draws; smoothing the reading
/// keeps 70°C mapping to exactly 70°C's percent — it just takes a sustained
/// 70°C to get there. What the chart shows stays true.
public struct TempSmoother: Sendable {
    /// Seconds to cover ~63% of a step change. 0 disables filtering entirely.
    public var tau: Double
    /// nil until the first sample — a smoother is seeded by its first reading,
    /// never by a guess, so applying a curve doesn't start from a fiction.
    private var value: Double?

    public init(tau: Double) {
        self.tau = tau
    }

    /// Above this the raw reading wins immediately. Smoothing is a comfort
    /// feature and must never stand between a genuinely hot die and the fans.
    public static let bypassTempC: Double = FanCurve.floorTempC

    /// Feed one reading, get back the temperature the curve should be
    /// evaluated at. `dt` is seconds since the previous call.
    public mutating func update(raw: Double, dt: Double) -> Double {
        guard tau > 0, dt > 0, let previous = value else {
            value = raw
            return raw
        }
        let alpha = 1 - exp(-dt / tau)
        var next = previous + alpha * (raw - previous)
        // One-directional bypass: snap UP to a dangerous reading at once, but
        // never snap down. Getting out of the hot zone stays smoothed, so a
        // die hovering around 90°C can't make the fans oscillate.
        if raw >= Self.bypassTempC { next = max(next, raw) }
        value = next
        return next
    }

    /// The options offered in Settings. Seconds, because that is the thing
    /// being chosen — a spike shorter than this barely moves the fans.
    public static let choices: [(seconds: Double, label: String)] = [
        (0, "Off"), (15, "15 s"), (30, "30 s"), (60, "60 s"),
    ]

    /// Long enough to ignore a compile or a Spotlight reindex, short enough
    /// that real sustained load still gets air within half a minute.
    public static let defaultSeconds: Double = 30
}

@inline(__always)
private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
