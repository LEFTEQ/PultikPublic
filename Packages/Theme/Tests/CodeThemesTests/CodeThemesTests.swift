import CodeThemes
import Foundation
import XCTest

final class CodeThemesTests: XCTestCase {
    /// The one definition file loads every shipped theme, each complete.
    func testTheDefinitionLoadsEveryThemeWithEveryRole() {
        let themes = ThemeCatalog.shipped.themes
        // A private build also ships one theme the public definition leaves out.
        XCTAssertEqual(themes.map(\.id).filter(Self.published.contains), Self.published, "in file order")
        for theme in themes {
            for role in PaletteRole.allCases {
                XCTAssertGreaterThan(theme[role].alpha, 0, "\(theme.id) \(role)")
            }
            for role in SyntaxRole.allCases {
                XCTAssertEqual(theme[role].color.alpha, 1, "\(theme.id) \(role): syntax is opaque")
            }
            XCTAssertFalse(theme.provenance.source.isEmpty || theme.provenance.licence.isEmpty, theme.id)
        }
        XCTAssertEqual(ThemeCatalog.shipped.theme(id: "one-dark")?[.background].hex, "#282C34")
        XCTAssertEqual(ThemeCatalog.shipped.theme(id: "one-light")?.appearance, .light)
        XCTAssertNil(ThemeCatalog.shipped.theme(id: "cursor-dark"))
    }

    /// A role the enums do not name, a missing one or a bad colour fails the
    /// whole file — the Rust reader is just as strict.
    func testAnIncompleteOrUnknownRoleFails() throws {
        let theme = ThemeCatalog.shipped.themes[0]
        func file(palette: [String: String], syntax: [String: [String: String]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["themes": [[
                "id": "t", "name": "T", "appearance": "dark",
                "provenance": ["source": "s", "licence": "l"], "palette": palette, "syntax": syntax,
            ]]])
        }
        var palette = Dictionary(uniqueKeysWithValues: PaletteRole.allCases.map { ($0.rawValue, theme[$0].hex) })
        let syntax = Dictionary(uniqueKeysWithValues: SyntaxRole.allCases.map { ($0.rawValue, ["color": theme[$0].color.hex]) })
        XCTAssertNoThrow(try ThemeCatalog(data: file(palette: palette, syntax: syntax)))

        palette["gutterGlow"] = "#FFFFFF"
        XCTAssertThrowsError(try ThemeCatalog(data: file(palette: palette, syntax: syntax))) {
            XCTAssertEqual($0 as? ThemeDefinitionError, .unknownRole(theme: "t", role: "gutterGlow"))
        }
        palette["gutterGlow"] = nil
        palette["cursor"] = nil
        XCTAssertThrowsError(try ThemeCatalog(data: file(palette: palette, syntax: syntax))) {
            XCTAssertEqual($0 as? ThemeDefinitionError, .missingRole(theme: "t", role: "cursor"))
        }
        palette["cursor"] = "blue"
        XCTAssertThrowsError(try ThemeCatalog(data: file(palette: palette, syntax: syntax))) {
            XCTAssertEqual($0 as? ThemeDefinitionError, .badColour(theme: "t", value: "blue"))
        }
    }

    /// Switching notifies each live observer once with the new theme; an
    /// unknown id or the current one changes nothing, and a gone observer is
    /// never called.
    @MainActor
    func testSwitchingNotifiesObservers() {
        let store = CodeThemeStore(selectedID: nil, defaultIDs: ["one-dark"])
        XCTAssertEqual(store.theme.id, "one-dark")
        let canvas = NSObject()
        var seen: [String] = []
        store.observe(canvas) { seen.append($0.id) }
        var gone: NSObject? = NSObject()
        var goneCalls = 0
        store.observe(gone!) { _ in goneCalls += 1 }
        gone = nil

        XCTAssertTrue(store.select("one-light"))
        XCTAssertEqual(store.theme.id, "one-light")
        XCTAssertFalse(store.select("one-light"), "the shown theme is no change")
        XCTAssertFalse(store.select("cursor-dark"), "an unknown id is no change")
        XCTAssertTrue(store.select("github-dark"))
        XCTAssertEqual(seen, ["one-light", "github-dark"])
        XCTAssertEqual(goneCalls, 0)

        store.stopObserving(canvas)
        store.select("adeberry-amber")
        XCTAssertEqual(seen, ["one-light", "github-dark"])
    }

    /// An id this build lacks — saved (a hand edit, a newer build's theme) or
    /// a default (a theme a public build leaves out) — falls through to the
    /// next default, then the first theme, never an error.
    @MainActor
    func testAMissingIDFallsThroughTheDefaults() {
        XCTAssertEqual(CodeThemeStore(selectedID: "cursor-dark", defaultIDs: ["adeberry-amber"]).theme.id, "adeberry-amber")
        XCTAssertEqual(CodeThemeStore(selectedID: "one-dark", defaultIDs: ["adeberry-amber"]).theme.id, "one-dark")
        let store = CodeThemeStore(selectedID: "not-shipped", defaultIDs: ["not-shipped-either", "one-light"])
        XCTAssertEqual(store.theme.id, "one-light")
        XCTAssertEqual(store.defaultID, "one-light")
        XCTAssertEqual(CodeThemeStore(selectedID: nil, defaultIDs: []).theme.id, ThemeCatalog.shipped.themes[0].id)
    }

    /// The themes every build ships, the public mirror included.
    private static let published = ["adeberry-amber", "one-dark", "github-dark", "one-light", "tokyo-night"]

    func testHexRoundTrips() {
        XCTAssertEqual(RGBA(hex: "#41A6B520")?.hex, "#41A6B520")
        XCTAssertEqual(RGBA(hex: "#ffffff")?.hex, "#FFFFFF")
        XCTAssertNil(RGBA(hex: "41A6B5"))
        XCTAssertNil(RGBA(hex: "#41A6"))
        XCTAssertNil(RGBA(hex: "#+41A6B"))
    }
}
