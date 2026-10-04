import Foundation

/// Hlídač — the prod digest API on BuildServer (example-org/hlidac,
/// docs/specs/2026-10-03-prod-watch-contracts.md §5). Mesh-only, no auth,
/// its own host and therefore its own breaker (`ProbeTarget.hlidac`). One
/// call carries every deployment's verdict, checks, log series, Sentry
/// issues, alerts and eve pool, so the 15 s fast lane is one request.
actor HlidacClient {
    static let shared = HlidacClient()

    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 5)
    }

    /// The cheap half-open probe: `/healthz`, no payload.
    func probe(base: URL) async -> ProbeFailure? {
        do {
            let (_, response) = try await session.data(from: base.appending(path: "healthz"))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? nil : Self.failure(status, "hlidac healthz")
        } catch {
            return .classify(error)
        }
    }

    func digest(base: URL) async -> (digest: HlidacDigest?, failure: ProbeFailure?) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: base.appending(path: "api/v1/prod"))
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return (nil, Self.failure(status, "hlidac")) }
        guard let digest = HlidacDigest.decode(data) else {
            return (nil, .unreachable("hlidac digest unreadable"))
        }
        return (digest, nil)
    }

    private static func failure(_ status: Int, _ what: String) -> ProbeFailure {
        let why = "\(what) answered \(status)"
        return [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why)
    }
}
