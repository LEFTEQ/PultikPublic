import Foundation

/// A palette query that asks for one brightness level rather than a preset
/// (docs/specs/2026-09-13-brightness-set-and-external-scale-decisions.md).
///
/// Accepts `50`, `50%`, `brightness 50`, `screen 40%`, `dim 30` — an optional
/// display alias, then an integer 0…100, then an optional percent sign. Pure
/// and nonisolated so a test can reach it without the store.
enum BrightnessQuery {
    /// Words that may precede the number. `dim` is here because "dim 30" is
    /// what one types when the Dim preset is not dim enough tonight.
    static let aliases: Set<String> = [
        "brightness", "display", "displays", "monitor", "monitors", "screen", "screens", "dim",
    ]

    /// The percent the query names, or nil when it is not a brightness ask.
    static func parse(_ query: String) -> Int? {
        let words = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let last = words.last, words.count <= 2 else { return nil }
        if words.count == 2, !aliases.contains(words[0]) { return nil }
        var digits = last
        if digits.hasSuffix("%") { digits.removeLast() }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits),
              (0...100).contains(value)
        else { return nil }
        return value
    }
}
