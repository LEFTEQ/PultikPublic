// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/SMC/MockSMCService.swift) — do not hand-drift; re-vendor on upstream change.
//
//  MockSMCService.swift
//  GenesisFanControl
//
//  Synthetic SMC backend that returns plausible Macbook Pro readings
//  so the entire UI works end-to-end without root / SMC entitlements.
//  Temperatures drift on a sine wave; RPM follows the active fan mode.
//

import Foundation

public final class MockSMCService: SMCService, @unchecked Sendable {
    public let backendName = "MockSMC"
    public let isSimulated = true

    private var fans: [Fan]
    private var sensors: [TempSensor]
    private var tick: Int = 0

    public init() {
        self.fans = [
            Fan(id: "F0", name: "Left side", minRPM: 1200, maxRPM: 5800,
                currentRPM: 1900, targetRPM: 1900, mode: .auto),
            Fan(id: "F1", name: "Right side", minRPM: 1200, maxRPM: 5800,
                currentRPM: 2000, targetRPM: 2000, mode: .auto),
        ]
        self.sensors = MockSMCService.makeSensors()
        Log.smc.info("MockSMC initialised: \(fans.count) fans, \(sensors.count) sensors")
    }

    public func snapshot() -> (fans: [Fan], sensors: [TempSensor]) {
        return (fans, sensors)
    }

    public func refresh() {
        tick &+= 1

        // Drift sensor temperatures on a slow sine + per-sensor offset
        for i in sensors.indices {
            let base = sensors[i].kind.baselineCelsius
            let phase = Double(tick) / 30.0 + Double(i) * 0.4
            let noise = sin(phase) * 4.0 + Double.random(in: -0.4...0.4)
            sensors[i].celsius = max(20, min(95, base + noise))
        }

        // Drive fan RPMs from the active mode
        for i in fans.indices {
            let f = fans[i]
            switch f.mode {
            case .auto:
                // Auto policy: average all CPU + GPU temps, lerp to RPM
                let drivers = sensors.filter { $0.kind == .cpu || $0.kind == .gpu }
                let avg = drivers.isEmpty ? 50.0 : drivers.map { $0.celsius }.reduce(0, +) / Double(drivers.count)
                let target = rpmForTemp(avg, fan: f, points: [
                    RampPoint(tempC: 45, rpm: f.minRPM),
                    RampPoint(tempC: 85, rpm: f.maxRPM),
                ])
                stepRPM(at: i, toward: target)
            case .constant(let rpm):
                fans[i].targetRPM = clampToFan(rpm, fan: f)
                stepRPM(at: i, toward: fans[i].targetRPM)
            case .sensorBased(let sensorId, let pts):
                guard let temp = sensors.first(where: { $0.id == sensorId })?.celsius else { continue }
                let target = rpmForTemp(temp, fan: f, points: pts)
                fans[i].targetRPM = target
                stepRPM(at: i, toward: target)
            }
        }
    }

    @discardableResult
    public func setMode(_ mode: FanMode, for fanID: String) -> Bool {
        guard let i = fans.firstIndex(where: { $0.id == fanID }) else { return false }
        fans[i].mode = mode
        switch mode {
        case .auto:
            Log.fans.info("Fan \(fanID) (\(fans[i].name)) -> AUTO")
        case .constant(let rpm):
            let clamped = clampToFan(rpm, fan: fans[i])
            fans[i].targetRPM = clamped
            fans[i].currentRPM = clamped
            Log.fans.info("Fan \(fanID) (\(fans[i].name)) -> CONSTANT \(clamped) RPM")
        case .sensorBased(let sensorId, let pts):
            let summary = pts.map { "\(Int($0.tempC))°→\($0.rpm)" }.joined(separator: ", ")
            Log.fans.info("Fan \(fanID) (\(fans[i].name)) -> SENSOR \(sensorId) [\(summary)]")
        }
        return true
    }

    // MARK: - Helpers

    private func clampToFan(_ rpm: Int, fan: Fan) -> Int {
        return max(fan.minRPM, min(fan.maxRPM, rpm))
    }

    /// Piecewise-linear interpolation matching AppleSMCService.rpmForTemp.
    private func rpmForTemp(_ tempC: Double, fan: Fan, points: [RampPoint]) -> Int {
        let sorted = points.sorted(by: { $0.tempC < $1.tempC })
        guard let first = sorted.first else { return fan.minRPM }
        guard sorted.count >= 2 else { return clampToFan(first.rpm, fan: fan) }
        if tempC <= first.tempC { return clampToFan(first.rpm, fan: fan) }
        if tempC >= sorted.last!.tempC { return clampToFan(sorted.last!.rpm, fan: fan) }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            if tempC >= a.tempC && tempC <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return clampToFan(a.rpm, fan: fan) }
                let t = (tempC - a.tempC) / span
                return clampToFan(Int((Double(a.rpm) + t * Double(b.rpm - a.rpm)).rounded()), fan: fan)
            }
        }
        return clampToFan(sorted.last!.rpm, fan: fan)
    }

    private func stepRPM(at i: Int, toward target: Int) {
        // Auto / sensor mode: cover the full range in ~2 ticks so the bar
        // reaches the requested speed within a couple of seconds.
        let current = fans[i].currentRPM
        let delta = target - current
        let step = max(200, min(3000, abs(delta)))
        if abs(delta) <= step {
            fans[i].currentRPM = target
        } else {
            fans[i].currentRPM = current + (delta > 0 ? step : -step)
        }
    }

    // MARK: - Fake hardware inventory

    private static func makeSensors() -> [TempSensor] {
        var s: [TempSensor] = []
        s.append(TempSensor(id: "TW0P", name: "Airport Proximity", kind: .airport, celsius: 38))
        s.append(TempSensor(id: "TB0T", name: "Battery", kind: .battery, celsius: 34))
        s.append(TempSensor(id: "TB1T", name: "Battery Gas Gauge", kind: .battery, celsius: 34))
        s.append(TempSensor(id: "TC0E", name: "CPU Core Average", kind: .cpu, celsius: 52))
        for i in 1...4 { s.append(TempSensor(id: "TC\(i)e", name: "CPU Efficiency Core \(i)", kind: .cpu, celsius: 50)) }
        for i in 1...12 { s.append(TempSensor(id: "TC\(i)p", name: "CPU Performance Core \(i)", kind: .cpu, celsius: 55)) }
        for i in 1...5 { s.append(TempSensor(id: "TG\(i)c", name: "GPU Cluster \(i)", kind: .gpu, celsius: 48)) }
        s.append(TempSensor(id: "TGAC", name: "GPU Cluster Average", kind: .gpu, celsius: 47))
        s.append(TempSensor(id: "TPDA", name: "Power Manager Die Average", kind: .power, celsius: 56))
        s.append(TempSensor(id: "TPSP", name: "Power Supply Proximity", kind: .power, celsius: 41))
        s.append(TempSensor(id: "TTLD", name: "Thunderbolt Left Proximity", kind: .thunderbolt, celsius: 36))
        s.append(TempSensor(id: "TTRD", name: "Thunderbolt Right Proximity", kind: .thunderbolt, celsius: 37))
        s.append(TempSensor(id: "TTPD", name: "Trackpad", kind: .trackpad, celsius: 30))
        s.append(TempSensor(id: "TTAD", name: "Trackpad Actuator", kind: .trackpad, celsius: 31))
        s.append(TempSensor(id: "TANP", name: "APPLE SSD AP1024Z", kind: .storage, celsius: 42))
        return s
    }
}

private extension SensorKind {
    /// Reasonable baseline temperature in °C for the sine drift.
    var baselineCelsius: Double {
        switch self {
        case .cpu: return 55
        case .gpu: return 50
        case .battery: return 34
        case .storage: return 42
        case .airport: return 38
        case .thunderbolt: return 37
        case .proximity: return 38
        case .power: return 50
        case .trackpad: return 30
        case .other: return 40
        }
    }
}
