import Foundation

struct DevboxClearCommandResult: Sendable {
    let ok: Bool
    let stdout: String
    let stderr: String
}

/// Source inspection/removal policy. The app supplies its bounded process
/// runner; Foundation tests use disposable Git repositories and the same policy.
struct DevboxClearWorktree: Sendable {
    let command: @Sendable (String, [String], Int) -> DevboxClearCommandResult
    var backupRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Backups/pultik-worktrees")
    var maximumPaths = 20_000
    var inspectionSeconds: TimeInterval = 10

    func inspect(_ directory: URL) -> DevboxClearPreview {
        let path = directory.path
        let deadline = Date().addingTimeInterval(inspectionSeconds)
        func git(_ arguments: [String]) -> DevboxClearCommandResult {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .init(ok: false, stdout: "", stderr: "Inspection exceeded its \(inspectionSeconds)s budget; local source kept.\n") }
            return command("/usr/bin/git", arguments, max(1, Int(ceil(remaining))))
        }
        let status = git(["-C", path, "status", "--short", "--untracked-files=all"])
        let diffArgs = ["--no-ext-diff", "--no-textconv", "--", ".", ":(exclude)**/.env*", ":(exclude)**/*.pem", ":(exclude)**/*.key"]
        let staged = git(["-C", path, "diff", "--cached"] + diffArgs)
        let unstaged = git(["-C", path, "diff"] + diffArgs)
        let diff = [("Staged changes", staged.stdout), ("Unstaged changes", unstaged.stdout)]
            .filter { !$0.1.isEmpty }.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n")
        let upstream = git(["-C", path, "rev-parse", "--verify", "@{upstream}"])
        let commits = upstream.ok ? git(["-C", path, "log", "--oneline", "@{upstream}..HEAD"])
            : git(["-C", path, "log", "--oneline", "HEAD", "--not", "--remotes"])
        let common = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let commonDir = URL(filePath: common.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let top = git(["-C", path, "rev-parse", "--show-toplevel"])
        let gitDir = git(["-C", path, "rev-parse", "--absolute-git-dir"])
        let locked = FileManager.default.fileExists(atPath: gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "/locked")
        // Include ignored files in the deletion guard, without reading or
        // displaying their contents. Missing metadata fails closed.
        let names = git(["-C", path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        let ignored = git(["-C", path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"])
        let paths = (names.stdout + ignored.stdout).split(separator: "\0")
        let overLimit = paths.count > maximumPaths
        let inventory = overLimit ? Set<String>() : Set(paths.map(String.init))
        var stamp: [String] = [], inspectionErrors: [String] = []
        if overLimit { inspectionErrors.append("Inspection exceeds \(maximumPaths) paths; local source kept. Clear this can still clear its runtime.") }
        for name in inventory.sorted() {
            guard Date() < deadline else {
                inspectionErrors.append("Inspection exceeded its \(inspectionSeconds)s budget; local source kept.")
                break
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
                guard let date = attributes[.modificationDate] as? Date else {
                    inspectionErrors.append("Could not inspect metadata for \(name)")
                    continue
                }
                stamp.append("\(name):\(date.timeIntervalSince1970):\(attributes[.size] ?? 0):\(attributes[.type] ?? "unknown")")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    stamp.append("\(name):absent")
                } else {
                    inspectionErrors.append("Could not inspect \(name): \(error.localizedDescription)")
                }
            }
        }
        let identity = git(["-C", path, "rev-parse", "HEAD"])
        let branch = git(["-C", path, "symbolic-ref", "--quiet", "HEAD"])
        // Git may rewrite index stat caches during inspection. Compare its
        // entries and flags instead; this also guards staged secret files
        // whose contents are intentionally absent from the displayed diff.
        let index = git(["-C", path, "ls-files", "--stage", "-z"])
        let indexFlags = git(["-C", path, "ls-files", "-v", "-z"])
        let complete = status.ok && staged.ok && unstaged.ok && commits.ok && common.ok && top.ok && gitDir.ok
            && identity.ok && names.ok && ignored.ok && index.ok && indexFlags.ok && names.stderr.isEmpty && ignored.stderr.isEmpty && inspectionErrors.isEmpty
        let linked = complete && commonDir.lastPathComponent == ".git"
            && commonDir.deletingLastPathComponent().resolvingSymlinksInPath().path != directory.resolvingSymlinksInPath().path
            && URL(filePath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path && !locked
        let anchored = branch.ok && branch.stdout.hasPrefix("refs/heads/")
        let clean = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let explanation = !complete ? (inspectionErrors.first ?? "Git could not fully inspect this source. It will be kept.")
            : linked && !anchored ? "This checkout has a detached HEAD. Local source will be kept to preserve its commits."
            : linked ? (clean ? "No modified or untracked files." : "Local changes are listed below. Keeping source preserves all of them.")
            : "This is a primary checkout or an unavailable worktree. Local source will be kept."
        let fingerprint = status.stdout + diff + commits.stdout + stamp.joined(separator: "\n") + identity.stdout + branch.stdout + common.stdout + index.stdout + indexFlags.stdout
        let identityErrors = [common.stderr, top.stderr, gitDir.stderr, identity.stderr, branch.stderr, index.stderr, indexFlags.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let log = "$ git status --short\n\(status.stdout)\(status.stderr)\n$ git diff --cached / git diff (secret files excluded)\n\(diff)\(staged.stderr)\(unstaged.stderr)\n$ git log (local commits; remote refs may be stale)\n\(commits.stdout)\(commits.stderr)\nDeletion guard: \(inventory.count) tracked, untracked and ignored paths inspected.\n\(names.stderr)\(ignored.stderr)\(inspectionErrors.joined(separator: "\n"))\nGit identity/index inspection:\n\(identityErrors)"
        return DevboxClearPreview(path: path, status: status.stdout, diff: diff, commits: commits.stdout,
                                  canRemove: linked && anchored, complete: complete,
                                  explanation: explanation, fingerprint: fingerprint, log: log)
    }

    func remove(_ preview: DevboxClearPreview, source: DevboxClearSourceAction, after report: DevboxClearReport) -> DevboxClearReport {
        guard report.ok, source != .keep else { return report }
        guard let path = preview.path else { return .failure("Runtime cleared; unavailable local source kept.", log: report.log) }
        let current = inspect(URL(filePath: path))
        guard current.complete, current.canRemove, current.fingerprint == preview.fingerprint else {
            return .failure("Runtime cleared. Local source was kept because the worktree changed during clearing or could not be inspected.", log: report.log + "\n\n" + current.log)
        }
        var log = report.log
        if source == .backup {
            switch backup(path) {
            case .success(let archive): log += "\n\nLocal worktree backed up at \(archive), including staged changes and RESTORE.txt instructions."
            case .failure(let error): return .failure("Runtime cleared. Worktree kept: backup failed.", log: log + "\n\n" + error.localizedDescription)
            }
            let checked = inspect(URL(filePath: path))
            guard checked.complete, checked.canRemove, checked.fingerprint == preview.fingerprint else {
                return .failure("Runtime cleared and backup saved. Worktree kept because local work changed during the backup.", log: log)
            }
        }
        let common = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let clone = URL(filePath: common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
        guard common.ok, clone.standardizedFileURL.resolvingSymlinksInPath().path != URL(filePath: path).resolvingSymlinksInPath().path else {
            return .failure("Runtime cleared; local source kept because its linked-worktree identity could not be verified.", log: log)
        }
        let removal = git(["-C", clone.path, "worktree", "remove", "--force", "--", path], timeout: 120)
        log += "\n\n$ git worktree remove --force -- \(path)\n\(removal.stdout)\n\(removal.stderr)"
        return DevboxClearReport(ok: removal.ok, summary: removal.ok ? "Workspace cleared; branch retained in its repository." : "Runtime cleared. Git refused to remove the worktree; see its explanation below.", diagnostics: report.diagnostics, next: report.next, log: log)
    }

    private func backup(_ path: String) -> Result<String, Error> {
        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let conflicts = git(["-C", path, "ls-files", "--unmerged"])
            let head = git(["-C", path, "rev-parse", "HEAD"])
            let gitDir = git(["-C", path, "rev-parse", "--absolute-git-dir"])
            guard conflicts.ok, conflicts.stdout.isEmpty, head.ok, gitDir.ok else {
                throw NSError(domain: "PultikClear", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot make a restorable index backup (resolve Git conflicts first). Local source is kept."])
            }
            let recovery = backupRoot.appending(path: ".pultik-clear-recovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer {
                do { try FileManager.default.removeItem(at: recovery) }
                catch { NSLog("pultik: backup recovery staging cleanup failed: %@", error.localizedDescription) }
            }
            let index = URL(filePath: gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).appending(path: "index")
            if FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.copyItem(at: index, to: recovery.appending(path: "index.saved"))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recovery.appending(path: "index.saved").path)
            }
            let patch = recovery.appending(path: "staged.patch")
            guard FileManager.default.createFile(atPath: patch.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "PultikClear", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create private staged-change backup."])
            }
            // Save binary content directly to a private file, never into a UI
            // log. Applying this patch recreates staged blobs from retained HEAD.
            let staged = git(["-C", path, "diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--output=" + patch.path, "HEAD", "--"])
            guard staged.ok else { throw NSError(domain: "PultikClear", code: 1, userInfo: [NSLocalizedDescriptionKey: "Staged-change backup failed: " + staged.stderr]) }
            let instructions = """
            Create a new linked worktree without checking out HEAD's working files:
            git worktree add --no-checkout -b <new-branch> <new-directory> \(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            In that new worktree run: git read-tree HEAD
            Then extract this archive there, excluding its old .git pointer:
            tar -xzf <archive> --exclude=./.git
            From the new worktree run: git apply --cached <recovery-directory>/staged.patch
            (Skip the apply when staged.patch is empty.) This recreates the staged objects and index,
            including changes absent from working files. Deleted working files remain absent,
            because --no-checkout never created them. Do not overlay an existing checkout.
            index.saved also preserves the original index flags; after applying the patch, it can
            replace the index path printed by: git rev-parse --git-path index
            Keep this archive private: it includes ignored files and complete staged content.
            """
            try Data(instructions.utf8).write(to: recovery.appending(path: "RESTORE.txt"))
            let target = backupRoot.appending(path: "\(URL(filePath: path).lastPathComponent)-\(UUID().uuidString).tar.gz")
            let partial = target.appendingPathExtension("partial")
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return .failure(NSError(domain: "PultikClear", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a private backup file."]))
            }
            let result = command("/usr/bin/tar", ["-czf", partial.path, "-C", path, ".", "-C", backupRoot.path, recovery.lastPathComponent], 300)
            guard result.ok else {
                try FileManager.default.removeItem(at: partial)
                return .failure(NSError(domain: "PultikClear", code: 1, userInfo: [NSLocalizedDescriptionKey: result.stderr]))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
            let file = try FileHandle(forWritingTo: partial)
            try file.synchronize()
            try file.close()
            try FileManager.default.moveItem(at: partial, to: target)
            return .success(target.path)
        } catch {
            NSLog("pultik: worktree backup failed: %@", error.localizedDescription)
            return .failure(error)
        }
    }

    private func git(_ arguments: [String], timeout: Int = 30) -> DevboxClearCommandResult {
        command("/usr/bin/git", arguments, timeout)
    }
}
