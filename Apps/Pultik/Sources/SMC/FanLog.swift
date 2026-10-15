// Minimal stand-in for GenesisFanControlCore's Log proxy so the vendored
// SMC bridge compiles unchanged. Unified log only — pultik has no Logs panel.

import Foundation
import os.log

public struct LogCategory {
    let logger: Logger

    public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    public func warning(_ message: String) { logger.warning("⚠️ \(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("🛑 \(message, privacy: .public)") }
}

public enum Log {
    private static let subsystem = "dev.example.pultik"
    public static let smc = LogCategory(logger: Logger(subsystem: subsystem, category: "smc"))
    public static let fans = LogCategory(logger: Logger(subsystem: subsystem, category: "fans"))
}
