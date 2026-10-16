import AppKit
import CodeThemes

/// The selected code theme as the canvas draws it (workbench WP4): every
/// colour resolved to an `NSColor` once per switch, and each kind's weight
/// and slant. Code colours come from `Packages/Theme` (`CodeThemeStore`),
/// never from constants in a view; the panel around a code surface keeps
/// `Theme`'s tokens.
struct CodePalette {
    let theme: CodeTheme
    let background: NSColor
    let foreground: NSColor
    /// Gutter numbers and the hunk header's text.
    let muted: NSColor
    let addedWash: NSColor
    let removedWash: NSColor
    /// A changed line's gutter, drawn over its wash.
    let addedGutter: NSColor
    let removedGutter: NSColor
    let addedMark: NSColor
    let removedMark: NSColor
    /// The hunk separator's band, and a file header's band and hairline.
    let hunk: NSColor
    let header: NSColor
    let border: NSColor
    let selection: NSColor
    /// By `TokenKind.rawValue`: the canvas looks a run's colour up per run.
    private let colors: [NSColor]
    private let styles: [SyntaxStyle?]

    init(_ theme: CodeTheme) {
        self.theme = theme
        background = theme[.background].nsColor
        foreground = theme[.foreground].nsColor
        muted = theme[.lineNumber].nsColor
        addedWash = theme[.addedLine].nsColor
        removedWash = theme[.removedLine].nsColor
        addedGutter = theme[.addedGutter].nsColor
        removedGutter = theme[.removedGutter].nsColor
        addedMark = theme[.addedMark].nsColor
        removedMark = theme[.removedMark].nsColor
        hunk = theme[.hunk].nsColor
        header = theme[.header].nsColor
        border = theme[.border].nsColor
        selection = theme[.selection].nsColor
        styles = TokenKind.allCases.map { $0.role.map { theme[$0] } }
        let foreground = foreground
        colors = styles.map { $0?.color.nsColor ?? foreground }
    }

    func color(_ kind: TokenKind) -> NSColor {
        colors[Int(kind.rawValue)]
    }

    /// The regular, bold, italic or bold-italic face `kind` draws in.
    func font(_ kind: TokenKind, in fonts: CodeFonts) -> NSFont {
        guard let style = styles[Int(kind.rawValue)] else { return fonts.regular }
        switch (style.bold, style.italic) {
        case (false, false): return fonts.regular
        case (true, false): return fonts.bold
        case (false, true): return fonts.italic
        case (true, true): return fonts.boldItalic
        }
    }
}

/// The canvas's monospaced faces. SF Mono keeps one advance across weights
/// and slants, so a styled run never moves the columns.
struct CodeFonts {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont

    init(size: CGFloat) {
        regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        italic = Self.italic(regular)
        boldItalic = Self.italic(bold)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)),
               size: font.pointSize) ?? font
    }
}

extension TokenKind {
    /// The theme role a kind draws with; plain draws in the foreground.
    var role: SyntaxRole? {
        switch self {
        case .plain: nil
        case .keyword: .keyword
        case .string: .string
        case .escape: .escape
        case .function: .function
        case .type: .type
        case .variable: .variable
        case .builtin: .builtin
        case .parameter: .parameter
        case .property: .property
        case .number: .number
        case .constant: .constant
        case .comment: .comment
        case .operator: .operator
        case .punctuation: .punctuation
        case .tag: .tag
        case .attribute: .attribute
        case .module: .module
        case .heading: .heading
        case .literal: .literal
        case .emphasis: .emphasis
        case .strong: .strong
        case .link: .link
        }
    }
}
