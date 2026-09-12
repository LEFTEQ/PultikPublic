import Foundation

/// Actor-owned admission control. Reserve before awaiting the network so
/// concurrent repository fetches cannot overspend the rolling-hour budget.
struct GitHubRequestBudget {
    let hourlyLimit: Int
    private var requests: [Date] = []
    private var deadlines: [String: Date] = [:]
    private var secondaryUntil: Date = .distantPast

    init(hourlyLimit: Int = 500) {
        self.hourlyLimit = max(1, hourlyLimit)
    }

    mutating func admit(resource: String, polling: Bool, now: Date) -> Date? {
        let serverUntil = max(secondaryUntil, deadlines[resource] ?? .distantPast)
        if serverUntil > now { return serverUntil }
        guard polling else { return nil }
        requests.removeAll { now.timeIntervalSince($0) >= 3600 }
        if requests.count >= hourlyLimit, let first = requests.first {
            return first.addingTimeInterval(3600)
        }
        requests.append(now)
        return nil
    }

    mutating func observe(status: Int, resource: String, remaining: Int?, reset: Date?,
                          retryAfter: TimeInterval?, rateLimited: Bool, now: Date) {
        // Never clear a known deadline on a successful concurrent response.
        if remaining == 0, let reset {
            deadlines[resource] = max(deadlines[resource] ?? .distantPast, reset)
        }
        if let retryAfter {
            secondaryUntil = max(secondaryUntil, now.addingTimeInterval(max(60, retryAfter)))
        } else if (status == 429 || rateLimited), remaining != 0 || reset == nil {
            secondaryUntil = max(secondaryUntil, now.addingTimeInterval(60))
        }
    }
}
