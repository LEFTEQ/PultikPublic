import Foundation

/// Semafor — the CI admission board on BuildServer (example-org/semafor),
/// reached over the WireGuard mesh like Prometheus but on its own host, so it
/// has its own breaker (`ProbeTarget.semafor`). Its admission view (both
/// pools, the queue head, refusal reasons) and its overview (today's jobs
/// and queue wait) are read. No auth on the query API; off-mesh the call fails
/// fast and the pool line hides.
actor SemaforClient {
    static let shared = SemaforClient()

    /// Also the web app the CI widget links to.
    static let base = URL(string: "https://semafor.ops.example.invalid")!
    private let session: URLSession

    init() {
        session = PollingSession.make(timeout: 5)
    }

    /// The pool, its head labelled from the lanes' `ci_lane_info` tiers. A
    /// failure is what the breaker backs off on; an answer without a Docker
    /// pool (no controller exported yet) is a nil pool, not a failure.
    func pool(lanes: [CILane]) async -> (pool: CIPool?, failure: ProbeFailure?) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: Self.base.appending(path: "api/v1/admission"))
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let why = "semafor answered \(status)"
            return (nil, [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why))
        }
        guard let admission = SemaforAdmission.decode(data) else {
            return (nil, .unreachable("semafor admission payload unreadable"))
        }
        return (admission.pool(lanes: lanes), nil)
    }

    /// Today's throughput and queue wait — `/api/v1/overview`. Semafor's own
    /// SPA reads it once a minute; the store keeps to the same cadence.
    func overview() async -> (throughput: CIThroughput?, failure: ProbeFailure?) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: Self.base.appending(path: "api/v1/overview"))
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let why = "semafor overview answered \(status)"
            return (nil, [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why))
        }
        guard let throughput = CIThroughput.decode(data) else {
            return (nil, .unreachable("semafor overview payload unreadable"))
        }
        return (throughput, nil)
    }
}
