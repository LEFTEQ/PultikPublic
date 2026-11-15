import XCTest
@testable import Pultik

/// vt-9725: the polled me doors revalidate, and `/me/work` reads compact
/// until a workspace's server proves it cannot feed the rail that way.
final class VitrinkaRevalidationTests: XCTestCase {
    private let body = Data(#"{"ripe":[]}"#.utf8)

    func testOnlyTheMeDoorsAreKeyedPerWorkspaceAndQuery() {
        XCTAssertNil(VitrinkaValidatorCache.key(path: "/api/v1/tray", workspace: "one"))
        XCTAssertNil(VitrinkaValidatorCache.key(path: "/api/v1/me", workspace: "one"))
        let ripe = VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: "one")
        XCTAssertNotNil(ripe)
        XCTAssertNotEqual(ripe, VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: "two"))
        XCTAssertNotEqual(VitrinkaValidatorCache.key(path: "/api/v1/me/work", workspace: "one"),
                          VitrinkaValidatorCache.key(path: "/api/v1/me/work?compact=1", workspace: "one"))
    }

    func testA200IsRememberedAndA304AnswersItsBody() throws {
        var cache = VitrinkaValidatorCache()
        cache.bind(identity: "me")
        let key = try XCTUnwrap(VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: "one"))
        XCTAssertNil(cache.entry(for: key))
        XCTAssertEqual(cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g1""#, body: body),
                       .body(body))
        let sent = try XCTUnwrap(cache.entry(for: key))
        XCTAssertEqual(sent.etag, #"W/"g1""#)
        XCTAssertEqual(cache.resolve(key: key, sent: sent, identity: "me", status: 304, etag: #"W/"g1""#, body: Data()),
                       .body(body), "a 304 is the remembered answer, never a failure")
        XCTAssertEqual(cache.entry(for: key), sent)
    }

    func testA304AnswersTheSentEntryEvenWhenTheCacheMovedDuringTheAwait() throws {
        var cache = VitrinkaValidatorCache()
        cache.bind(identity: "me")
        let key = try XCTUnwrap(VitrinkaValidatorCache.key(path: "/api/v1/me/work?compact=1", workspace: "one"))
        _ = cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g1""#, body: body)
        let sent = cache.entry(for: key)
        cache.bind(identity: "someone else") // the credential moved mid-flight
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.resolve(key: key, sent: sent, identity: "me", status: 304, etag: nil, body: Data()),
                       .body(body))
        XCTAssertNil(cache.entry(for: key), "an old identity's answer never lands under the new one")
        XCTAssertEqual(cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g2""#, body: body),
                       .body(body))
        XCTAssertNil(cache.entry(for: key))
    }

    func testAnIdentityChangeForgetsEveryAnswer() throws {
        var cache = VitrinkaValidatorCache()
        cache.bind(identity: "me")
        let key = try XCTUnwrap(VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: nil))
        _ = cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g1""#, body: body)
        cache.bind(identity: "me")
        XCTAssertNotNil(cache.entry(for: key), "the same identity keeps its answers")
        cache.bind(identity: nil)
        XCTAssertNil(cache.entry(for: key))
    }

    func testA304WithoutAValidatorRefetchesAndOtherStatusesPassThrough() throws {
        var cache = VitrinkaValidatorCache()
        cache.bind(identity: "me")
        let key = try XCTUnwrap(VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: "one"))
        XCTAssertEqual(cache.resolve(key: key, sent: nil, identity: "me", status: 304, etag: nil, body: Data()), .refetch)
        _ = cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g1""#, body: body)
        let sent = cache.entry(for: key)
        XCTAssertEqual(cache.resolve(key: key, sent: sent, identity: "me", status: 401, etag: nil, body: Data()), .status(401))
        XCTAssertEqual(cache.entry(for: key), sent, "a refusal leaves the validator for the breaker's next try")
        XCTAssertEqual(cache.resolve(key: key, sent: sent, identity: "me", status: 200, etag: nil, body: body), .body(body))
        XCTAssertNil(cache.entry(for: key), "a 200 without an ETag drops the stale validator")
    }

    func testTheEntryCountStaysBounded() {
        var cache = VitrinkaValidatorCache()
        cache.bind(identity: "me")
        for index in 0...VitrinkaValidatorCache.entryLimit {
            let key = VitrinkaValidatorCache.key(path: "/api/v1/me/ripe", workspace: "w\(index)")!
            _ = cache.resolve(key: key, sent: nil, identity: "me", status: 200, etag: #"W/"g""#, body: body)
        }
        XCTAssertLessThanOrEqual(cache.count, VitrinkaValidatorCache.entryLimit)
    }

    func testWorkReadsCompactAndFallsBackToFullForTheWorkspaceForGood() {
        var mode = VitrinkaWorkReadMode()
        XCTAssertEqual(mode.path(for: "one"), "/api/v1/me/work?compact=1")
        let linked = Data("""
        {"actor":"me","assigned":[{"id":7,"title":"Ship","state":"started","status":"in_progress","version":1,"origin":"human",
          "project":"demo","url":"https://example.test/w/one/p/demo/t/7"}],
         "gates":[{"task":{"id":8,"title":"Sign","state":"todo","status":"todo","version":1,"origin":"human",
          "project":"demo","url":"https://example.test/w/one/p/demo/t/8"},"why":["gate on you: sign"]}]}
        """.utf8)
        guard case .work(let work) = mode.decode(linked, readThrough: mode.path(for: "one"), workspace: "one") else {
            return XCTFail("a compact answer with project and url feeds the rail")
        }
        XCTAssertEqual(work.assigned?.first?.url.path, "/w/one/p/demo/t/7")
        XCTAssertEqual(work.gates?.first?.task.project, "demo")
        XCTAssertEqual(mode.path(for: "one"), "/api/v1/me/work?compact=1")

        let older = Data(#"{"actor":"me","assigned":[{"id":7,"title":"Ship","state":"started","status":"in_progress"}]}"#.utf8)
        guard case .fullRead = mode.decode(older, readThrough: mode.path(for: "one"), workspace: "one") else {
            return XCTFail("compact rows without project/url ask for the full read")
        }
        XCTAssertEqual(mode.path(for: "one"), "/api/v1/me/work", "the workspace stays on the full read")
        XCTAssertEqual(mode.path(for: "two"), "/api/v1/me/work?compact=1", "only that workspace")
        guard case .unreadable = mode.decode(older, readThrough: mode.path(for: "one"), workspace: "one") else {
            return XCTFail("an unreadable full answer is the error, never another fallback")
        }
    }
}
