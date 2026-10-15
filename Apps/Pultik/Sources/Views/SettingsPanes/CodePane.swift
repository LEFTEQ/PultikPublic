import CodeThemes
import SwiftUI

/// Settings ▸ Code (workbench WP4): the code theme every code surface draws
/// in — a PR's Files changed and a definition's card — each shown as a few
/// lines of itself. A click switches every open canvas at once and saves
/// the pick (`codeTheme`).
struct CodePane: View {
    private let preferences = CodePreferences.shared

    var body: some View {
        Form {
            Section {
                ForEach(preferences.themes.catalog.themes) { theme in
                    row(theme, selected: theme.id == preferences.themes.theme.id)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Code surfaces only; the panel around them keeps its own colours. \(defaultName) is the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var defaultName: String {
        preferences.themes.catalog.theme(id: preferences.themes.defaultID)?.name ?? preferences.themes.defaultID
    }

    private func row(_ theme: CodeTheme, selected: Bool) -> some View {
        Button {
            preferences.selectTheme(theme.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(theme.name).font(.body.weight(selected ? .semibold : .regular))
                    CodeThemePreview(theme: theme)
                    Text(theme.provenance.licence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A few lines in `theme`: keywords, a call, a string, a comment, and one
/// removed and one added line on the theme's own diff washes.
private struct CodeThemePreview: View {
    let theme: CodeTheme

    private typealias Run = (String, SyntaxRole?)

    private static let lines: [(PaletteRole?, [Run])] = [
        (nil, [("// greet whoever calls", .comment)]),
        (nil, [("func", .keyword), (" ", nil), ("greet", .function), ("(", .punctuation), ("name", .parameter),
               (": ", .punctuation), ("String", .type), (") {", .punctuation)]),
        (.removedLine, [("    let", .keyword), (" count ", .variable), ("=", .operator), (" 41", .number)]),
        (.addedLine, [("    let", .keyword), (" count ", .variable), ("=", .operator), (" 42", .number)]),
        (nil, [("    return", .keyword), (" ", nil), ("\"hi \\(", .string), ("name", .variable), (")\\n\"", .string)]),
        (nil, [("}", .punctuation)]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.lines.indices, id: \.self) { index in
                let (wash, runs) = Self.lines[index]
                Text(attributed(runs))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(wash.map { theme[$0].color } ?? .clear)
            }
        }
        .padding(.vertical, 6)
        .background(theme[.background].color, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(theme[.border].color))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
        .frame(maxWidth: 420)
        .accessibilityHidden(true)
    }

    private func attributed(_ runs: [Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { text, run in
            var piece = AttributedString(run.0)
            let style = run.1.map { theme[$0] }
            var font = Theme.Typo.code
            if style?.bold == true { font = font.bold() }
            if style?.italic == true { font = font.italic() }
            piece.font = font
            piece.foregroundColor = (style?.color ?? theme[.foreground]).color
            text += piece
        }
    }
}
