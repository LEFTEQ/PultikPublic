import Foundation

/// A straight-alpha sRGB colour, each channel in `0...1`.
public struct RGBA: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(red: Double(rgba >> 24 & 0xFF) / 255, green: Double(rgba >> 16 & 0xFF) / 255,
                  blue: Double(rgba >> 8 & 0xFF) / 255, alpha: Double(rgba & 0xFF) / 255)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
        return channels[3] == 255 ? rgb : rgb + String(format: "%02X", channels[3])
    }
}

public enum Appearance: String, Sendable, Decodable {
    case dark, light
}

/// The colours of a code surface other than its syntax.
public enum PaletteRole: String, CaseIterable, Sendable {
    case background, foreground
    /// The gutter's own fill (context lines).
    case gutter
    /// Gutter figures and other quiet text (a hunk header).
    case lineNumber
    case currentLine, selection, cursor
    /// A changed line's wash, and the changed words inside it.
    case addedLine, removedLine, addedWord, removedWord
    /// A changed line's gutter fill, drawn over its wash.
    case addedGutter, removedGutter
    /// The ± glyph, a file's A / D letter and its +n −n counts.
    case addedMark, removedMark
    /// A hunk separator's band, and a file header's band.
    case hunk, header
    case findMatch
    /// Hairlines: under a file header, between panes.
    case border
    /// A language server's diagnostics: the squiggle and the gutter mark.
    case error, warning, info
}

/// What a highlighted run means. Each app maps its highlighter's kinds here.
public enum SyntaxRole: String, CaseIterable, Sendable {
    case keyword, string, escape, function, type, variable, builtin, parameter, property, number, constant, comment,
         `operator`, punctuation, tag, attribute, module, heading, literal, emphasis, strong, link
}

public struct SyntaxStyle: Hashable, Sendable {
    public let color: RGBA
    public let bold: Bool
    public let italic: Bool

    public init(color: RGBA, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

/// Where a theme's values come from, and under which terms.
public struct Provenance: Hashable, Sendable, Decodable {
    public let source: String
    public let licence: String
    public let notes: String?
}

/// One theme: a palette for code surfaces and a style per syntax role, both
/// complete — decoding fails on a missing or unknown role.
public struct CodeTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let appearance: Appearance
    public let provenance: Provenance
    private let palette: [PaletteRole: RGBA]
    private let syntax: [SyntaxRole: SyntaxStyle]

    public subscript(role: PaletteRole) -> RGBA {
        // Complete by construction (`init(from:)`).
        palette[role]!
    }

    public subscript(role: SyntaxRole) -> SyntaxStyle {
        syntax[role]!
    }
}

extension CodeTheme: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, appearance, provenance, palette, syntax
    }

    private struct StyleFile: Decodable {
        let color: String
        let bold: Bool?
        let italic: Bool?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        appearance = try container.decode(Appearance.self, forKey: .appearance)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        let themeID = id
        palette = try Self.complete(container.decode([String: String].self, forKey: .palette), theme: themeID) { hex in
            try Self.color(hex, theme: themeID)
        }
        syntax = try Self.complete(container.decode([String: StyleFile].self, forKey: .syntax), theme: themeID) {
            style in
            try SyntaxStyle(color: Self.color(style.color, theme: themeID), bold: style.bold ?? false,
                            italic: style.italic ?? false)
        }
    }

    /// Every case of `Role` exactly once, by its raw value.
    private static func complete<Role: RawRepresentable & CaseIterable & Hashable, Raw, Value>(
        _ raw: [String: Raw], theme: String, _ transform: (Raw) throws -> Value
    ) throws -> [Role: Value] where Role.RawValue == String {
        var result: [Role: Value] = [:]
        for (key, value) in raw {
            guard let role = Role(rawValue: key) else { throw ThemeDefinitionError.unknownRole(theme: theme, role: key) }
            result[role] = try transform(value)
        }
        if let missing = Role.allCases.first(where: { result[$0] == nil }) {
            throw ThemeDefinitionError.missingRole(theme: theme, role: missing.rawValue)
        }
        return result
    }

    private static func color(_ hex: String, theme: String) throws -> RGBA {
        guard let color = RGBA(hex: hex) else { throw ThemeDefinitionError.badColour(theme: theme, value: hex) }
        return color
    }
}

public enum ThemeDefinitionError: Error, Equatable, CustomStringConvertible {
    case unknownRole(theme: String, role: String)
    case missingRole(theme: String, role: String)
    case badColour(theme: String, value: String)
    case duplicateID(String)
    case noThemes
    case missingResource

    public var description: String {
        switch self {
        case let .unknownRole(theme, role): "theme \(theme): unknown role \(role)"
        case let .missingRole(theme, role): "theme \(theme): no \(role)"
        case let .badColour(theme, value): "theme \(theme): \(value) is not #RRGGBB or #RRGGBBAA"
        case let .duplicateID(id): "theme \(id) is defined twice"
        case .noThemes: "the definition holds no theme"
        case .missingResource: "themes.json is not in the CodeThemes bundle"
        }
    }
}
