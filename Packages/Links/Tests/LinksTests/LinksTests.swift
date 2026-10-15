import Foundation
import Links
import XCTest

/// Both grammars build what they parse and parse what they build; Pultík's grammar stays
/// what links in the wild already use.
final class LinksTests: XCTestCase {
    private func url(_ raw: String) -> URL { URL(string: raw)! }

    // MARK: - pultik://

    /// The PR link is byte for byte what it always was, and round-trips.
    func testPRLinkKeepsItsGrammarAndRoundTrips() throws {
        let link = PultikLink.pr(repo: "octo-org/hello-world", number: 280)
        XCTAssertEqual(link.url.absoluteString, "pultik://pr/octo-org/hello-world/280")
        XCTAssertEqual(PultikLink(link.url), link)
        XCTAssertEqual(PultikLink(url("pultik://pr/octo-org/hello-world/280")), link)
        XCTAssertEqual(link.webURL?.absoluteString, "https://github.com/octo-org/hello-world/pull/280")
        // A trailing slash and a query never changed what a link names.
        XCTAssertEqual(PultikLink(url("pultik://pr/octo-org/hello-world/280/?from=x")), link)
    }

    /// Any page can fire the scheme: anything but a well-formed link is dropped.
    func testAnythingElseIsIgnored() {
        for raw in ["pultik://pr/octo-org/hello-world", "pultik://pr/a/b/0", "pultik://pr/a/b/1/extra",
                    "pultik://pr/a%2Fb/c/1", "pultik://pr/a/b%20c/1", "pultik://settings/x",
                    "pultik://panel/a/b", "pultik://panel/prod/a%2Fb", "pultik://panel",
                    "https://github.com/a/b/pull/1", "other://pr/a/b/1"] {
            XCTAssertNil(PultikLink(url(raw)), raw)
        }
    }

    /// A notification's panel links are the strings the persisted Focus queue holds.
    func testPanelLinksRoundTrip() {
        XCTAssertEqual(PultikLink.panel(rail: "firing").url.absoluteString, "pultik://panel/firing")
        XCTAssertEqual(PultikLink.prod(key: "web-prod").url.absoluteString, "pultik://panel/prod/web-prod")
        for link in [PultikLink.panel(rail: "firing"), .prod(key: "api-sk"), .pr(repo: "a/b.c", number: 7)] {
            XCTAssertEqual(PultikLink(link.url), link)
        }
        XCTAssertNil(PultikLink.prod(key: "x").webURL)
    }

    /// A GitHub PR page, on any of its tabs, is the link that opens it in Pultík; an issue,
    /// another host or a malformed number is not.
    func testGitHubPageBecomesAPRLink() {
        let link = PultikLink.pr(repo: "octo-org/hello.world", number: 12)
        for raw in ["https://github.com/octo-org/hello.world/pull/12",
                    "https://github.com/octo-org/hello.world/pull/12/files#diff-1",
                    "http://www.github.com/octo-org/hello.world/pull/12?w=1"] {
            XCTAssertEqual(PultikLink(webURL: url(raw)), link, raw)
        }
        for raw in ["https://github.com/octo-org/hello.world/issues/12", "https://gitlab.com/a/b/pull/1",
                    "https://github.com/a/b/pull/x", "https://github.com/a/pull/1", "pultik://pr/a/b/1"] {
            XCTAssertNil(PultikLink(webURL: url(raw)), raw)
        }
        XCTAssertEqual(link.webURL.flatMap(PultikLink.init(webURL:)), link)
    }

    // MARK: - <scheme>://session/

    /// The session reference is percent-encoded one segment, so names with spaces, slashes,
    /// `%` or non-ASCII letters round-trip.
    func testSessionLinkRoundTripsAnyReference() throws {
        let plain = try XCTUnwrap(SessionLink(scheme: "agentshell", session: "api-7"))
        XCTAssertEqual(plain.url.absoluteString, "agentshell://session/api-7")
        for session in ["api-7", "agt_demo-7", "1b2c3d4e-0000-4abc-8def-0123456789ab",
                        "pay ments/7", "100%", "kočka~é", "@a2"] {
            let link = try XCTUnwrap(SessionLink(scheme: "agentshell", session: session), session)
            XCTAssertEqual(SessionLink(link.url, scheme: "agentshell"), link, session)
            XCTAssertEqual(link.url.pathComponents.count, 2, "one segment: \(link.url)")
        }
        XCTAssertEqual(SessionLink(scheme: "agentshell", session: "pay ments/7")?.url.absoluteString,
                       "agentshell://session/pay%20ments%2F7")
    }

    /// The caller's scheme is the only one a session link answers to (any case), and the
    /// link is exactly one session.
    func testSessionLinkParsesOnlyItsOwnShape() {
        XCTAssertEqual(SessionLink(url("AgentShell://session/a1"), scheme: "agentshell")?.session, "a1")
        for raw in ["other://session/a1", "agentshell://session", "agentshell://session/a/b",
                    "agentshell://agent/a1", "agentshell://session/%20a1", "agentshell://session/a%0A1"] {
            XCTAssertNil(SessionLink(url(raw), scheme: "agentshell"), raw)
        }
    }

    /// A builder never makes a link the parser would refuse.
    func testSessionLinkRefusesWhatItCouldNotCarry() {
        XCTAssertNil(SessionLink(scheme: "agent shell", session: "a1"))
        XCTAssertNil(SessionLink(scheme: "1shell", session: "a1"))
        XCTAssertNil(SessionLink(scheme: "agentshell", session: ""))
        XCTAssertNil(SessionLink(scheme: "agentshell", session: " a1"))
        XCTAssertNil(SessionLink(scheme: "agentshell", session: "a\u{0}1"))
        XCTAssertNil(SessionLink(scheme: "agentshell", session: String(repeating: "a", count: 257)))
        XCTAssertNotNil(SessionLink(scheme: "agentshell", session: String(repeating: "a", count: 256)))
    }
}
