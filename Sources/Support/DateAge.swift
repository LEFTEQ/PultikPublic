import Foundation

extension JSONDecoder.DateDecodingStrategy {
    /// ISO8601 with or without fractional seconds — Sentry and eve both emit
    /// fractional timestamps, which the plain .iso8601 strategy rejects.
    /// Formatters are created inside the closure: ISO8601DateFormatter is not
    /// Sendable, so a captured instance would trip strict concurrency.
    static let iso8601Flexible = custom { decoder in
        let raw = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unparseable ISO8601 date: \(raw)"
        ))
    }
}

extension Date {
    /// Compact age like "now", "45s", "6m", "1h", "2d".
    var shortAge: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<10: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
