import Foundation

/// Bearer-token resolution for eve's `/eve/v1` API, shared by `EveClient` and
/// `EveNotificationsClient`.
///
/// eve is growing an RBAC gate: every `/eve/v1/*` call will need
/// `Authorization: Bearer evk_…`. Token: explicit setting first, else the
/// PULTIK_EVE_TOKEN line cached in ~/.claude/.env (same mechanism as
/// `SentryClient`'s SENTRY_AUTH_TOKEN).
///
/// The key is deliberately PULTIK_EVE_TOKEN and not a bare `EVE_TOKEN`:
/// ~/.claude/.env is sourced by Claude sessions, where `EVE_TOKEN` would
/// shadow the eve CLI's own token.
///
/// No token resolves → no header, which is byte-identical to the tokenless
/// behavior these clients had before the gate.
actor EveAuth {
    static let shared = EveAuth()

    private static let key = "PULTIK_EVE_TOKEN="
    private var cachedToken: String?

    func token(preferred: String?) -> String? {
        if let preferred, !preferred.isEmpty { return preferred }
        if let cachedToken { return cachedToken }
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix(Self.key) else { continue }
            let value = line.dropFirst(Self.key.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty {
                cachedToken = value
                return value
            }
        }
        return nil
    }

    /// Stamps the bearer header when a token resolved; a no-op otherwise.
    nonisolated static func apply(_ token: String?, to request: inout URLRequest) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
