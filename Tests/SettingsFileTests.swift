import XCTest
@testable import Pultik

/// The settings-file policy behind `Preferences.loadSnapshot()`: a bad edit
/// costs only the bad entry, an undecodable file keeps the last good copy and
/// is never moved or replaced, and only a missing file reaches the legacy
/// fallbacks (brief AC13).
final class SettingsFileTests: XCTestCase {
    /// Decodes `projects` exactly as `Preferences.init(from:)` does.
    private struct Shape: Decodable {
        let projects: [ProjectSpec]

        enum CodingKeys: String, CodingKey { case projects }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projects = try c.decode(LossyArray<ProjectSpec>.self, forKey: .projects).elements
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pultik-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws -> URL {
        let url = directory.appending(path: "settings.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    func testBadEntriesAreSkippedAndReportedTheRestKept() throws {
        let url = try write("""
        {"projects": [
          {"key": "exampleapp", "title": "ExampleApp"},
          {"title": "no key"},
          {"key": "eve", "links": [{"title": "Console"}], "prod": [{"key": "eve-exampleapp-prod"}]},
          {"key": "booking", "prod": []}
        ]}
        """)
        guard case let .fresh(shape, issues, _, _) = SettingsFile.resolve(Shape.self, at: url, lastGood: nil) else {
            return XCTFail("a partly bad file still decodes")
        }
        XCTAssertEqual(shape.projects.map(\.key), ["exampleapp", "eve", "booking"])
        // Lenient: a project without lists, or a link without a url, is not fatal.
        XCTAssertEqual(shape.projects[0].links.count, 0)
        XCTAssertEqual(shape.projects[1].links.count, 0)
        XCTAssertEqual(shape.projects[1].title, "eve")
        // Nil = never set (seed once); [] = deliberately none (left alone).
        XCTAssertNil(shape.projects[0].prod)
        XCTAssertEqual(shape.projects[1].prod?.first?.key, "eve-exampleapp-prod")
        XCTAssertEqual(shape.projects[2].prod, [])
        XCTAssertEqual(issues, ["projects[1]: missing key", "projects[2].links[0]: missing url"])
    }

    func testUnreadableFileKeepsLastGoodAndIsNeverTouched() throws {
        let broken = #"{"projects": [{"key": "exampleapp",}"#
        let url = try write(broken)
        let lastGood = try JSONDecoder().decode(Shape.self, from: Data(#"{"projects": [{"key": "kept"}]}"#.utf8))

        guard case let .unreadable(kept, issue) = SettingsFile.resolve(Shape.self, at: url, lastGood: lastGood) else {
            return XCTFail("a syntax error must not decode")
        }
        XCTAssertEqual(kept?.projects.map(\.key), ["kept"])
        XCTAssertTrue(issue.hasPrefix("settings.json"), issue)
        // The edit in progress stays exactly where it was.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
    }

    func testOnlyAMissingFileReachesTheLegacyFallback() {
        let missing = directory.appending(path: "settings.json")
        guard case .absent = SettingsFile.resolve(Shape.self, at: missing, lastGood: nil) else {
            return XCTFail("a missing file is .absent")
        }
        XCTAssertNil(SettingsFile.snapshot(at: missing, lastGoodURL: lastGoodURL, memory: SettingsMemory<Doc>(),
                                           fallback: { Doc(projects: []) }))
    }

    /// A document under the snapshot policy, shaped like `Preferences`:
    /// lossy projects, migrations that report a change when asked to.
    private struct Doc: SettingsDocument {
        var projects: [ProjectSpec]
        var migrates = false
        /// Set by `applyMigrations` when `migrates` asks for a change.
        var migrated = false

        enum CodingKeys: String, CodingKey { case projects, migrates }

        init(projects: [ProjectSpec]) {
            self.projects = projects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projects = try c.decode(LossyArray<ProjectSpec>.self, forKey: .projects).elements
            migrates = try c.decodeIfPresent(Bool.self, forKey: .migrates) ?? false
        }

        mutating func restoreSkipped(_ skipped: [SkippedEntry], from lastGood: Doc) {
            projects.restoreSkipped(skipped, from: lastGood.projects)
        }

        mutating func applyMigrations() -> Bool {
            if migrates { migrated = true }
            return migrates
        }
    }

    private var lastGoodURL: URL {
        directory.appending(path: "settings.lastgood.json")
    }

    private func snapshot(_ memory: SettingsMemory<Doc>, at url: URL) -> SettingsSnapshot<Doc>? {
        SettingsFile.snapshot(at: url, lastGoodURL: lastGoodURL, memory: memory, fallback: { Doc(projects: []) })
    }

    /// AC13: a malformed prod pointer keeps the previous pointer in memory,
    /// lists one issue, and the file is never rewritten — not even by a
    /// migration that would otherwise save.
    func testMalformedPointerKeepsThePreviousOneAndIsNeverWritten() throws {
        let memory = SettingsMemory<Doc>()
        var url = try write(#"{"migrates": true, "projects": [{"key": "exampleapp", "prod": [{"key": "exampleapp-prod", "title": "ExampleApp prod", "order": 1}]}]}"#)
        let clean = try XCTUnwrap(snapshot(memory, at: url))
        XCTAssertTrue(clean.writable)
        XCTAssertTrue(clean.needsSave)

        let lossy = #"{"migrates": true, "projects": [{"key": "exampleapp", "prod": [{"key": "exampleapp-prod", "title": 7}]}]}"#
        url = try write(lossy)
        let snap = try XCTUnwrap(snapshot(memory, at: url))
        XCTAssertFalse(snap.writable)
        XCTAssertFalse(snap.needsSave)
        XCTAssertEqual(snap.issues, ["projects[0].prod[0]: expected String at title"])
        XCTAssertEqual(snap.value.projects.first?.prod,
                       [ProdPointer(key: "exampleapp-prod", title: "ExampleApp prod", order: 1)])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), lossy)
    }

    /// A launch whose settings.json no longer decodes runs on the persisted
    /// last good copy, not on the shipped defaults.
    func testColdStartOnABadFileRunsOnThePersistedLastGood() throws {
        var url = try write(#"{"projects": [{"key": "exampleapp"}, {"key": "eve"}]}"#)
        XCTAssertEqual(snapshot(SettingsMemory<Doc>(), at: url)?.writable, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lastGoodURL.path))

        url = try write(#"{"projects": [{"key": "exampleapp",}"#)
        let cold = try XCTUnwrap(snapshot(SettingsMemory<Doc>(), at: url))
        XCTAssertFalse(cold.writable)
        XCTAssertEqual(cold.value.projects.map(\.key), ["exampleapp", "eve"])
    }

    /// Every load branch migrates: a last-good copy an older build persisted
    /// is migrated in memory on a bad file, and nothing is written.
    func testUnreadableFileMigratesTheLastGoodInMemoryOnly() throws {
        let stale = #"{"migrates": true, "projects": [{"key": "exampleapp"}]}"#
        try Data(stale.utf8).write(to: lastGoodURL)
        let url = try write(#"{"projects": [{"key": "exampleapp",}"#)
        let cold = try XCTUnwrap(snapshot(SettingsMemory<Doc>(), at: url))
        XCTAssertTrue(cold.value.migrated)
        XCTAssertFalse(cold.writable)
        XCTAssertFalse(cold.needsSave)
        XCTAssertEqual(try String(contentsOf: lastGoodURL, encoding: .utf8), stale)
    }
}
