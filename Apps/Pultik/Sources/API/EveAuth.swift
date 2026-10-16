import Foundation

/// Bearer-token stamping for eve's `/eve/v1` API, shared by `EveClient` and
/// `EveNotificationsClient`.
///
/// eve's RBAC gate wants `Authorization: Bearer evk_…`. The token is the one
/// `StatusStore.eveToken` read from the login keychain (`pultik-eve`), and
/// nothing else: secrets never come from plaintext files or the environment.
///
/// No token → no header, byte-identical to the tokenless calls these clients
/// made before the gate, so an instance that does not enforce it keeps
/// answering. One that does refuses, and `failure` names the missing token
/// instead of a bare 401.
enum EveAuth {
    /// What a refused tokenless call reports: the pause line, the Test
    /// verdict, the sweep log and /ask.
    static let missingToken = MissingCredential(
        what: "eve token",
        whereToSet: "paste an evk_ token into Settings ▸ Integrations ▸ eve (login keychain pultik-eve; Onyx keeps the human copy)")

    /// A 401/403 to a call that carried no token is this Mac's missing token,
    /// not a bad one.
    static func isMissing(_ token: String?, refusedWith status: Int) -> Bool {
        (status == 401 || status == 403) && (token?.isEmpty ?? true)
    }

    /// The breaker's reading of a non-2xx answer.
    static func failure(status: Int, token: String?) -> ProbeFailure {
        isMissing(token, refusedWith: status)
            ? .classify(missingToken) : .classify(HTTPStatusError(status: status))
    }

    /// Stamps the bearer header when a token is set; a no-op otherwise.
    static func apply(_ token: String?, to request: inout URLRequest) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
