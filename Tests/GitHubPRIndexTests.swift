import XCTest
@testable import Pultik

final class GitHubPRIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let repos = ["owner/a", "owner/b"]

    private func pr(_ number: Int = 1744, repo: String = "owner/a", title: String = "Cache PR search") -> ArchivedPR {
        ArchivedPR(lookup: PRLookup(number: number, title: title,
            htmlUrl: "https://github.com/\(repo)/pull/\(number)", state: "closed", draft: false,
            mergedAt: now, updatedAt: now, head: nil), repoSlug: repo)
    }

    func testNumberHitsAndConfirmedMissesAvoidOnlyCoveredRepositoriesAndExpire() {
        var index = GitHubPRIndex()
        index.ingest([pr()], now: now)
        XCTAssertEqual(index.reposNeedingLookup(number: 1744, repos: repos, now: now), ["owner/b"])
        index.rememberLookup(number: 1744, repos: ["owner/b"], hits: [], now: now)
        XCTAssertTrue(index.answer(query: "#1744", repos: repos, now: now).isFresh)
        XCTAssertEqual(index.answer(query: "1744", repos: repos.reversed(), now: now).hits.map(\.id), ["owner/a#1744"])
        XCTAssertEqual(index.reposNeedingLookup(number: 1744, repos: repos, now: now.addingTimeInterval(61)), ["owner/b"])
        index.rememberLookup(number: 1744, repos: ["owner/b"], hits: [pr(repo: "owner/b")], now: now)
        XCTAssertEqual(index.answer(query: "#1744", repos: repos, now: now).hits.count, 2)
    }

    func testPartialAnswersCannotCacheAbsenceAndScopeChangesNeverReuseCompleteness() {
        var index = GitHubPRIndex()
        index.remember(query: "cache", repos: repos, hits: [pr()], complete: false, now: now)
        XCTAssertFalse(index.answer(query: "cache", repos: repos, now: now).isFresh)
        index.remember(query: "cache", repos: repos, hits: [pr()], complete: true, now: now)
        XCTAssertTrue(index.answer(query: "cache", repos: repos.reversed(), now: now).isFresh)
        let removed = index.answer(query: "cache", repos: ["owner/b"], now: now)
        XCTAssertTrue(removed.hits.isEmpty)
        XCTAssertFalse(removed.isFresh)
        index.remember(query: "missing", repos: repos, hits: [], complete: false, now: now)
        XCTAssertFalse(index.answer(query: "missing", repos: repos, now: now).isFresh)
        index.remember(query: "missing", repos: repos, hits: [], complete: true, now: now)
        XCTAssertTrue(index.answer(query: "missing", repos: repos, now: now).isFresh)
        XCTAssertFalse(index.answer(query: "missing", repos: repos, now: now.addingTimeInterval(61)).isFresh)
    }

    func testRefreshingNumberMissesDoesNotRestampRetainedHits() {
        var index = GitHubPRIndex()
        index.ingest([pr()], now: now)
        index.rememberLookup(number: 1744, repos: [repos[1]], hits: [], now: now)
        for elapsed in [61.0, 122, 183, 244] {
            let refreshedAt = now.addingTimeInterval(elapsed)
            index.rememberLookup(number: 1744, repos: [repos[1]], hits: [], now: refreshedAt)
            let retained = index.answer(query: "#1744", repos: repos, now: refreshedAt).hits
            index.remember(query: "#1744", repos: repos, hits: retained, complete: true, now: refreshedAt)
        }
        XCTAssertEqual(index.records["owner/a#1744"]?.fetchedAt, now)
        XCTAssertEqual(index.reposNeedingLookup(number: 1744, repos: repos,
            now: now.addingTimeInterval(301)), [repos[0]])
    }

    func testArchiveCoverageResumesFromItsShortLastPageWhenTheRepositoryGrows() {
        var index = GitHubPRIndex()
        let full = (1...100).map { pr($0) }
        index.rememberPage(repo: repos[0], page: 1, hits: [pr()], now: now)
        XCTAssertNil(index.archivePage(repo: repos[0], now: now))
        index.rememberPage(repo: repos[0], page: 1, hits: full, now: now.addingTimeInterval(301))
        XCTAssertEqual(index.archivePage(repo: repos[0], now: now.addingTimeInterval(301)), 2)
        index.rememberPage(repo: repos[0], page: 2, hits: [pr()], now: now.addingTimeInterval(302))
        index.rememberPage(repo: repos[0], page: 1, hits: full, now: now.addingTimeInterval(602))
        XCTAssertEqual(index.archivePage(repo: repos[0], now: now.addingTimeInterval(602)), 2)
        index.rememberPage(repo: repos[0], page: 10, hits: full, now: now.addingTimeInterval(603))
        index.rememberPage(repo: repos[0], page: 1, hits: full, now: now.addingTimeInterval(904))
        XCTAssertNil(index.archivePage(repo: repos[0], now: now.addingTimeInterval(904)))
    }

    func testQualifiersRequireARealQueryAnswerAndKeepCaseInCacheKeys() {
        var index = GitHubPRIndex()
        index.ingest([pr(title: "label:Bug in the title")], now: now)
        XCTAssertTrue(index.answer(query: "label:Bug", repos: repos, now: now).hits.isEmpty)
        index.remember(query: "label:Bug", repos: repos, hits: [pr()], complete: true, now: now)
        XCTAssertEqual(index.answer(query: "label:Bug", repos: repos, now: now).hits.count, 1)
        XCTAssertFalse(index.answer(query: "label:bug", repos: repos, now: now).isFresh)
    }

    func testRenamedRepositoryMatchesItsConfiguredSlugWithoutLeakingIntoOtherScopes() {
        var index = GitHubPRIndex()
        var previous = pr(repo: "owner/old")
        previous.branch = "feature/cache"
        index.ingest([previous], now: now)
        let renamed = ArchivedPR(lookup: PRLookup(number: 1744, title: "Cache search",
            htmlUrl: "https://github.com/owner/new/pull/1744", state: "open", draft: false,
            mergedAt: nil, updatedAt: now, head: nil), repoSlug: "owner/old")
        index.rememberLookup(number: 1744, repos: ["owner/old"], hits: [renamed], now: now)
        let answer = index.answer(query: "#1744", repos: ["owner/old"], now: now)
        XCTAssertEqual(answer.hits.map(\.id), ["owner/new#1744"])
        XCTAssertEqual(answer.hits.first?.branch, "feature/cache")
        XCTAssertTrue(answer.isFresh)
        XCTAssertTrue(index.answer(query: "#1744", repos: ["owner/other"], now: now).hits.isEmpty)
    }

    func testThinSearchResponsePreservesKnownBranchAndOlderPagesCannotOverwriteIt() {
        var index = GitHubPRIndex()
        var metadata = pr()
        metadata.branch = "feature/instant-pr-search"
        index.ingest([metadata], now: now)
        index.ingest([pr()], now: now.addingTimeInterval(1))
        XCTAssertEqual(index.answer(query: "instant-pr", repos: repos, now: now).hits.first?.branch,
                       "feature/instant-pr-search")
        let older = ArchivedPR(lookup: PRLookup(number: 1744, title: "Old title",
            htmlUrl: metadata.url, state: "open", draft: false, mergedAt: nil,
            updatedAt: now.addingTimeInterval(-1), head: nil), repoSlug: repos[0])
        index.ingest([older], now: now.addingTimeInterval(2))
        XCTAssertEqual(index.records[metadata.id]?.pr.outcome, .merged)
    }

    func testRecentDeltaStandsInForTheHeadOnlyWhenItReachesBackPastIt() {
        var index = GitHubPRIndex()
        let recent = [pr(1), pr(2)]
        index.rememberRecent(repo: repos[0], hits: recent, limit: 20, now: now)
        XCTAssertNotNil(index.records[recent[0].id.lowercased()], "the delta is searchable at once")
        XCTAssertEqual(index.archivePage(repo: repos[0], now: now), 1, "a never-fetched head still loads its page")
        index.rememberPage(repo: repos[0], page: 1, hits: recent, now: now)
        let later = now.addingTimeInterval(400)
        let busy = (3...22).map { number in ArchivedPR(lookup: PRLookup(number: number, title: "busy",
            htmlUrl: "https://github.com/owner/a/pull/\(number)", state: "open", draft: false, mergedAt: nil,
            updatedAt: later, head: nil), repoSlug: repos[0]) }
        index.rememberRecent(repo: repos[0], hits: busy, limit: 20, now: later)
        XCTAssertEqual(index.archivePage(repo: repos[0], now: later), 1, "twenty newer PRs may hide a gap")
        index.rememberRecent(repo: repos[0], hits: recent, limit: 20, now: later)
        XCTAssertNotEqual(index.archivePage(repo: repos[0], now: later), 1, "a short delta covers the head")
    }

    func testADeltaRetitleDropsTheStaleQuerySnapshotThatStillListedIt() {
        var index = GitHubPRIndex()
        index.remember(query: "pricing", repos: repos, hits: [pr(5, title: "Pricing module")], complete: true, now: now)
        XCTAssertEqual(index.answer(query: "pricing", repos: repos, now: now).hits.map(\.number), [5])
        let retitled = ArchivedPR(lookup: PRLookup(number: 5, title: "Billing module",
            htmlUrl: "https://github.com/owner/a/pull/5", state: "closed", draft: false, mergedAt: now,
            updatedAt: now.addingTimeInterval(60), head: nil), repoSlug: repos[0])
        index.rememberRecent(repo: repos[0], hits: [retitled], limit: 20, now: now.addingTimeInterval(60))
        let answer = index.answer(query: "pricing", repos: repos, now: now.addingTimeInterval(60))
        XCTAssertTrue(answer.hits.isEmpty, "the snapshot no longer vouches for a retitled PR")
        XCTAssertFalse(answer.isFresh, "the next search asks GitHub again")
    }

    func testArchiveBackfillResumesAndCannotStarveBehindStaleHeads() throws {
        var index = GitHubPRIndex()
        let page = (1...100).map { pr($0) }
        XCTAssertEqual(index.archivePage(repo: repos[0], now: now), 1)
        index.rememberPage(repo: repos[0], page: 1, hits: page, now: now)
        var restored = try JSONDecoder().decode(GitHubPRIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(restored.archivePage(repo: repos[0], now: now.addingTimeInterval(3600)), 2)
        restored.rememberPage(repo: repos[0], page: 2, hits: page, now: now)
        XCTAssertEqual(restored.archivePage(repo: repos[0], now: now), 3)
        restored.rememberPage(repo: repos[0], page: 10, hits: page, now: now)
        XCTAssertNil(restored.archivePage(repo: repos[0], now: now))
        XCTAssertEqual(restored.archivePage(repo: repos[0], now: now.addingTimeInterval(301)), 1)
    }

    func testDiskCacheSurvivesRestartSeparatesIdentitiesAndRejectsOlderSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = GitHubPRIndexDisk(directory: directory)
        var index = GitHubPRIndex()
        index.remember(query: "cache", repos: repos, hits: [pr()], complete: true, now: now)
        index.rememberLookup(number: 1744, repos: repos, hits: [pr()], now: now)
        await disk.save(index, identity: "account-a", revision: 2)
        await disk.save(GitHubPRIndex(), identity: "account-a", revision: 1)
        var restored = await GitHubPRIndexDisk(directory: directory).load(identity: "account-a")
        XCTAssertTrue(restored.answer(query: "cache", repos: repos, now: now).isFresh)
        XCTAssertTrue(restored.answer(query: "#1744", repos: repos, now: now).isFresh)
        let other = await disk.load(identity: "account-b")
        XCTAssertTrue(other.records.isEmpty)
    }

    func testMaximumIndexFiltersWithinFiftyMillisecondsAndStaysBounded() throws {
        var index = GitHubPRIndex()
        index.ingest((1...3_001).map { pr($0) }, now: now)
        XCTAssertEqual(index.records.count, GitHubPRIndex.recordLimit)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            XCTAssertFalse(index.answer(query: "cache search", repos: repos, now: now).hits.isEmpty)
        }
        let perSearch = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
        print("Cached filtering at capacity: \(perSearch) ms/search")
        XCTAssertLessThan(perSearch, 50, "cached filtering should feel immediate")
        XCTAssertLessThan(try JSONEncoder().encode(index).count, GitHubPRIndex.maximumBytes)
    }
}
