import Foundation
import XCTest
@testable import Pultik

final class DevboxClearWorktreeTests: XCTestCase {
    private let cleared = DevboxClearReport(ok: true, summary: "Runtime cleared", diagnostics: [], next: [], log: "fixture runtime")

    private func fixture() throws -> (root: URL, worktree: URL, policy: DevboxClearWorktree) {
        let root = FileManager.default.temporaryDirectory.appending(path: "pultik-clear-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let tree = root.appending(path: ".worktrees/qa")
        for arguments in [
            ["init", "-b", "main", root.path],
            ["-C", root.path, "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "--allow-empty", "-m", "base"],
            ["-C", root.path, "worktree", "add", "-b", "qa-clear", tree.path],
        ] {
            XCTAssertTrue(Self.run("/usr/bin/git", arguments, 30).ok)
        }
        let policy = DevboxClearWorktree(command: Self.run, backupRoot: root.appending(path: "archives"))
        return (root, tree, policy)
    }

    private static func run(_ executable: String, _ arguments: [String], _ timeout: Int) -> DevboxClearCommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            // These disposable fixtures produce only small Git/tar responses.
            process.waitUntilExit()
            return .init(ok: process.terminationStatus == 0,
                         stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                         stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } catch {
            return .init(ok: false, stdout: "", stderr: error.localizedDescription)
        }
    }

    private func write(_ text: String, at path: URL) throws {
        try Data(text.utf8).write(to: path)
    }

    func testChangedIgnoredWorkIsKeptAfterRuntimeClear() throws {
        let f = try fixture()
        try write("ignored.txt\n", at: f.worktree.appending(path: ".gitignore"))
        let ignored = f.worktree.appending(path: "ignored.txt")
        try write("old ignored work", at: ignored)
        let preview = f.policy.inspect(f.worktree)
        XCTAssertTrue(preview.canRemove)
        try write("newer ignored work", at: ignored)
        let outcome = f.policy.remove(preview, source: .discard, after: cleared)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(try String(contentsOf: ignored), "newer ignored work")
    }

    func testPrimaryAndDetachedSourcesAreRetained() throws {
        let f = try fixture()
        XCTAssertFalse(f.policy.inspect(f.root).canRemove)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "checkout", "--detach"], 30).ok)
        let detached = f.policy.inspect(f.worktree)
        XCTAssertFalse(detached.canRemove)
        XCTAssertFalse(f.policy.remove(detached, source: .discard, after: cleared).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path))
    }

    func testOpposingStagedAndUnstagedDiffsStayVisible() throws {
        let f = try fixture()
        let path = f.worktree.appending(path: "tracked.txt")
        try write("original\n", at: path)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "add", "."], 30).ok)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "tracked"], 30).ok)
        try write("staged replacement\n", at: path)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "add", "tracked.txt"], 30).ok)
        try write("original\n", at: path)
        let preview = f.policy.inspect(f.worktree)
        XCTAssertTrue(preview.diff.contains("+staged replacement"))
        XCTAssertTrue(preview.diff.contains("-staged replacement"))
    }

    func testBackupPreservesIgnoredAndUntrackedFilesAndBranchBeforeRemoval() throws {
        let f = try fixture()
        try write("ignored.txt\n", at: f.worktree.appending(path: ".gitignore"))
        try write("ignored contents", at: f.worktree.appending(path: "ignored.txt"))
        try write("untracked contents", at: f.worktree.appending(path: "untracked.txt"))
        let outcome = f.policy.remove(f.policy.inspect(f.worktree), source: .backup, after: cleared)
        XCTAssertTrue(outcome.ok, outcome.log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.root.path, "rev-parse", "--verify", "refs/heads/qa-clear"], 30).ok)
        let files = try FileManager.default.contentsOfDirectory(at: f.policy.backupRoot, includingPropertiesForKeys: nil)
        let archive = try XCTUnwrap(files.first)
        let contents = Self.run("/usr/bin/tar", ["-xOf", archive.path, "./ignored.txt", "./untracked.txt"], 30)
        XCTAssertTrue(contents.ok)
        XCTAssertTrue(contents.stdout.contains("ignored contents"))
        XCTAssertTrue(contents.stdout.contains("untracked contents"))
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testChangesDuringBackupKeepWorktreeAndSavedArchive() throws {
        let f = try fixture()
        try write("ignored.txt\n", at: f.worktree.appending(path: ".gitignore"))
        let ignored = f.worktree.appending(path: "ignored.txt")
        try write("before backup", at: ignored)
        let policy = DevboxClearWorktree(command: { executable, arguments, timeout in
            let result = Self.run(executable, arguments, timeout)
            if executable == "/usr/bin/tar" { try! self.write("after backup", at: ignored) }
            return result
        }, backupRoot: f.policy.backupRoot)
        let outcome = policy.remove(policy.inspect(f.worktree), source: .backup, after: cleared)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(try String(contentsOf: ignored), "after backup")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: policy.backupRoot.path).count, 1)
    }

    func testIncompleteInventoryAndFailedBackupKeepSource() throws {
        let f = try fixture()
        let incomplete = DevboxClearWorktree(command: { executable, arguments, timeout in
            arguments.contains("ls-files") ? .init(ok: false, stdout: "", stderr: "cannot read inventory") : Self.run(executable, arguments, timeout)
        }, backupRoot: f.policy.backupRoot)
        let preview = incomplete.inspect(f.worktree)
        XCTAssertFalse(preview.complete)
        XCTAssertFalse(preview.canRemove)
        XCTAssertFalse(incomplete.remove(preview, source: .discard, after: cleared).ok)
        let failingBackup = DevboxClearWorktree(command: { executable, arguments, timeout in
            executable == "/usr/bin/tar" ? .init(ok: false, stdout: "", stderr: "backup refused") : Self.run(executable, arguments, timeout)
        }, backupRoot: f.policy.backupRoot)
        XCTAssertFalse(failingBackup.remove(failingBackup.inspect(f.worktree), source: .backup, after: cleared).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path))
    }

    func testBackupRestoresStagedContentAbsentFromWorkingFiles() throws {
        let f = try fixture()
        let path = f.worktree.appending(path: "tracked.txt")
        let binary = f.worktree.appending(path: "binary.dat")
        try write("original\n", at: path)
        try write("\0original", at: binary)
        try write("staged deletion", at: f.worktree.appending(path: "deleted-staged.txt"))
        try write("unstaged deletion", at: f.worktree.appending(path: "deleted-unstaged.txt"))
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "add", "."], 30).ok)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "tracked"], 30).ok)
        try write("staged replacement\n", at: path)
        try write("\0staged", at: binary)
        try FileManager.default.removeItem(at: f.worktree.appending(path: "deleted-staged.txt"))
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", f.worktree.path, "add", "tracked.txt", "binary.dat", "deleted-staged.txt"], 30).ok)
        try FileManager.default.removeItem(at: f.worktree.appending(path: "deleted-unstaged.txt"))
        let stagedBlob = Self.run("/usr/bin/git", ["-C", f.worktree.path, "rev-parse", ":tracked.txt"], 30).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try write("original\n", at: path)
        try write("\0original", at: binary)
        let outcome = f.policy.remove(f.policy.inspect(f.worktree), source: .backup, after: cleared)
        XCTAssertTrue(outcome.ok, outcome.log)
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.policy.backupRoot, includingPropertiesForKeys: nil).first)
        let clone = f.root.appending(path: "recovery-repository")
        XCTAssertTrue(Self.run("/usr/bin/git", ["clone", "--no-local", "--single-branch", "--branch", "qa-clear", f.root.path, clone.path], 30).ok)
        XCTAssertFalse(Self.run("/usr/bin/git", ["-C", clone.path, "cat-file", "-e", stagedBlob], 30).ok)
        let restored = clone.appending(path: ".worktrees/restored")
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", clone.path, "worktree", "add", "--no-checkout", "-b", "qa-restored", restored.path, "qa-clear"], 30).ok)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", restored.path, "read-tree", "HEAD"], 30).ok)
        XCTAssertTrue(Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", restored.path, "--exclude=./.git"], 30).ok)
        let recovery = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: restored, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".pultik-clear-recovery-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appending(path: "index.saved").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appending(path: "RESTORE.txt").path))
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", restored.path, "apply", "--cached", recovery.appending(path: "staged.patch").path], 30).ok)
        XCTAssertTrue(Self.run("/usr/bin/git", ["-C", restored.path, "show", ":tracked.txt"], 30).stdout.contains("staged replacement"))
        XCTAssertEqual(Self.run("/usr/bin/git", ["-C", restored.path, "show", ":binary.dat"], 30).stdout, "\0staged")
        XCTAssertEqual(try String(contentsOf: restored.appending(path: "tracked.txt")), "original\n")
        XCTAssertEqual(try String(contentsOf: restored.appending(path: "binary.dat")), "\0original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appending(path: "deleted-staged.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appending(path: "deleted-unstaged.txt").path))
        let indexed = Self.run("/usr/bin/git", ["-C", restored.path, "ls-files"], 30).stdout
        XCTAssertFalse(indexed.contains("deleted-staged.txt"))
        XCTAssertTrue(indexed.contains("deleted-unstaged.txt"))
    }

    func testInspectionBudgetKeepsSourceWhenExceeded() throws {
        let f = try fixture()
        try write("first", at: f.worktree.appending(path: "one.txt"))
        try write("second", at: f.worktree.appending(path: "two.txt"))
        var policy = f.policy
        policy.maximumPaths = 1
        let large = policy.inspect(f.worktree)
        XCTAssertFalse(large.complete)
        XCTAssertFalse(large.canRemove)
        XCTAssertTrue(large.explanation.contains("exceeds 1 paths"))
        // The deletion guard gave up; the changes summary still reads.
        XCTAssertTrue(large.changesRead)
        XCTAssertEqual(DevboxClearSummary(large).files.map(\.kind), ["?", "?"])
        policy.inspectionSeconds = 0
        let timedOut = policy.inspect(f.worktree)
        XCTAssertFalse(timedOut.complete)
        XCTAssertFalse(timedOut.canRemove)
        XCTAssertTrue(timedOut.log.contains("budget"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path))
    }
}
