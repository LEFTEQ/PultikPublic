import Foundation

extension JSONDecoder.DateDecodingStrategy {
    /// ISO8601 with or without fractional seconds — Sentry emits fractional
    /// timestamps, which the plain .iso8601 strategy rejects.
    static let iso8601Flexible = custom { decoder in
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let date = ISO8601Parsers.fractional.date(from: raw) ?? ISO8601Parsers.plain.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unparseable ISO8601 date: \(raw)"
        ))
    }
}

/// One parser of each kind for every decode: a formatter per date field cost
/// two allocations per timestamp (the Mac health decode's top frame). Parsing
/// with an ISO8601DateFormatter is thread-safe; it is never mutated after init.
private enum ISO8601Parsers {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}

extension Date {
    /// Compact age like "now", "45s", "6m", "1h", "2d".
    var shortAge: String {
        shortAge(relativeTo: Date())
    }

    /// The same age against an explicit clock — the Foundation-tested glances
    /// pass theirs so a test reads "12m", not whatever the wall clock says.
    func shortAge(relativeTo now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(self))
        switch seconds {
        case ..<10: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
