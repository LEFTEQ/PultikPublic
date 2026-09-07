// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/Privileged/HelperClient.swift) — do not hand-drift; re-vendor on upstream change.
// DIVERGED ON PURPOSE (2026-08-20): protocol-v9 `setCurve` is pultik's, and
// privileged WRITES use a 45 s socket timeout — the cold Ftst unlock dance
// runs 3 s + up to 30 s of retries, and a 5 s receive timeout recorded a
// false failure while the helper went on to register the hold, leaving app
// and helper disagreeing about who owns the fan. Pings/health keep 5 s.
//
//  HelperClient.swift
//  GenesisFanControlCore
//
//  Tiny synchronous client for the privileged pultik-fan-control-helper.
//  Opens a Unix socket per call, writes a single JSON request, reads
//  a single JSON response, closes. Reconnecting per call keeps the
//  surface tiny and matches the once-per-fan-edit call frequency.
//

import Foundation
import Darwin

public final class HelperClient: @unchecked Sendable {
    private let socketPath: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String = HelperConstants.socketPath) {
        self.socketPath = socketPath
    }

    /// Helper liveness + protocol-compat result. Drives the elevation
    /// banner: `.down` and `.outdated` both raise it; only `.healthy`
    /// clears it.
    public enum Health: Equatable {
        case down                                  // socket unreachable
        case outdated(installed: Int, current: Int) // running but stale
        case healthy(version: Int)                 // running and matching
    }

    public func health() -> Health {
        guard let resp = try? send(.ping), resp.ok else { return .down }
        // Older helpers may not include protocolVersion in the response
        // (the field is Optional). Treat missing == 1.
        let installed = resp.protocolVersion ?? 1
        if installed == HelperConstants.protocolVersion {
            return .healthy(version: installed)
        }
        return .outdated(installed: installed, current: HelperConstants.protocolVersion)
    }

    /// Quick liveness check — true iff the helper answers AND its
    /// protocol matches ours. Use `health()` when you need to
    /// distinguish "down" from "outdated".
    public func ping() -> Bool {
        if case .healthy = health() { return true }
        return false
    }

    /// Forwards a `FanMode` to the helper. Returns true on success.
    @discardableResult
    public func setMode(_ mode: FanMode, for fanID: String) -> Bool {
        let req: HelperRequest
        switch mode {
        case .auto:
            req = .setAuto(fanID: fanID)
        case .constant(let rpm):
            req = .setConstant(fanID: fanID, rpm: rpm)
        case .sensorBased:
            // Sensor-based is host-driven — the GUI's polling loop rewrites
            // a constant target on every tick. No special helper RPC needed.
            return true
        }
        do {
            let resp = try send(req, timeoutSeconds: Self.writeTimeoutSeconds)
            if !resp.ok {
                Log.smc.error("Helper rejected \(fanID) write: \(resp.error ?? "<no error>")")
            }
            return resp.ok
        } catch {
            Log.smc.debug("Helper call failed: \(error)")
            return false
        }
    }

    /// Hand a fan to a temperature curve (protocol v9). Sent ONCE — the
    /// helper then drives it from its own 1 Hz timer, including after this
    /// process is gone. `setMode(.auto, …)` is what takes it back.
    ///
    /// `smoothingSeconds` is the low-pass time constant applied to the driving
    /// temperature before the curve is interpolated (protocol v10); 0 reacts to
    /// every reading.
    @discardableResult
    public func setCurve(fanID: String, sensorId: String, points: [CurvePoint],
                         smoothingSeconds: Double) -> Bool {
        do {
            let resp = try send(.setCurve(fanID: fanID, sensorId: sensorId, points: points,
                                          smoothingSeconds: smoothingSeconds),
                                timeoutSeconds: Self.writeTimeoutSeconds)
            if !resp.ok {
                Log.smc.error("Helper rejected \(fanID) curve: \(resp.error ?? "<no error>")")
            }
            return resp.ok
        } catch {
            Log.smc.debug("Helper curve call failed: \(error)")
            return false
        }
    }

    /// What the helper says it is driving. The three cases are NOT
    /// interchangeable for a crash-safe sweep: `unknown` means a live pre-v11
    /// helper — which CAN be holding curves it cannot report — so sweeping
    /// on it would kill a curve; only `down` (nobody home to own anything)
    /// and an explicit `owned` set are safe to act on.
    public enum FanOwnership {
        /// Curved and fixed-hold sets separately — the crash-safe sweep
        /// spares their union, while the chip reconciliation needs to know
        /// specifically whether any CURVE is running.
        case owned(curved: Set<String>, held: Set<String>)
        case unknown
        case down
    }

    public func fanOwnership() -> FanOwnership {
        // `.down` requires POSITIVE absence: ECONNREFUSED (a listener-less
        // socket — a stale file from a kill -9 refuses too, and launchd's
        // KeepAlive respawn answers within moments either way) or ENOENT
        // (never installed). Any OTHER connect failure — permissions, a
        // transient EINTR — proves nothing about absence and stays
        // `.unknown`. Once connected, any later failure — including a read
        // timeout — is `.unknown` too: the helper processes requests
        // serially and a cold unlock dance can hold it past our window,
        // and a busy helper is a LIVE owner, not an absent one.
        let fd: Int32
        do {
            fd = try UnixSocket.connect(toPath: socketPath)
        } catch UnixSocketError.connect(let errno) where errno == ECONNREFUSED || errno == ENOENT {
            return .down
        } catch {
            return .unknown
        }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: 5)
        guard let payload = try? encoder.encode(HelperRequest.ping),
              (try? UnixSocket.writeLine(fd, payload: payload)) != nil,
              let raw = try? UnixSocket.readLine(fd),
              let resp = try? decoder.decode(HelperResponse.self, from: raw),
              resp.ok,
              resp.curvedFanIDs != nil || resp.heldFanIDs != nil
        else { return .unknown }
        return .owned(curved: Set(resp.curvedFanIDs ?? []),
                      held: Set(resp.heldFanIDs ?? []))
    }

    /// Returns true if the helper socket exists AND is reachable. Cheap.
    public var isInstalled: Bool {
        var st = stat()
        return stat(socketPath, &st) == 0
    }

    // MARK: -

    /// Privileged writes wait out the whole cold unlock dance; see the
    /// divergence note in the header. Everything else fails fast at 5 s.
    private static let writeTimeoutSeconds = 45

    private func send(_ req: HelperRequest, timeoutSeconds: Int = 5) throws -> HelperResponse {
        let fd = try UnixSocket.connect(toPath: socketPath)
        defer { close(fd) }
        // Default 5s SO_RCVTIMEO/SO_SNDTIMEO fails fast on a deadlocked /
        // hung helper instead of pinning the GUI's smcQueue forever; writes
        // pass writeTimeoutSeconds so a legitimate cold Ftst dance isn't
        // recorded as a failure the helper then contradicts.
        UnixSocket.setTimeouts(fd, seconds: timeoutSeconds)
        let payload = try encoder.encode(req)
        try UnixSocket.writeLine(fd, payload: payload)
        let raw = try UnixSocket.readLine(fd)
        return try decoder.decode(HelperResponse.self, from: raw)
    }
}
