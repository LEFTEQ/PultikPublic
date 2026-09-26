import Foundation

/// Semafor — the CI admission board on BuildServer (example-org/semafor),
/// reached over the WireGuard mesh like Prometheus but on its own host, so it
/// has its own breaker (`ProbeTarget.semafor`). Only its admission view is
/// read: the shared Docker pool's slots and reservation budget and the head
/// of the priority queue. No auth on the query API; off-mesh the call fails
/// fast and the pool line hides.
actor SemaforClient {
    static let shared = SemaforClient()

    private let base = URL(string: "https://semafor.ops.example.invalid")!
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
            (data, response) = try await session.data(from: base.appending(path: "api/v1/admission"))
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
}
