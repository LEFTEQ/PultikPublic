import Foundation

/// One actively-listening scope: a Claude Code session holds a lease on this
/// board (or repo+branch) and services its annotation queue. The lease's
/// long-poll IS the heartbeat, so `lastSeen` going stale means the listener
/// died — the row dims rather than lies.
struct VitrinkaListening: Identifiable {
    let id: Int64          // lease id
    let scope: String      // board slug, or "project@branch" for repo scopes
    let title: String
    let url: String?
    let openCount: Int
    let lastSeen: Date
    let session: String

    /// The heartbeat renews every long-poll cycle (~1 min); double that and
    /// the listener is gone, not just slow.
    var isLive: Bool { Date().timeIntervalSince(lastSeen) < 150 }
}

/// Client for the vitrinka deployment this Mac is signed in to: the listener
/// queue and — since todos moved off the Obsidian vault (2026-09-05) — the
/// personal todo engine (`/me/ripe`, open todos). Mesh-only, like
/// Prometheus: off the mesh the fetch fails and every section it feeds
/// vanishes.
///
/// Auth rides on the machine's own CLI credential (`vitrinka login` wrote
/// it) — pultik never mints or stores credentials of its own. Deployment and
/// token resolve the way the CLI resolves them (`internal/cli/config`), minus
/// the per-repo binding a GUI app has no checkout for.
actor VitrinkaClient {
    static let shared = VitrinkaClient()

    /// The deployment: `VITRINKA_URL` (a terminal-launched Debug build against
    /// a scratch server) → config.json `defaultServer` → the ONLY signed-in
    /// origin → the hosted default. `https://boards.example.invalid` is retired (a 308
    /// shim that drops Authorization), so it must never be the fallback.
    nonisolated static func resolveBase() -> URL {
        let hosted = URL(string: "https://boards.example.invalid")!
        if let env = ProcessInfo.processInfo.environment["VITRINKA_URL"],
           let url = URL(string: env.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil {
            return url
        }
        let config = cliConfig()
        if let chosen = config?["defaultServer"] as? String, let url = URL(string: chosen), url.host != nil {
            return url
        }
        if let servers = config?["servers"] as? [String: Any], servers.count == 1,
           let sole = servers.keys.first, let url = URL(string: sole), url.host != nil {
            return url
        }
        return hosted
    }

    /// `~/.config/vitrinka/config.json` — the CLI's non-secret metadata (plus
    /// a plaintext token fallback on machines without a keyring). Read fresh
    /// per call; it is small and `vitrinka login` rewrites it.
    nonisolated private static func cliConfig() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/vitrinka/config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated let base: URL
    /// The origin as the CLI keys its credential: scheme + host (+ port), no
    /// path, no trailing slash — `NormalizeOrigin` on the Go side.
    nonisolated let origin: String
    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 5)
        base = Self.resolveBase()
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        origin = components.string ?? base.absoluteString
    }

    /// The credential, on the CLI's ladder: `VITRINKA_TOKEN` → the legacy
    /// `~/.config/vitrinka/token` file → the CLI's keychain item (service
    /// `vitrinka`, account = origin) → the plaintext `servers[origin].token`
    /// in config.json.
    ///
    /// Cached per process once found, and a miss is retried only every ten
    /// minutes: the keychain read can prompt ("Pultík wants to use your
    /// confidential information…"), and a poller that asked every 30 s would
    /// be a nag rather than a status item.
    private var cachedToken: String?
    private var tokenMissedAt: Date?

    private var token: String? {
        if let cachedToken { return cachedToken }
        if let missed = tokenMissedAt, Date().timeIntervalSince(missed) < 600 { return nil }
        let found = Self.readToken(origin: origin)
        if let found { cachedToken = found } else { tokenMissedAt = .now }
        return found
    }

    nonisolated private static func readToken(origin: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["VITRINKA_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/vitrinka/token")
        if let value = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = Keychain.read(service: "vitrinka", account: origin)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let servers = cliConfig()?["servers"] as? [String: Any],
           let server = servers[origin] as? [String: Any],
           let value = server["token"] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    /// The breaker's way back in: ONE cheap request against the same host
    /// and credential every other call uses. `/me/ripe` is the smallest
    /// authenticated answer the todo engine gives, so a refusal or a dead
    /// host is learned for the price of one request — never the full
    /// listener-plus-todo fan-out.
    func probe() async -> ProbeFailure? {
        guard let token else { return .rejected("no vitrinka credential") }
        if case .failed(let failure) = await get("/api/v1/me/ripe", token: token) { return failure }
        return nil
    }

    // MARK: - Todos

    private struct RipeResponse: Decodable {
        struct Entry: Decodable {
            struct Milestone: Decodable { let name: String }
            let task: TodoItem
            let reason: String
            let milestone: Milestone?
        }
        let ripe: [Entry]
    }

    private struct TasksResponse: Decodable {
        let tasks: [TodoItem]
        let nextCursor: String?
    }

    /// Everything ripe RIGHT NOW across every project — overdue, inside its
    /// lead window, or waiting on a milestone that was just reached. The
    /// server computes ripeness (spec decision 6); the app only paints it.
    func ripe() async -> ProbeResult<[TodoItem]> {
        guard let token else { return .failed(.rejected("no vitrinka credential")) }
        switch await get("/api/v1/me/ripe", token: token) {
        case .failed(let failure): return .failed(failure)
        case .value(let data):
            guard let payload = try? JSONDecoder().decode(RipeResponse.self, from: data) else {
                return .failed(.unreachable("unreadable ripe payload"))
            }
            return .value(payload.ripe.map { entry in
                var task = entry.task
                task.reason = entry.reason
                task.milestoneName = entry.milestone?.name
                return task
            })
        }
    }

    /// Open todos in every project, newest page first, following the keyset
    /// cursor for at most five pages — the panel is a glance, not an archive.
    func openTodos() async -> ProbeResult<[TodoItem]> {
        guard let token else { return .failed(.rejected("no vitrinka credential")) }
        let filter = #"{"types":["todo"],"groups":["backlog","unstarted","started"]}"#
        let encoded = Data(filter.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var all: [TodoItem] = []
        var seen: Set<Int64> = []
        var cursor: String?
        for _ in 0..<5 {
            var path = "/api/v1/tasks?f=\(encoded)&fields=summary&limit=200"
            if let cursor { path += "&cursor=\(cursor)" }
            switch await get(path, token: token) {
            case .failed(let failure): return .failed(failure)
            case .value(let data):
                guard let page = try? JSONDecoder().decode(TasksResponse.self, from: data) else {
                    return .failed(.unreachable("unreadable task payload"))
                }
                // Keyed by id: a cursor that failed to advance must not paint
                // the same rows twice (the first live pass showed one todo
                // five times because the server ends paging with "" not null).
                for task in page.tasks where seen.insert(task.id).inserted { all.append(task) }
                let next = page.nextCursor ?? ""
                if next.isEmpty || next == cursor || page.tasks.isEmpty { return .value(all) }
                cursor = next
            }
        }
        return .value(all)
    }

    /// The task panel on the project page — `/p/{project}?task={id}` is the
    /// PM app's own selection URL (`pm/state/url-state.ts`).
    nonisolated func taskURL(project: String, id: Int64) -> URL {
        var components = URLComponents(url: base.appending(path: "p/\(project)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "task", value: String(id))]
        return components.url!
    }

    /// `/me/work` — the cross-project overview with its Ripe section.
    nonisolated var myWorkURL: URL { base.appending(path: "me/work") }

    private struct ListenersResponse: Decodable {
        struct Listener: Decodable {
            let id: Int64
            let scope: String
            let scopeKind: String?
            let branch: String?
            let session: String?
            let lastSeen: String
        }
        let listeners: [Listener]
    }

    private struct WorkResponse: Decodable {
        struct Item: Decodable { let board: String }
        let work: [Item]
    }

    private struct BoardsResponse: Decodable {
        struct Board: Decodable {
            let slug: String
            let title: String?
            let url: String?
        }
        let boards: [Board]
    }

    /// The boards someone is CURRENTLY listening to, freshest heartbeat first,
    /// each with its open-work count. Not the whole queue: a board nobody is
    /// tuned into doesn't belong in the listener panel.
    ///
    /// The three requests are no longer fired together. Listeners goes first
    /// and alone, so a host that isn't answering costs one request per refresh
    /// instead of three — and its verdict is what `ProbeGate` backs off on.
    func listening() async -> ProbeResult<[VitrinkaListening]> {
        guard let token else { return .failed(.rejected("no vitrinka token")) }
        let listenersData: Data
        switch await get("/api/v1/work/listeners", token: token) {
        case .failed(let failure): return .failed(failure)
        case .value(let data): listenersData = data
        }
        guard let listeners = try? JSONDecoder().decode(ListenersResponse.self, from: listenersData) else {
            return .failed(.unreachable("unreadable listener payload"))
        }

        // Decoration, fetched only once the host has proven it answers.
        async let workData = get("/api/v1/work?status=open", token: token)
        async let boardsData = get("/api/v1/boards", token: token)

        var openCounts: [String: Int] = [:]
        if let work = await workData.value.flatMap({ try? JSONDecoder().decode(WorkResponse.self, from: $0) }) {
            for item in work.work { openCounts[item.board, default: 0] += 1 }
        }
        var boards: [String: (title: String?, url: String?)] = [:]
        if let list = await boardsData.value.flatMap({ try? JSONDecoder().decode(BoardsResponse.self, from: $0) }) {
            for board in list.boards { boards[board.slug] = (board.title, board.url) }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let mapped = listeners.listeners.map { lease -> VitrinkaListening in
            let board = boards[lease.scope]
            let title: String
            if let t = board?.title, !t.isEmpty {
                title = t
            } else if let branch = lease.branch, !branch.isEmpty {
                title = "\(lease.scope) @ \(branch)"
            } else {
                title = lease.scope
            }
            return VitrinkaListening(
                id: lease.id,
                scope: lease.scope,
                title: title,
                url: board?.url,
                openCount: openCounts[lease.scope] ?? 0,
                lastSeen: iso.date(from: lease.lastSeen)
                    ?? isoPlain.date(from: lease.lastSeen) ?? .distantPast,
                session: lease.session ?? ""
            )
        }
        return .value(mapped.sorted { $0.lastSeen > $1.lastSeen })
    }

    private func get(_ path: String, token: String) async -> ProbeResult<Data> {
        guard let url = URL(string: path, relativeTo: base) else {
            return .failed(.rejected("bad path \(path)"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.unreachable("no response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(.classify(HTTPStatusError(status: http.statusCode)))
            }
            return .value(data)
        } catch {
            return .failed(.classify(error))
        }
    }
}
