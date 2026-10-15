import Foundation

/// Actor-owned admission control. Reserve before awaiting the network so
/// concurrent repository fetches cannot overspend the rolling-hour budget.
struct GitHubRequestBudget {
    let hourlyLimit: Int
    let readLimit: Int
    private var requests: [Date] = []
    private var reads: [Date] = []
    private var deadlines: [String: Date] = [:]
    private var secondaryUntil: Date = .distantPast
    private var searches: [Date] = []
    private var secondaryFailures = 0
    private var lowQuotaUntil: [String: Date] = [:]

    init(hourlyLimit: Int = 3_000, readLimit: Int = 4_000) {
        self.hourlyLimit = max(1, hourlyLimit)
        self.readLimit = max(1, readLimit)
    }

    func blockedUntil(resource: String, now: Date) -> Date? {
        let until = max(secondaryUntil, deadlines[resource] ?? .distantPast)
        return until > now ? until : nil
    }

    mutating func admit(resource: String, polling: Bool, mutation: Bool = false, now: Date) -> Date? {
        let serverUntil = max(secondaryUntil, deadlines[resource] ?? .distantPast)
        if serverUntil > now { return serverUntil }
        if mutation { return nil }
        reads.removeAll { now.timeIntervalSince($0) >= 3600 }
        if reads.count >= readLimit, let first = reads.first { return first.addingTimeInterval(3600) }
        if resource == "search" {
            searches.removeAll { now.timeIntervalSince($0) >= 60 }
            if searches.count >= 20, let first = searches.first { return first.addingTimeInterval(60) }
        }
        if polling, let until = lowQuotaUntil[resource], until > now { return until }
        requests.removeAll { now.timeIntervalSince($0) >= 3600 }
        if polling, requests.count >= hourlyLimit, let first = requests.first {
            return first.addingTimeInterval(3600)
        }
        reads.append(now)
        if resource == "search" { searches.append(now) }
        if polling { requests.append(now) }
        return nil
    }

    mutating func observe(status: Int, resource: String, remaining: Int?, reset: Date?,
                          retryAfter: TimeInterval?, rateLimited: Bool, now: Date) {
        // Never clear a known deadline on a successful concurrent response.
        if remaining == 0, let reset {
            deadlines[resource] = max(deadlines[resource] ?? .distantPast, reset)
        }
        if let remaining, let reset, remaining <= (resource == "search" ? 5 : 100) {
            lowQuotaUntil[resource] = max(lowQuotaUntil[resource] ?? .distantPast, reset)
        }
        if let retryAfter {
            secondaryUntil = max(secondaryUntil, now.addingTimeInterval(max(60, retryAfter)))
        } else if (status == 429 || rateLimited), remaining != 0 || reset == nil {
            secondaryFailures = min(secondaryFailures + 1, 5)
            secondaryUntil = max(secondaryUntil, now.addingTimeInterval(60 * pow(2, Double(secondaryFailures - 1))))
        } else if (200..<400).contains(status), secondaryUntil <= now {
            secondaryFailures = 0
        }
    }
}
