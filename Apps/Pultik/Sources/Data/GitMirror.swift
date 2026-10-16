import CodeCore
import Foundation

/// Pultík's own git mirror (stay in Pultík D10): a bare partial clone per
/// repo under `~/Library/Caches/Pultik/git/<owner>/<repo>.git`, fetching the
/// warm set's PR heads and base branches over https, so diffs, commits and
/// workflow YAML are read locally — complete, without REST budget, and
/// never touching the operator's checkouts.
///
/// Blobless (`--filter=blob:none`), not treeless: a diff walks trees, and a
/// treeless clone fetches each missing tree in its own round trip, while a
/// blobless one already holds them and fetches the changed blobs in one
/// batch. Git runs at background QoS, one command per repo at a time, with
/// no global or system config (no `insteadOf` turning https into SSH, no
/// keychain helper storing the token), its HOME inside the mirror root, and
/// the token handed to `GIT_ASKPASS` through the child's environment only.
/// Code search (PR workbench D3) backfills a head's whole tree once, then
/// `grep` and the symbol index read it without a round trip; those reads
/// refuse lazy fetches, so a missing blob fails loudly instead of costing
/// one request each.
/// Foundation-only: `Tests/GitMirrorTests.swift` drives it against a
/// disposable `file://` remote.
actor GitMirror {
    static let shared = GitMirror(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pultik/git", isDirectory: true))

    enum Failure: Error, LocalizedError {
        case git(arguments: [String], status: Int32, stderr: String)
        case timedOut([String])
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .git(arguments, status, stderr):
                "git \(arguments.prefix(2).joined(separator: " ")) exited \(status): \(stderr.prefix(300))"
            case let .timedOut(arguments): "git \(arguments.prefix(2).joined(separator: " ")) timed out"
            case let .missing(what): "\(what) is not in the mirror"
            }
        }
    }

    let root: URL
    /// The whole mirror's ceiling; past it the least recently used repos go.
    let capBytes: Int64
    /// A repo nobody read for this long is removed.
    let idleEviction: TimeInterval
    private let git: URL
    private let timeout: TimeInterval
    /// One git command per repo at a time (D10): each repo's work chains on
    /// the one before it.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Commands queued or running per repo: eviction leaves these alone.
    private var inFlight: [String: Int] = [:]
    /// Repos whose `origin` this run already set.
    private var prepared: Set<String> = []
    /// Backfills in flight by repo@head: a search and the symbol index
    /// asking at once share one.
    private var backfills: [String: Task<Void, Error>] = [:]
    /// Backfilled this run: a search then spends no process on the marker.
    /// Eviction clears it.
    private var backfilled: Set<String> = []
    private(set) var fetches = 0

    /// Blobs per backfill fetch: thousands per round trip, yet small enough
    /// that a diff of the same repo gets its turn between batches.
    static let backfillBatch = 5_000
    /// A batch can be tens of MB on a slow link.
    static let fetchTimeout: TimeInterval = 600
    /// How many heads' backfill markers a repo keeps.
    static let backfillMarkers = 16
    /// Reads that must not fetch: a missing object fails them at once rather
    /// than costing one request per object.
    private static let localOnly = ["GIT_NO_LAZY_FETCH": "1"]

    /// The cap is 4 GB since whole-repo search (PR workbench D3) keeps head trees' blobs.
    init(root: URL, capBytes: Int64 = 4 << 30, idleEviction: TimeInterval = 14 * 86400,
         git: URL = URL(fileURLWithPath: "/usr/bin/git"), timeout: TimeInterval = 180) {
        self.root = root
        self.capBytes = capBytes
        self.idleEviction = idleEviction
        self.git = git
        self.timeout = timeout
    }

    /// `owner/repo` → its bare repository. Path components never climb out
    /// of the root.
    func path(_ repo: String) -> URL {
        let parts = repo.split(separator: "/").map { $0.replacingOccurrences(of: "..", with: "_") }
        return parts.dropLast().reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
            .appendingPathComponent("\(parts.last ?? "repo").git", isDirectory: true)
    }

    func hasRepo(_ repo: String) -> Bool {
        FileManager.default.fileExists(atPath: path(repo).appendingPathComponent("HEAD").path)
    }

    // MARK: - Change sets

    /// The change set of `request` at exactly `base...head`: its head and
    /// base fetched when the mirror lacks either commit, then a local diff.
    /// The same budgets as the host's (`ChangeSet.bounded`), never its
    /// 300-file cap.
    func changeSet(for request: ChangeRequest, remote: URL, password: String?) async throws -> ChangeSet {
        let repo = request.ref.repo
        try await prepare(repo, remote: remote)
        let hasHead = await hasCommit(repo, request.headSHA)
        let hasBase = await hasCommit(repo, request.baseSHA)
        if !hasHead || !hasBase {
            try await fetch(repo, refspecs: ["+refs/pull/\(request.number)/head:refs/pull/\(request.number)/head",
                                             "+refs/heads/\(request.baseRef):refs/remotes/origin/\(request.baseRef)"],
                            password: password)
        }
        // A force-push moved the ref past the commit the conversation names:
        // ask for the commits themselves.
        for sha in [request.headSHA, request.baseSHA] where !(await hasCommit(repo, sha)) {
            try await fetch(repo, refspecs: [sha], password: password)
        }
        return try await diff(repo, base: request.baseSHA, head: request.headSHA, password: password)
    }

    /// `base...head` as the host's "Files changed": the merge base against
    /// the head, renames found, missing blobs fetched in one batch — so both
    /// sides' blobs, named by `--full-index`, are local for highlighting.
    func diff(_ repo: String, base: String, head: String, password: String?) async throws -> ChangeSet {
        let output = try await run(repo, Self.diffArguments + ["\(base)...\(head)"], password: password)
        touch(repo)
        return ChangeSet.bounded(Self.parse(diff: String(decoding: output, as: UTF8.self)), truncated: false,
                                 lineLimit: ChangeSet.mirrorLineLimit, byteBudget: ChangeSet.mirrorByteBudget)
    }

    /// One commit's own change set — Files changed scoped to a commit
    /// (PR workbench S9): against its first parent, a root against the empty
    /// tree, with `diff`'s flags and budgets so both sides' blobs are named.
    func commitChangeSet(_ repo: String, sha: String, password: String?) async throws -> ChangeSet {
        let listed = try await run(repo, ["rev-list", "--no-walk", "--parents", "-n", "1", sha], password: nil,
                                   options: Invocation(environment: Self.localOnly)).stdout
        let ids = String(decoding: listed, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let commit = ids.first else { throw Failure.missing("commit \(sha)") }
        let output = try await run(repo, Self.diffArguments + [ids.dropFirst().first ?? Self.emptyTree, commit],
                                   password: password)
        touch(repo)
        return ChangeSet.bounded(Self.parse(diff: String(decoding: output, as: UTF8.self)), truncated: false,
                                 lineLimit: ChangeSet.mirrorLineLimit, byteBudget: ChangeSet.mirrorByteBudget)
    }

    private static let diffArguments = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff",
                                        "--find-renames", "--full-index", "--unified=3", "--src-prefix=a/",
                                        "--dst-prefix=b/"]
    /// Git knows this tree without holding it: what a root commit diffs against.
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // MARK: - Commits

    /// `base..head` oldest first — the Commits tab (PR workbench S9) — each
    /// with its numstat totals against its first parent. The first read is
    /// local only; when it needs blobs the mirror lacks (a blobless clone
    /// holds only what earlier diffs walked), every blob the range touched
    /// comes in one batched fetch and the log reads again — never a round
    /// trip per commit.
    func log(_ repo: String, base: String, head: String, password: String?) async throws -> [ChangeCommit] {
        let range = "\(base)..\(head)"
        let arguments = ["-c", "core.quotePath=false", "log", "--reverse", "--topo-order", "--no-color",
                         "--diff-merges=first-parent", "--numstat", "--format=\(Self.logFormat)", range]
        let output: Data
        do {
            output = try await run(repo, arguments, password: nil, options: Invocation(environment: Self.localOnly)).stdout
        } catch Failure.git {
            // Blobs are missing (or the range is bad, which the next read throws again).
            try await prefetchChanges(repo, range: range, password: password)
            output = try await run(repo, arguments, password: password)
        }
        touch(repo)
        return Self.parse(log: output)
    }

    /// Every blob the commits of `range` changed, fetched where missing.
    /// The raw listing names them without reading any.
    private func prefetchChanges(_ repo: String, range: String, password: String?) async throws {
        let raw = try await run(repo, ["log", "--format=", "--raw", "--no-abbrev", "--no-renames",
                                       "--diff-merges=first-parent", range],
                                password: nil, options: Invocation(environment: Self.localOnly)).stdout
        var wanted: [String] = []
        var seen: Set<String> = []
        // `:100644 100644 <old> <new> M\tpath`; a submodule (160000) names a commit.
        for line in String(decoding: raw, as: UTF8.self).split(separator: "\n") where line.hasPrefix(":") {
            let fields = line.dropFirst().split(separator: " ", maxSplits: 4)
            guard fields.count == 5 else { continue }
            for (mode, id) in [(fields[0], fields[2]), (fields[1], fields[3])]
            where mode != "160000" && !id.allSatisfy({ $0 == "0" }) && seen.insert(String(id)).inserted {
                wanted.append(String(id))
            }
        }
        try await fetchMissing(repo, wanted, password: password)
    }

    /// NUL-led fields, then the numstat text up to the next commit's NUL: no
    /// subject or body can hold a NUL, and without `-z` numstat quotes paths.
    private static let logFormat = "%x00%H%x00%P%x00%an%x00%at%x00%s%x00%b%x00"

    /// `log`'s output → commits: after the leading NUL, seven tokens each —
    /// sha, parents, author, author time, subject, body, numstat.
    static func parse(log output: Data) -> [ChangeCommit] {
        let tokens = output.split(separator: 0, omittingEmptySubsequences: false).dropFirst()
            .map { String(decoding: $0, as: UTF8.self) }
        return stride(from: tokens.startIndex, to: tokens.endIndex - 6, by: 7).map { start in
            var additions = 0
            var deletions = 0
            var files = 0
            for line in tokens[start + 6].split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { continue }
                // A binary file reads `-\t-`: a file without lines.
                additions += Int(fields[0]) ?? 0
                deletions += Int(fields[1]) ?? 0
                files += 1
            }
            return ChangeCommit(sha: tokens[start], parents: tokens[start + 1].split(separator: " ").map(String.init),
                                author: tokens[start + 2],
                                date: Date(timeIntervalSince1970: TimeInterval(tokens[start + 3]) ?? 0),
                                subject: tokens[start + 4],
                                body: tokens[start + 5].trimmingCharacters(in: .whitespacesAndNewlines),
                                additions: additions, deletions: deletions, files: files)
        }
    }

    // MARK: - Code search

    /// Makes every blob of `head`'s tree local (PR workbench D3), so `grep`
    /// and the symbol index read the whole repo without a round trip per
    /// blob. Once per repo@head: a marker in the repo remembers it.
    ///
    /// Not `git backfill`: it takes no revision (git 2.50) and walks HEAD's
    /// whole history, every past version of every file. Instead the tree's
    /// blobs (`ls-tree`, trees are local) minus what the mirror holds are
    /// fetched by id, `backfillBatch` per fetch, at background QoS.
    func backfill(_ repo: String, head: String, password: String?) async throws {
        let key = "\(repo)@\(head)"
        guard !backfilled.contains(key) else { return }
        if let flight = backfills[key] { return try await flight.value }
        let flight = Task { try await self.fill(repo, head: head, password: password) }
        backfills[key] = flight
        defer { backfills[key] = nil }
        try await flight.value
        backfilled.insert(key)
    }

    private func fill(_ repo: String, head: String, password: String?) async throws {
        let resolved = try await run(repo, ["rev-parse", "--verify", "--quiet", "\(head)^{commit}"], password: nil,
                                     options: Invocation(environment: Self.localOnly)).stdout
        let sha = String(decoding: resolved, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty, sha.allSatisfy(\.isHexDigit) else { throw Failure.missing("commit \(head)") }
        let markers = path(repo).appendingPathComponent("pultik-backfilled", isDirectory: true)
        let marker = markers.appendingPathComponent(sha)
        if FileManager.default.fileExists(atPath: marker.path) {
            touch(repo)
            return
        }
        let tree = try await run(repo, ["ls-tree", "-r", "-z", "--format=%(objecttype) %(objectname)", sha],
                                 password: nil, options: Invocation(environment: Self.localOnly)).stdout
        var blobs: [String] = []
        var seen: Set<String> = []
        // Path order, so each batch's pack deltas similar files together.
        for entry in tree.split(separator: 0) {
            let line = String(decoding: entry, as: UTF8.self)
            guard line.hasPrefix("blob ") else { continue }
            let id = String(line.dropFirst(5))
            if seen.insert(id).inserted { blobs.append(id) }
        }
        try await fetchMissing(repo, blobs, password: password)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: marker.path, contents: nil) else {
            throw Failure.missing("backfill marker \(marker.path)")
        }
        pruneMarkers(markers)
        touch(repo)
    }

    /// The newest `backfillMarkers` stay; an older head backfills again
    /// (cheaply: its blobs are mostly local).
    private func pruneMarkers(_ directory: URL) {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let entries = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)),
              entries.count > Self.backfillMarkers else { return }
        let dated = entries.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.backfillMarkers) {
            do {
                try files.removeItem(at: url)
            } catch {
                NSLog("pultik: mirror marker %@ not pruned: %@", url.path, error.localizedDescription)
            }
        }
    }

    /// Fetches the objects among `ids` the mirror lacks, by id, the way
    /// git's own lazy fetch asks (no negotiation, the clone's filter), in
    /// `backfillBatch`es. What it holds comes from one pass over every
    /// object: asking per id costs a rescan of the pack directory for each
    /// missing one (21 s for ExampleApp's 13k against 0.5 s).
    private func fetchMissing(_ repo: String, _ ids: [String], password: String?) async throws {
        guard !ids.isEmpty else { return }
        var missing = Set(ids)
        let present = try await run(repo, ["cat-file", "--batch-all-objects", "--unordered", "--batch-check=%(objectname)"],
                                    password: nil, options: Invocation(environment: Self.localOnly)).stdout
        for line in present.split(separator: 0x0A) where !missing.isEmpty {
            missing.remove(String(decoding: line, as: UTF8.self))
        }
        let wanted = ids.filter { missing.contains($0) }
        for start in stride(from: 0, to: wanted.count, by: Self.backfillBatch) {
            let batch = wanted[start ..< min(start + Self.backfillBatch, wanted.count)]
            fetches += 1
            try await run(repo, ["-c", "protocol.version=2", "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet",
                                 "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none",
                                 "--stdin", "origin"], password: password,
                          options: Invocation(input: Data((batch.joined(separator: "\n") + "\n").utf8),
                                              timeout: Self.fetchTimeout))
        }
        touch(repo)
    }

    /// Every path in `head`'s tree.
    func paths(_ repo: String, head: String) async throws -> [String] {
        let output = try await run(repo, ["ls-tree", "-r", "--name-only", "-z", head], password: nil,
                                   options: Invocation(environment: Self.localOnly)).stdout
        touch(repo)
        return output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The text of each of `paths` at `head` in two `cat-file` reads — the
    /// symbol index reads thousands of files, and a process each would take
    /// minutes. Files past `byteLimit`, missing or not blobs are left out;
    /// local only, so backfill first.
    func texts(_ repo: String, head: String, paths: [String], byteLimit: Int) async throws -> [(path: String, text: String)] {
        // `cat-file` reads one name per line.
        let named = paths.filter { !$0.contains("\n") }
        guard !named.isEmpty else { return [] }
        let checked = try await run(repo, ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                                    password: nil,
                                    options: Invocation(input: Data(named.map { "\(head):\($0)\n" }.joined().utf8),
                                                        environment: Self.localOnly)).stdout
        var blobs: [(path: String, id: String)] = []
        for (path, line) in zip(named, checked.split(separator: 0x0A, omittingEmptySubsequences: false)) {
            let fields = String(decoding: line, as: UTF8.self).split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", let size = Int(fields[2]), size <= byteLimit else { continue }
            blobs.append((path, String(fields[0])))
        }
        guard !blobs.isEmpty else { return [] }
        let ids = Array(Set(blobs.map(\.id)))
        let contents = try await run(repo, ["cat-file", "--batch"], password: nil,
                                     options: Invocation(input: Data(ids.map { "\($0)\n" }.joined().utf8),
                                                         environment: Self.localOnly)).stdout
        let byID = Self.parse(batch: contents)
        touch(repo)
        return blobs.compactMap { blob in byID[blob.id].map { (blob.path, String(decoding: $0, as: UTF8.self)) } }
    }

    /// `cat-file --batch` output → each object's bytes by id:
    /// `<id> <type> <size>\n<bytes>\n`, or `<id> missing\n`.
    static func parse(batch output: Data) -> [String: Data] {
        var objects: [String: Data] = [:]
        var index = output.startIndex
        while index < output.endIndex, let newline = output[index...].firstIndex(of: 0x0A) {
            let header = String(decoding: output[index ..< newline], as: UTF8.self).split(separator: " ")
            index = output.index(after: newline)
            guard header.count == 3, let size = Int(header[2]), output.endIndex - index >= size else { continue }
            objects[String(header[0])] = output.subdata(in: index ..< index + size)
            index += size + 1
        }
        return objects
    }

    /// Every match of `query` in `head`'s tree (PR workbench S13): `git grep`
    /// over the tree, no checkout, binary files skipped, local only — so
    /// `backfill` first (`CodeSearch` does). A regex is Perl-compatible (this
    /// git's `-E` has no `\b` or `\d`), and the line reads as UTF-8 so
    /// case folding and `.` see characters, not bytes.
    ///
    /// One hit per match. Git reports a line's first match; the rest are
    /// found in the line by the code core (`GrepCollector`; git's own `-o`
    /// prints wrong columns past the first match). At most `limit` hits: git
    /// stops once they are in, so exactly `limit` means there may be more.
    ///
    /// User-initiated QoS, unlike the mirror's other work: the operator is
    /// waiting, and at background QoS ExampleApp's search takes 1.4–2.2 s
    /// instead of 0.22 s.
    func grep(_ repo: String, head: String, query: String, options: SearchOptions, paths: [String]? = nil,
              limit: Int = 2000) async throws -> [GrepHit] {
        guard !query.isEmpty, limit > 0, paths?.isEmpty != true else { return [] }
        var arguments = ["--literal-pathspecs", "grep", "-n", "--column", "-I", "--no-color", "-z"]
        if !options.caseSensitive { arguments.append("-i") }
        if options.wholeWord { arguments.append("-w") }
        arguments += [options.regex ? "-P" : "-F", "-e", query, head, "--"] + (paths ?? [])
        let collector = try GrepCollector(head: head, limit: limit, query: query, options: options)
        let output = try await run(repo, arguments, password: nil,
                                   options: Invocation(environment: Self.localOnly.merging(["LC_ALL": "en_US.UTF-8"]) { $1 },
                                                       qos: .userInitiated, record: { collector.add($0) },
                                                       answers: [0, 1]))
        // Exit 1 is "no match" — unless git also could not read a blob.
        let problem = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !problem.isEmpty, !output.stopped {
            NSLog("pultik: mirror grep %@ failed: %@", repo, problem)
            throw Failure.git(arguments: arguments, status: output.status, stderr: problem)
        }
        touch(repo)
        return try collector.hits()
    }

    /// One blob's bytes — a side of a diff the code canvas highlights
    /// whole. Local after `diff`; a missing one is fetched on demand.
    func blob(_ repo: String, sha: String, password: String?) async throws -> Data {
        let output = try await run(repo, ["cat-file", "blob", sha], password: password)
        touch(repo)
        return output
    }

    /// A file at a commit — the workflow YAML a run's job graph reads.
    func file(_ repo: String, path: String, at sha: String, remote: URL, password: String?) async throws -> String {
        try await prepare(repo, remote: remote)
        if !(await hasCommit(repo, sha)) { try await fetch(repo, refspecs: [sha], password: password) }
        let output = try await run(repo, ["cat-file", "blob", "\(sha):\(path)"], password: password)
        touch(repo)
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Git

    /// A bare repository whose `origin` is `remote`; idempotent.
    func prepare(_ repo: String, remote: URL) async throws {
        let directory = path(repo)
        if !hasRepo(repo) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = try await command(["init", "--bare", "--quiet", directory.path], in: root, password: nil, Invocation())
        }
        guard !prepared.contains(repo) else { return }
        _ = try await run(repo, ["config", "remote.origin.url", remote.absoluteString], password: nil)
        prepared.insert(repo)
    }

    func fetch(_ repo: String, refspecs: [String], password: String?) async throws {
        fetches += 1
        _ = try await run(repo, ["-c", "protocol.version=2", "fetch", "--quiet", "--no-tags", "--no-write-fetch-head",
                                 "--filter=blob:none", "origin"] + refspecs, password: password)
        touch(repo)
    }

    func hasCommit(_ repo: String, _ sha: String) async -> Bool {
        guard !sha.isEmpty, hasRepo(repo) else { return false }
        return (try? await run(repo, ["cat-file", "-e", "\(sha)^{commit}"], password: nil)) != nil
    }

    /// What one git command is handed beyond its arguments.
    struct Invocation: Sendable {
        /// Fed to stdin from a file under the root: a pipe the child stops
        /// reading would raise SIGPIPE in the app.
        var input: Data?
        var environment: [String: String] = [:]
        var qos: QualityOfService = .background
        var timeout: TimeInterval?
        /// Handed each `\n`-terminated stdout record as it arrives; false
        /// stops the child, keeping what it handed over. Stdout is then not
        /// collected.
        var record: (@Sendable (Data) -> Bool)?
        /// Exit statuses that answer rather than fail (`git grep`'s 1).
        var answers: Set<Int32> = [0]
    }

    /// What one git command printed.
    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let status: Int32
        /// `Invocation.record` stopped it.
        let stopped: Bool
    }

    /// One git command in `repo`, after the repo's previous one.
    @discardableResult
    func run(_ repo: String, _ arguments: [String], password: String?) async throws -> Data {
        try await run(repo, arguments, password: password, options: Invocation()).stdout
    }

    @discardableResult
    func run(_ repo: String, _ arguments: [String], password: String?, options: Invocation) async throws -> Output {
        let previous = tails[repo]
        let directory = path(repo)
        let work = Task { () throws -> Output in
            await previous?.value
            return try await command(arguments, in: directory, password: password, options)
        }
        tails[repo] = Task { _ = try? await work.value }
        inFlight[repo, default: 0] += 1
        defer {
            inFlight[repo, default: 1] -= 1
            if inFlight[repo] == 0 {
                inFlight[repo] = nil
                tails[repo] = nil
            }
        }
        return try await work.value
    }

    private func command(_ arguments: [String], in directory: URL, password: String?,
                         _ options: Invocation) async throws -> Output {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let askpass = try askpassScript()
        var environment = [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": askpass.path, "GIT_OPTIONAL_LOCKS": "0",
        ]
        environment.merge(options.environment) { $1 }
        if let password { environment["PULTIK_GIT_PASSWORD"] = password }
        let full = ["-c", "credential.helper=", "-c", "maintenance.auto=false", "-c", "gc.auto=0"] + arguments
        var inputFile: URL?
        if let input = options.input {
            let url = root.appendingPathComponent(".stdin-\(UUID().uuidString)")
            try input.write(to: url)
            inputFile = url
        }
        defer {
            if let inputFile {
                do {
                    try FileManager.default.removeItem(at: inputFile)
                } catch {
                    NSLog("pultik: mirror stdin %@ not removed: %@", inputFile.path, error.localizedDescription)
                }
            }
        }
        let git = git
        let timeout = options.timeout ?? timeout
        let qos = options.qos
        let queue = DispatchQueue.global(qos: qos.dispatchClass)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = git
                process.arguments = full
                process.currentDirectoryURL = directory
                process.environment = environment
                process.qualityOfService = qos
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    process.standardInput = try inputFile.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                var output = (stdout: Data(), stderr: Data())
                var stopped = false
                if let record = options.record {
                    (output.stderr, stopped) = ProcessOutput.records(process, stdout: stdout, stderr: stderr, record: record)
                } else {
                    output = ProcessOutput.collect(process, stdout: stdout, stderr: stderr)
                }
                deadline.cancel()
                let status = process.terminationStatus
                if !stopped, process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure.timedOut(arguments))
                } else if !stopped, !options.answers.contains(status) {
                    continuation.resume(throwing: Failure.git(arguments: arguments, status: status,
                                                              stderr: String(decoding: output.stderr, as: UTF8.self)))
                } else {
                    continuation.resume(returning: Output(stdout: output.stdout, stderr: output.stderr, status: status,
                                                          stopped: stopped))
                }
            }
        }
    }

    /// Answers git's prompts from the child's own environment: the script
    /// holds no secret, and the token never reaches disk or argv.
    private func askpassScript() throws -> URL {
        let url = root.appendingPathComponent("askpass.sh")
        let script = """
            #!/bin/sh
            case "$1" in
              Username*) printf '%s\\n' x-access-token ;;
              *) printf '%s\\n' "$PULTIK_GIT_PASSWORD" ;;
            esac

            """
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Disk

    /// Marks the repo used: eviction removes the least recently used.
    private func touch(_ repo: String) {
        let marker = path(repo).appendingPathComponent("pultik-used")
        if !FileManager.default.createFile(atPath: marker.path, contents: nil) {
            NSLog("pultik: mirror %@ not marked used", repo)
        }
    }

    /// Repos idle past `idleEviction` go, then the least recently used until
    /// the mirror is under `capBytes`. A repo with a command in flight stays.
    func evict(now: Date = Date()) {
        let files = FileManager.default
        var repos: [(url: URL, used: Date, size: Int64)] = []
        for owner in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for repo in (try? files.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)) ?? []
            where repo.pathExtension == "git" {
                let used = (try? files.attributesOfItem(atPath: repo.appendingPathComponent("pultik-used").path))?[.modificationDate]
                    as? Date ?? .distantPast
                repos.append((repo, used, Self.size(of: repo)))
            }
        }
        let busy = Set(inFlight.keys.map { path($0).standardizedFileURL.path })
        var total = repos.reduce(Int64(0)) { $0 + $1.size }
        for repo in repos.sorted(by: { $0.used < $1.used }) where !busy.contains(repo.url.standardizedFileURL.path) {
            guard now.timeIntervalSince(repo.used) > idleEviction || total > capBytes else { break }
            do {
                try files.removeItem(at: repo.url)
                total -= repo.size
                backfilled.removeAll()
            } catch {
                NSLog("pultik: mirror eviction of %@ failed: %@", repo.url.path, error.localizedDescription)
            }
        }
    }

    private static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: - Parsing

    /// `git diff` output → one entry per file, its patch from the first hunk
    /// (the host's `patch` shape); a binary file has none. `index` names
    /// each side's blob (all zeros: the side does not exist).
    static func parse(diff: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        var current: (header: String, old: String?, new: String?, renamedFrom: String?, renamedTo: String?,
                      status: ChangedFile.Status, hunks: [Substring], additions: Int, deletions: Int, binary: Bool,
                      blobs: (old: String?, new: String?))?
        func finish() {
            guard let file = current else { return }
            let fromHeader = Self.headerPaths(file.header)
            let path = file.renamedTo ?? file.new ?? file.old ?? fromHeader.new
            let previous = file.renamedFrom ?? (file.status == .renamed || file.status == .copied ? fromHeader.old : nil)
            files.append(ChangedFile(path: path, previousPath: previous, status: file.status, additions: file.additions,
                                     deletions: file.deletions,
                                     patch: file.binary || file.hunks.isEmpty ? nil : file.hunks.joined(separator: "\n"),
                                     trimmed: false, oldBlob: file.blobs.old, newBlob: file.blobs.new))
            current = nil
        }
        let text = diff.hasSuffix("\n") ? String(diff.dropLast()) : diff
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finish()
                current = (String(line), nil, nil, nil, nil, .modified, [], 0, 0, false, (nil, nil))
                continue
            }
            guard current != nil else { continue }
            if !current!.hunks.isEmpty {
                if line.hasPrefix("+") { current!.additions += 1 }
                if line.hasPrefix("-") { current!.deletions += 1 }
                current!.hunks.append(line)
                continue
            }
            if line.hasPrefix("@@") {
                current!.hunks.append(line)
            } else if line.hasPrefix("new file mode") {
                current!.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current!.status = .removed
            } else if line.hasPrefix("rename from ") {
                current!.status = .renamed
                current!.renamedFrom = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                current!.renamedTo = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                current!.status = .copied
                current!.renamedFrom = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                current!.renamedTo = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("--- ") {
                current!.old = Self.side(line.dropFirst(4), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                current!.new = Self.side(line.dropFirst(4), prefix: "b/")
            } else if line.hasPrefix("Binary files ") {
                current!.binary = true
            } else if line.hasPrefix("index ") {
                current!.blobs = Self.blobs(line.dropFirst("index ".count))
            }
        }
        finish()
        return files
    }

    /// `<old>..<new> 100644` → both blobs; an all-zero id is no blob.
    private static func blobs(_ text: Substring) -> (old: String?, new: String?) {
        let ids = text.split(separator: " ").first?.components(separatedBy: "..") ?? []
        guard ids.count == 2 else { return (nil, nil) }
        let real: (String) -> String? = { $0.allSatisfy { $0 == "0" } ? nil : $0 }
        return (real(ids[0]), real(ids[1]))
    }

    /// `a/path` → `path`; `/dev/null` → nil.
    private static func side(_ text: Substring, prefix: String) -> String? {
        let value = Self.unquoted(String(text))
        guard value != "/dev/null" else { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `diff --git a/x b/x` → both paths (a mode-only change has no `---`/`+++`).
    private static func headerPaths(_ header: String) -> (old: String, new: String) {
        let body = header.dropFirst("diff --git ".count)
        guard let split = body.range(of: " b/", options: .backwards) else { return (String(body), String(body)) }
        let old = String(body[..<split.lowerBound])
        return (old.hasPrefix("a/") ? String(old.dropFirst(2)) : old, String(body[split.upperBound...]))
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
    }
}

private extension QualityOfService {
    var dispatchClass: DispatchQoS.QoSClass {
        switch self {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }
}

/// Turns `git grep -z -n --column` records into hits as git prints them,
/// and stops git once `limit` are in: the code core's `GrepRecords`
/// (workbench WP3b). Git reports a line's first match; the core finds the
/// rest the way git walks a line (leftmost first, the next from the previous
/// match's end; under whole word a word is ASCII letters, digits and `_`, as
/// git counts them), in UTF-16 as `GrepHit` counts. A Perl pattern the core
/// cannot read keeps git's first match alone. Records arrive on one thread;
/// the lock orders them against the final read.
private final class GrepCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let records: GrepRecords
    private var failure: Error?

    init(head: String, limit: Int, query: String, options: SearchOptions) throws {
        records = try GrepRecords(head: head, limit: limit, query: query,
                                  toggles: SearchToggles(caseSensitive: options.caseSensitive,
                                                         wholeWord: options.wholeWord, regex: options.regex))
    }

    /// `<head>:<path>\0<line>\0<byte column>\0<text>`; false once full.
    func add(_ record: Data) -> Bool {
        lock.withLock {
            guard failure == nil else { return false }
            do {
                let (more, readable) = try records.add(record)
                if !readable {
                    NSLog("pultik: mirror grep record unreadable: %@", String(decoding: record.prefix(200), as: UTF8.self))
                }
                return more
            } catch {
                failure = error
                return false
            }
        }
    }

    /// The hits in git's order; a record the core failed on fails the search.
    func hits() throws -> [GrepHit] {
        try lock.withLock {
            if let failure { throw failure }
            return try records.hits().map {
                GrepHit(path: $0.path, line: $0.line, column: $0.column, length: $0.length, text: $0.text)
            }
        }
    }
}
