import Foundation

/// Thin client for the self-hosted Sentry on BuildServer (mesh-gated host,
/// token-authed API). Off-mesh every call fails fast and the prod strip
/// simply doesn't render.
actor SentryClient {
    static let shared = SentryClient()

    private let base = URL(string: "https://sentry.ops.example.invalid")!
    private let org = "sentry"
    private let session: URLSession
    private var cachedToken: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601Flexible
        return d
    }()

    init() {
        session = PollingSession.make(timeout: 10)
    }

    /// Token: explicit setting first, else the SENTRY_AUTH_TOKEN line cached in
    /// ~/.claude/.env (kept fresh by the my:sentry skill's loader).
    private func token(preferred: String?) -> String? {
        if let preferred, !preferred.isEmpty { return preferred }
        if let cachedToken { return cachedToken }
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix("SENTRY_AUTH_TOKEN=") else { continue }
            let value = line.dropFirst("SENTRY_AUTH_TOKEN=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty {
                cachedToken = value
                return value
            }
        }
        return nil
    }

    /// The half-open trial's single cheap request: the org endpoint with the
    /// same token the per-project fan-out would use. One hit proves mesh,
    /// TLS and auth before the breaker lets the full sweep out. Returns the
    /// classified failure (nil = healthy) — a 401/403 must re-arm the pause
    /// as `.rejected`, not be flattened to "not answering".
    func probeHealth(settingsToken: String?) async -> ProbeFailure? {
        guard let token = token(preferred: settingsToken) else {
            return .classify(URLError(.userAuthenticationRequired))
        }
        var request = URLRequest(url: base.appending(path: "api/0/organizations/\(org)/"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("no response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .classify(HTTPStatusError(status: http.statusCode))
            }
            return nil
        } catch {
            return .classify(error)
        }
    }

    /// Unresolved production issues for one project, newest activity first.
    func unresolvedIssues(project: String, settingsToken: String?) async throws -> [SentryIssue] {
        guard let token = token(preferred: settingsToken) else {
            throw URLError(.userAuthenticationRequired)
        }
        var components = URLComponents(
            url: base.appending(path: "api/0/projects/\(org)/\(project)/issues/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: "is:unresolved level:[error,fatal]"),
            URLQueryItem(name: "statsPeriod", value: "24h"),
            URLQueryItem(name: "environment", value: "production"),
            URLQueryItem(name: "sort", value: "date"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // The CODE, not a flat badServerResponse: a 403 from the mesh gate and
        // a 502 from a restarting Sentry want very different retry behavior,
        // and only ProbeGate's classifier can tell them apart.
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode)
        }
        return try decoder.decode([SentryIssue].self, from: data)
    }

    /// Org-wide issue search for the palette. A short-id-shaped query resolves
    /// the exact issue ("EXAMPLEAPP-API-86", case-insensitive); anything else — and
    /// a short-id shape that resolved to nothing, like "exampleapp-api" — runs as
    /// Sentry full text. Unlike the strip this is NOT scoped to production or
    /// unresolved: a search is a lookup, and hiding a resolved hit would read
    /// as "doesn't exist".
    func searchIssues(_ query: String, settingsToken: String?) async throws -> [SentryIssue] {
        if Self.looksLikeShortId(query) {
            let exact = try await orgIssues(query: "issue:\(query)", settingsToken: settingsToken)
            if !exact.isEmpty { return exact }
        }
        return try await orgIssues(query: query, settingsToken: settingsToken)
    }

    /// "EXAMPLEAPP-API-86" — slug, dash, counter. Deliberately loose: a false
    /// positive only costs the extra exact-match request before full text.
    private static func looksLikeShortId(_ query: String) -> Bool {
        query.range(of: "^[A-Za-z][A-Za-z0-9_-]*-[A-Za-z0-9]+$", options: .regularExpression) != nil
    }

    private func orgIssues(query: String, settingsToken: String?) async throws -> [SentryIssue] {
        guard let token = token(preferred: settingsToken) else {
            throw URLError(.userAuthenticationRequired)
        }
        var components = URLComponents(
            url: base.appending(path: "api/0/organizations/\(org)/issues/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "statsPeriod", value: "90d"),
            URLQueryItem(name: "sort", value: "date"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode)
        }
        return try decoder.decode([SentryIssue].self, from: data)
    }

    /// Unresolved issues whose activity falls inside [start, end) — the
    /// archive's 4-day window fetch. Same filters as the strip, absolute
    /// range instead of statsPeriod.
    func archiveIssues(project: String, settingsToken: String?,
                       start: Date, end: Date) async throws -> [SentryIssue] {
        guard let token = token(preferred: settingsToken) else {
            throw URLError(.userAuthenticationRequired)
        }
        let iso = ISO8601DateFormatter()
        var components = URLComponents(
            url: base.appending(path: "api/0/projects/\(org)/\(project)/issues/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: "is:unresolved level:[error,fatal]"),
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "end", value: iso.string(from: end)),
            URLQueryItem(name: "environment", value: "production"),
            URLQueryItem(name: "sort", value: "date"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: http.statusCode)
        }
        return try decoder.decode([SentryIssue].self, from: data)
    }
}
