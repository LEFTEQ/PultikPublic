import XCTest
@testable import Pultik

final class GitHubRequestBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testPollingReservationsAreBoundedAcrossConcurrentStartsAndExpire() {
        var budget = GitHubRequestBudget(hourlyLimit: 2)
        XCTAssertNil(budget.admit(resource: "core", polling: true, now: now))
        XCTAssertNil(budget.admit(resource: "core", polling: true, now: now))
        XCTAssertEqual(budget.admit(resource: "core", polling: true, now: now), now.addingTimeInterval(3600))
        XCTAssertNil(budget.admit(resource: "core", polling: false, now: now), "explicit actions retain their quota")
        XCTAssertNil(budget.admit(resource: "core", polling: true, now: now.addingTimeInterval(3600)))
    }

    func testPrimaryResetSurvivesSuccessfulProbeAndAlsoBlocksExplicitActions() {
        var budget = GitHubRequestBudget()
        let reset = now.addingTimeInterval(900)
        budget.observe(status: 403, resource: "core", remaining: 0, reset: reset,
                       retryAfter: nil, rateLimited: true, now: now)
        budget.observe(status: 200, resource: "core", remaining: 5000, reset: reset,
                       retryAfter: nil, rateLimited: false, now: now)
        XCTAssertEqual(budget.admit(resource: "core", polling: false, now: now), reset)
        XCTAssertNil(budget.admit(resource: "search", polling: false, now: now))
        XCTAssertNil(budget.admit(resource: "core", polling: true, now: reset))
    }

    func testSecondaryBackoffSpansResourcesButPermissionErrorsDoNot() {
        var budget = GitHubRequestBudget()
        budget.observe(status: 403, resource: "core", remaining: 100, reset: nil,
                       retryAfter: nil, rateLimited: false, now: now)
        XCTAssertNil(budget.admit(resource: "core", polling: false, now: now))
        budget.observe(status: 429, resource: "core", remaining: 100, reset: nil,
                       retryAfter: 120, rateLimited: true, now: now)
        XCTAssertEqual(budget.admit(resource: "search", polling: false, now: now), now.addingTimeInterval(120))
    }

    func testInteractiveSearchesHaveTheirOwnRollingMinuteBudget() {
        var budget = GitHubRequestBudget()
        for _ in 0..<20 { XCTAssertNil(budget.admit(resource: "search", polling: false, now: now)) }
        XCTAssertEqual(budget.admit(resource: "search", polling: false, now: now), now.addingTimeInterval(60))
        XCTAssertNil(budget.admit(resource: "core", polling: false, now: now))
        XCTAssertNil(budget.admit(resource: "search", polling: false, now: now.addingTimeInterval(60)))
    }

    func testAllReadAttemptsAreBoundedWithoutBlockingMutations() {
        var budget = GitHubRequestBudget(hourlyLimit: 2, readLimit: 3)
        for _ in 0..<3 { XCTAssertNil(budget.admit(resource: "core", polling: false, now: now)) }
        XCTAssertEqual(budget.admit(resource: "core", polling: false, now: now), now.addingTimeInterval(3600))
        XCTAssertNil(budget.admit(resource: "core", polling: false, mutation: true, now: now))
        XCTAssertNil(budget.admit(resource: "core", polling: false, now: now.addingTimeInterval(3600)))
    }

    func testLowQuotaReservesForegroundCapacityAndRepeatedSecondaryLimitsBackOff() {
        var budget = GitHubRequestBudget()
        let reset = now.addingTimeInterval(900)
        budget.observe(status: 200, resource: "core", remaining: 100, reset: reset,
                       retryAfter: nil, rateLimited: false, now: now)
        XCTAssertEqual(budget.admit(resource: "core", polling: true, now: now), reset)
        XCTAssertNil(budget.admit(resource: "core", polling: false, now: now))
        budget.observe(status: 429, resource: "core", remaining: 100, reset: nil,
                       retryAfter: nil, rateLimited: true, now: now)
        let later = now.addingTimeInterval(61)
        budget.observe(status: 429, resource: "core", remaining: 100, reset: nil,
                       retryAfter: nil, rateLimited: true, now: later)
        XCTAssertEqual(budget.blockedUntil(resource: "search", now: later), later.addingTimeInterval(120))
    }

    func testQuotaDeferralNeverTripsTheBreakerButARefusalDoes() {
        XCTAssertNil(ProbeFailure.tripping(GitHubError.deferred(now)), "the budget already holds every request")
        guard case .rejected = ProbeFailure.tripping(GitHubError.http(401, "/graphql")) else {
            return XCTFail("a refused credential must still open the breaker")
        }
    }
}
