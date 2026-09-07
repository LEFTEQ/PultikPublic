import Foundation

/// Fetches eve's notifications ledger — `/eve/v1/notifications` on the WG
/// mesh, same host and posture as `EveClient`: mesh-gated with an optional
/// `Authorization: Bearer evk_…` (see `EveAuth`), fail fast off-mesh, empty on
/// any error so the alerts section simply hides.
actor EveNotificationsClient {
    static let shared = EveNotificationsClient()

    private let base = URL(string: "https://eve.ops.example.invalid")!
    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 10)
    }

    /// The most recent ~50 notifications, newest first. Lane filtering is
    /// client-side (the ledger stores every lane), so one fetch serves any
    /// visible-lanes setting without a refetch.
    ///
    /// `.failed` means the fetch FAILED (off-mesh, non-200, undecodable) —
    /// which is NOT the same as `.value([])`, meaning the ledger genuinely
    /// holds nothing. The caller needs that difference: a transient failure
    /// must keep the last known list, but a legitimately empty feed has to be
    /// able to clear the rail, and conflating them left it unclearable forever.
    ///
    /// The same signal drives `ProbeGate` — this is the only eve call that can
    /// tell a refusal from silence, so both of eve's rails back off on it.
    func recent(settingsToken: String?) async -> ProbeResult<[EveAlert]> {
        var request = URLRequest(url: base.appending(path: "eve/v1/notifications")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "50")]))
        request.timeoutInterval = 10
        EveAuth.apply(await EveAuth.shared.token(preferred: settingsToken), to: &request)
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.unreachable("no response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(.classify(HTTPStatusError(status: http.statusCode)))
            }
            data = body
        } catch {
            return .failed(.classify(error))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        guard let decoded = try? decoder.decode(EveAlertsResponse.self, from: data) else {
            return .failed(.unreachable("unreadable ledger payload"))
        }
        return .value(decoded.notifications)
    }
}
