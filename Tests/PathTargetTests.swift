import XCTest
@testable import Pultik

/// The repair side of the palette path card: what an AI printed into a
/// terminal, wrapped and decorated, must land on the file it meant.
final class PathTargetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "pultik-path-tests-\(UUID().uuidString)")
        let dir = root.appending(path: "forge/.worktrees/push/Sources/Support")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appending(path: "PathTarget.swift"), atomically: true, encoding: .utf8)
        // A worktree's .git is a FILE pointing at the main checkout.
        try "gitdir: elsewhere".write(
            to: root.appending(path: "forge/.worktrees/push/.git"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appending(path: "My Documents/notes"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var file: String { root.appending(path: "forge/.worktrees/push/Sources/Support/PathTarget.swift").path }
    private var pushDir: String { root.appending(path: "forge/.worktrees/push").path }

    func testExactFileIsFound() throws {
        let target = try XCTUnwrap(PathTarget.detect(file))
        XCTAssertEqual(target.url.path, file)
        XCTAssertFalse(target.isDirectory)
        XCTAssertNil(target.missing)
        XCTAssertEqual(target.verbs, [.open, .code, .reveal, .terminal])
    }

    func testDirectoryOffersNoReveal() throws {
        let target = try XCTUnwrap(PathTarget.detect(" \(pushDir) "))
        XCTAssertTrue(target.isDirectory)
        XCTAssertEqual(target.verbs, [.open, .code, .terminal])
    }

    func testTerminalWrappedMidWordWithTrailingComma() throws {
        // Exactly what a wrapped terminal line pastes as: newline plus the
        // continuation indentation in the middle of a path component.
        let wrapped = file.replacingOccurrences(of: ".worktrees", with: ".worktr\n      ees") + ","
        let target = try XCTUnwrap(PathTarget.detect(wrapped))
        XCTAssertEqual(target.url.path, file)
        XCTAssertNil(target.missing)
    }

    func testLineAndColumnSuffix() throws {
        let target = try XCTUnwrap(PathTarget.detect("'\(file):42:7'"))
        XCTAssertEqual(target.url.path, file)
        XCTAssertEqual(target.line, 42)
        XCTAssertEqual(target.column, 7)
    }

    func testQuotesAndClosingParenAreStripped() throws {
        let target = try XCTUnwrap(PathTarget.detect("(\"\(pushDir)\")."))
        XCTAssertEqual(target.url.path, pushDir)
    }

    func testFileURLAndTildeExpand() throws {
        let viaURL = try XCTUnwrap(PathTarget.detect("file://\(pushDir)"))
        XCTAssertEqual(viaURL.url.path, pushDir)
        let home = try XCTUnwrap(PathTarget.detect("~"))
        XCTAssertEqual(home.url.path, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testSpacesInsidePathSurviveWrapping() throws {
        let path = root.appending(path: "My Documents/notes").path
        let wrapped = path.replacingOccurrences(of: "My Documents", with: "My\n   Documents")
        let target = try XCTUnwrap(PathTarget.detect(wrapped))
        XCTAssertEqual(target.url.path, path)
    }

    func testMissingTailFallsBackToNearestAncestor() throws {
        let target = try XCTUnwrap(PathTarget.detect("\(pushDir)h/Sources/Nope.swift"))
        XCTAssertEqual(target.url.path, root.appending(path: "forge/.worktrees").path)
        XCTAssertTrue(target.isDirectory)
        XCTAssertEqual(target.missing, "\(pushDir)h/Sources/Nope.swift")
        XCTAssertNil(target.line, "a line number means nothing on an ancestor")
    }

    func testShallowGarbageIsNotAPath() {
        XCTAssertNil(PathTarget.detect("/definitely-not-here-\(UUID().uuidString)"))
        XCTAssertNil(PathTarget.detect("/U"))
        XCTAssertNil(PathTarget.detect("fix the build"))
        XCTAssertFalse(PathTarget.looksLikePath("owner/repo"))
    }

    func testSplitLineSuffixKeepsColonsInNames() {
        let (path, line, column) = PathTarget.splitLineSuffix("/tmp/a:b/file.swift")
        XCTAssertEqual(path, "/tmp/a:b/file.swift")
        XCTAssertNil(line)
        XCTAssertNil(column)
        let single = PathTarget.splitLineSuffix("/tmp/file.swift:9")
        XCTAssertEqual(single.line, 9)
        XCTAssertNil(single.column)
    }

    func testGitRootAcceptsWorktreeGitFile() {
        XCTAssertEqual(PathTarget.gitRoot(of: URL(filePath: file))?.path, pushDir)
        XCTAssertNil(PathTarget.gitRoot(of: root.appending(path: "My Documents/notes")))
    }
}
