import Foundation

/// The themes of one definition file, in its order, looked up by id.
public struct ThemeCatalog: Sendable {
    public let themes: [CodeTheme]

    /// The bundled `themes.json`. Its test proves it decodes, so a failure
    /// here is a broken build, never a user's state.
    public static let shipped: ThemeCatalog = {
        do {
            guard let url = Bundle.module.url(forResource: "themes", withExtension: "json") else {
                throw ThemeDefinitionError.missingResource
            }
            return try ThemeCatalog(data: Data(contentsOf: url))
        } catch {
            fatalError("CodeThemes: themes.json does not load: \(error)")
        }
    }()

    public init(data: Data) throws {
        let themes = try JSONDecoder().decode(File.self, from: data).themes
        guard !themes.isEmpty else { throw ThemeDefinitionError.noThemes }
        var seen = Set<String>()
        for theme in themes where !seen.insert(theme.id).inserted {
            throw ThemeDefinitionError.duplicateID(theme.id)
        }
        self.themes = themes
    }

    public func theme(id: String) -> CodeTheme? {
        themes.first { $0.id == id }
    }

    private struct File: Decodable {
        let themes: [CodeTheme]
    }
}
