import Foundation

/// The one number format (DESIGN.md §6). Every figure the Kit draws goes
/// through here, so `119/147 GB`, `3m 12s` and `as of 15:12` read the same in
/// every module. Foundation-only: the foundation harness tests it.
///
/// Sizes are SI decimal (1 GB = 10⁹ bytes) with the unit written once; one
/// decimal for TB and for values under 10. Durations never put a space inside
/// a component (`1m 1s`, `3h 12m`, `9d`).
enum PultikFormat {
    // MARK: Sizes

    private static let units: [(suffix: String, scale: Double)] = [
        ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3),
    ]

    private static func unit(for bytes: Double) -> (suffix: String, scale: Double) {
        units.first { abs(bytes) >= $0.scale } ?? ("B", 1)
    }

    /// `5.5 GB`, `393 GB`, `1.4 TB`.
    static func size(_ bytes: Double) -> String {
        let u = unit(for: bytes)
        return "\(scaled(bytes / u.scale, tb: u.suffix == "TB")) \(u.suffix)"
    }

    /// `5.5 GB free`.
    static func free(_ bytes: Double) -> String { "\(size(bytes)) free" }

    /// `119/147 GB`, `1.4/1.7 TB`, `0/96 GB` — the total picks the unit.
    static func sizeRatio(used: Double, total: Double) -> String {
        let u = unit(for: total)
        let tb = u.suffix == "TB"
        return "\(scaled(used / u.scale, tb: tb))/\(scaled(total / u.scale, tb: tb)) \(u.suffix)"
    }

    private static func scaled(_ value: Double, tb: Bool) -> String {
        if value == 0 { return "0" }
        if tb || abs(value) < 10 { return String(format: "%.1f", value) }
        return String(Int(value.rounded()))
    }

    // MARK: Counts, percents

    /// `9/32`.
    static func ratio(_ count: Int, of total: Int) -> String { "\(count)/\(total)" }

    /// `93%`; `tenths` for rates where they matter (`0.0%`, `98.0%`).
    static func percent(_ fraction: Double, tenths: Bool = false) -> String {
        let value = fraction * 100
        return tenths ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    /// `+139%`, `-12%`.
    static func delta(_ fraction: Double) -> String {
        let value = Int((fraction * 100).rounded())
        return value > 0 ? "+\(value)%" : "\(value)%"
    }

    /// Three significant figures and `K`/`M`: `590 M`, `12.3 K`; a `B` keeps
    /// two decimals (`8.11 B`, `12.30 B`).
    static func count(_ value: Double) -> String {
        let scales: [(String, Double)] = [("B", 1e9), ("M", 1e6), ("K", 1e3)]
        guard let (suffix, scale) = scales.first(where: { abs(value) >= $0.1 }) else {
            return String(Int(value.rounded()))
        }
        let scaledValue = value / scale
        let digits = suffix == "B" ? 2 : abs(scaledValue) >= 100 ? 0 : abs(scaledValue) >= 10 ? 1 : 2
        return String(format: "%.\(digits)f \(suffix)", scaledValue)
    }

    /// `8 ms`, `83 °C`, `3274 rpm` — value, space, unit.
    static func quantity(_ value: Double, unit: String) -> String {
        "\(Int(value.rounded())) \(unit)"
    }

    // MARK: Time

    /// A run's length: `3s`, `1m 1s`, `3m 12s`, `2h`, `3h 12m`, `9d`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return pair(total / 60, "m", total % 60, "s")
        case ..<86400: return pair(total / 3600, "h", total % 3600 / 60, "m")
        default: return "\(total / 86400)d"
        }
    }

    /// How long something has been so, minute precision past the first
    /// minute: `40s`, `4m`, `6h 12m`, `1h`, `6d`.
    static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        switch total {
        case ..<60: return "\(total)s"
        case ..<3600: return "\(total / 60)m"
        case ..<86400: return pair(total / 3600, "h", total % 3600 / 60, "m")
        default: return "\(total / 86400)d"
        }
    }

    /// `4m ago`, `3h 12m ago`, `1d ago`.
    static func ago(_ date: Date, now: Date) -> String {
        "\(age(now.timeIntervalSince(date))) ago"
    }

    private static func pair(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
        minor == 0 ? "\(major)\(majorUnit)" : "\(major)\(majorUnit) \(minor)\(minorUnit)"
    }

    /// `09:00` — 24-hour, in `calendar`'s time zone.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `as of 15:12`.
    static func asOf(_ date: Date, calendar: Calendar = .current) -> String {
        "as of \(clock(date, calendar: calendar))"
    }

    /// `Oct 2`, or `Oct 2, 2025` when it is not this year.
    static func date(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
