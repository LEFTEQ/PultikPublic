// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/SMC/SMCService.swift) — do not hand-drift; re-vendor on upstream change.
//
//  SMCService.swift
//  GenesisFanControlCore
//
//  Protocol for talking to the System Management Controller.
//  The real implementation needs IOKit AppleSMC; bootstrap ships a mock.
//

import Foundation

public protocol SMCService: AnyObject, Sendable {
    var backendName: String { get }
    var isSimulated: Bool { get }
    func snapshot() -> (fans: [Fan], sensors: [TempSensor])
    func refresh()
    /// Returns true on success. Writes to SMC fan-control keys normally
    /// require root — when that's the cause, this returns false so the
    /// UI can surface "needs elevated privileges".
    @discardableResult
    func setMode(_ mode: FanMode, for fanID: String) -> Bool
}
