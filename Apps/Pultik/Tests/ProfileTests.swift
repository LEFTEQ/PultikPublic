import XCTest
@testable import Pultik

/// Profiles (docs/specs/2026-10-23-pultik-profiles-decisions.md): absent is
/// example with exactly the defaults Pultík shipped before profiles; genesis
/// and custom name none of its hosts; an explicit setting always wins.
final class ProfileTests: XCTestCase {
    func testAbsentIsTheShippedProfileAndAnUnknownNameIsCustom() {
        XCTAssertEqual(PultikProfile.named(nil), .example)
        XCTAssertEqual(PultikProfile.named("example"), .example)
        XCTAssertEqual(PultikProfile.named("genesis"), .genesis)
        XCTAssertEqual(PultikProfile.named("custom"), .custom)
        // A typo must never poll an estate: custom names no host.
        XCTAssertEqual(PultikProfile.named("Genesis"), .custom)
        XCTAssertEqual(PultikProfile.named(""), .custom)
    }

    /// The values Pultík used before profiles, verbatim.
    func testTheShippedProfileKeepsTodaysDefaults() {
        let example = PultikProfile.example
        XCTAssertEqual(example.hotkey, "option+space")
        XCTAssertTrue(example.loginItemOnFirstRun)
        XCTAssertTrue(example.seedsShippedEstate)
        XCTAssertEqual(example.prometheusURL, "http://192.0.2.10:9090")
        XCTAssertEqual(example.lokiURL, "http://192.0.2.10:3100")
        XCTAssertEqual(example.hlidacURL, "https://hlidac.ops.example.invalid")
        XCTAssertEqual(example.eveURL, "https://app.assistant.example.invalid")
        XCTAssertEqual(example.sentryURL, "https://sentry.ops.example.invalid")
        XCTAssertEqual(example.devboxIdentityFile, "~/.ssh/pultik_devbox")
        XCTAssertFalse(example.devboxSearchesPath)
        XCTAssertEqual(example.devboxFallbackBoxes, [.fallback])
        XCTAssertEqual(DevboxEndpoint.fallback.destination, "devbox@192.0.2.11")
        XCTAssertEqual(DevboxEndpoint.fallback.port, 2225)
        // Now's identities for its rules and its eve stay what they were.
        let hosts = RuntimeConfig(prometheus: RuntimeConfig.host(nil, default: example.prometheusURL),
                                  eve: RuntimeConfig.host(nil, default: example.eveURL))
        XCTAssertEqual(hosts.prometheus?.host(), "192.0.2.10")
        XCTAssertEqual(hosts.eve?.host(), "app.assistant.example.invalid")
    }

    func testGenesisAndCustomNameNoEstateHost() {
        for profile in [PultikProfile.genesis, .custom] {
            XCTAssertFalse(profile.loginItemOnFirstRun, "\(profile)")
            XCTAssertFalse(profile.seedsShippedEstate, "\(profile)")
            for host in [profile.prometheusURL, profile.lokiURL, profile.hlidacURL, profile.eveURL, profile.sentryURL] {
                XCTAssertEqual(host, "", "\(profile)")
                XCTAssertNil(RuntimeConfig.host(nil, default: host), "\(profile)")
            }
            XCTAssertEqual(profile.devboxIdentityFile, "", "\(profile)")
            XCTAssertEqual(profile.devboxFallbackBoxes, [], "\(profile)")
            XCTAssertTrue(profile.devboxSearchesPath, "\(profile)")
        }
        XCTAssertEqual(PultikProfile.genesis.hotkey, "control+space")
        XCTAssertEqual(PultikProfile.custom.hotkey, "option+space")
        XCTAssertEqual(PultikProfile.genesisProjects.flatMap(\.repos), [
            "example-org/GenesisTools", "example-org/example-agent-config", "example-org/example-playground",
            "example-org/example-mobile-app", "example-org/pultik", "example-org/toolkit",
        ])
        XCTAssertTrue(PultikProfile.genesisProjects.allSatisfy { $0.prod == [] })
    }

    /// settings.json's value wins over the profile's; "" is none.
    func testAnExplicitHostWinsAndEmptyIsNone() {
        let shipped = PultikProfile.example.prometheusURL
        XCTAssertEqual(RuntimeConfig.host(nil, default: shipped)?.absoluteString, shipped)
        XCTAssertEqual(RuntimeConfig.host("http://prom.test:9090", default: shipped)?.absoluteString, "http://prom.test:9090")
        XCTAssertEqual(RuntimeConfig.host("http://prom.test:9090", default: "")?.absoluteString, "http://prom.test:9090")
        XCTAssertNil(RuntimeConfig.host("", default: shipped))
        XCTAssertNil(RuntimeConfig.host("   ", default: shipped))
        XCTAssertNil(RuntimeConfig.host("not a host", default: shipped))
    }

    /// No key, no ssh: a configured key that is missing is none too.
    func testTheDevboxProbeNeedsAnExistingKey() {
        var config = RuntimeConfig(devboxIdentityFile: "/keys/pultik_devbox")
        XCTAssertNil(config.devboxIdentity(exists: { _ in false }))
        XCTAssertEqual(config.devboxIdentity(exists: { $0 == "/keys/pultik_devbox" }), "/keys/pultik_devbox")
        config.devboxIdentityFile = nil
        XCTAssertNil(config.devboxIdentity(exists: { _ in true }))
        XCTAssertNil(ExecutableSearch.expand(PultikProfile.genesis.devboxIdentityFile))
        XCTAssertEqual(ExecutableSearch.expand(PultikProfile.example.devboxIdentityFile),
                       NSHomeDirectory() + "/.ssh/pultik_devbox")
    }

    /// example runs `~/bin/devbox` alone, as before; the others try PATH first.
    func testTheDevboxCLIFollowsTheProfile() {
        let home = NSHomeDirectory() + "/bin/devbox"
        let path = ["PATH": "/opt/tools/bin:relative/bin"]
        let example = RuntimeConfig(devboxSearchesPath: false)
        XCTAssertEqual(example.devboxCLI(environment: path, isExecutable: { _ in true }), home)
        XCTAssertNil(example.devboxCLI(environment: path, isExecutable: { $0 == "/opt/tools/bin/devbox" }))
        let genesis = RuntimeConfig(devboxSearchesPath: true)
        XCTAssertEqual(genesis.devboxCLI(environment: path, isExecutable: { _ in true }), "/opt/tools/bin/devbox")
        XCTAssertEqual(genesis.devboxCLI(environment: path, isExecutable: { $0 == home }), home)
        XCTAssertNil(genesis.devboxCLI(environment: path, isExecutable: { $0 == "relative/bin/devbox" }))
        let pinned = RuntimeConfig(devboxExecutable: "/pinned/devbox", devboxSearchesPath: true)
        XCTAssertEqual(pinned.devboxCLI(environment: path, isExecutable: { _ in true }), "/pinned/devbox")
        XCTAssertNil(pinned.devboxCLI(environment: path, isExecutable: { $0 != "/pinned/devbox" }))
    }

    func testExecutableSearchOrder() {
        let all: (String) -> Bool = { _ in true }
        let env = ["PATH": "/a/bin/:/b/bin:.:"]
        XCTAssertEqual(ExecutableSearch.onPath("tool", environment: env), ["/a/bin/tool", "/b/bin/tool"])
        XCTAssertEqual(ExecutableSearch.find("tool", configured: nil, fallbacks: ["/f/tool"], environment: env,
                                             isExecutable: all), "/a/bin/tool")
        XCTAssertEqual(ExecutableSearch.find("tool", configured: nil, fallbacks: ["/f/tool"], environment: [:],
                                             isExecutable: all), "/f/tool")
        XCTAssertEqual(ExecutableSearch.find("tool", configured: "~/x/tool", fallbacks: [], environment: env,
                                             isExecutable: all), NSHomeDirectory() + "/x/tool")
        XCTAssertEqual(ExecutableSearch.find("tool", configured: "  ", fallbacks: ["/f/tool"], environment: [:],
                                             isExecutable: all), "/f/tool")
        // Configured is explicit: relative or missing is unusable, never a
        // search that finds another copy.
        XCTAssertEqual(ExecutableSearch.expand("relative/tool"), "relative/tool")
        XCTAssertNil(ExecutableSearch.find("tool", configured: "relative/tool", fallbacks: ["/f/tool"],
                                           environment: env, isExecutable: all))
        XCTAssertNil(ExecutableSearch.find("tool", configured: "/missing/tool", fallbacks: ["/f/tool"],
                                           environment: env, isExecutable: { $0 != "/missing/tool" }))
        XCTAssertNil(RuntimeConfig(devboxIdentityFile: "keys/pultik_devbox").devboxIdentity(exists: { _ in true }))
    }

    func testDiscoveryFallsBackToTheProfilesBoxes() {
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: nil, previous: nil), [.fallback])
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: nil, previous: nil,
                                               fallback: PultikProfile.genesis.devboxFallbackBoxes), [])
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: nil, previous: [],
                                               fallback: PultikProfile.example.devboxFallbackBoxes), [.fallback])
    }

    /// A settings.json the full decode refuses still says its profile, so a
    /// broken genesis file never polls example's estate; a file that names no
    /// profile is example, as before.
    func testABrokenFileStillNamesItsProfile() throws {
        // What the launch runs: `named(peek)`. Foundation's parser takes a
        // trailing comma, so `"Genesis",` reaches `named` as written.
        let cases: [(String, PultikProfile)] = [
            (#"{"profile": "genesis", "hotkey": 3}"#, .genesis),
            (#"{"profile": "genesis",}"#, .genesis),
            (#"{"profile": "genesis" "hotkey": 3}"#, .genesis),
            (#"{"profile": 3}"#, .custom),
            (#"{"profile": 3,}"#, .custom),
            (#"{"profile": "Genesis",}"#, .custom),
            (#"{"profile": "Genesis" "hotkey": 3}"#, .custom),
            (#"{"profile": null, "hotkey": 3}"#, .example),
            (#"{"profile": null,}"#, .example),
            (#"{"hotkey": 3}"#, .example),
            (#"{"hotkey": "x" "a": 1}"#, .example),
            ("", .example),
        ]
        let directory = FileManager.default.temporaryDirectory.appending(path: "pultik-peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (text, want) in cases {
            let peeked = PultikProfile.peek(Data(text.utf8))
            XCTAssertEqual(PultikProfile.named(peeked), want, text)
            XCTAssertEqual(peeked == nil, want == .example, "example only for a file naming none: \(text)")
            let file = directory.appending(path: "settings.json")
            try Data(text.utf8).write(to: file)
            XCTAssertEqual(Preferences.peekProfile(at: file), peeked, text)
        }
        XCTAssertNil(Preferences.peekProfile(at: directory.appending(path: "absent.json")))
        // What such a launch runs on: the profile's defaults.
        let fallback = Preferences(profile: PultikProfile.peek(Data(#"{"profile": "genesis",}"#.utf8)))
        XCTAssertTrue(fallback.servers.isEmpty)
        XCTAssertNil(fallback.runtimeConfig.prometheus)
        XCTAssertEqual(Preferences(profile: nil).servers.map(\.ref), Preferences.defaultServers.map(\.ref))
    }

    /// Hlídač is off when none is configured or the value is no URL; it
    /// never falls back to example's. example's explicit value is read as it
    /// was before profiles (`URL(string:)`, a scheme-less value included);
    /// genesis and custom need a scheme and a host.
    func testHlidacIsOffWhenItsURLIsUnusable() throws {
        func base(_ json: String, override: String? = nil) throws -> URL? {
            try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)).hlidacBase(override: override)
        }
        XCTAssertEqual(try base("{}")?.absoluteString, "https://hlidac.ops.example.invalid")
        XCTAssertNil(try base(#"{"hlidacURL": ""}"#))
        XCTAssertNil(try base(#"{"hlidacURL": "  "}"#))
        // example: whatever URL(string:) took before, as before.
        for value in ["hlidac.test", "not a url", "https://h.test", "http://192.0.2.10:8787"] {
            XCTAssertNotNil(URL(string: value), value)
            XCTAssertEqual(try base(#"{"hlidacURL": "\#(value)"}"#), URL(string: value), value)
            XCTAssertEqual(try base(#"{"profile": "example", "hlidacURL": "\#(value)"}"#), URL(string: value), value)
        }
        // A value URL(string:) refuses is off, never example's default.
        XCTAssertNil(URL(string: "http://[::1"))
        XCTAssertNil(try base(#"{"hlidacURL": "http://[::1"}"#))
        // genesis and custom: a scheme and a host, or off.
        for profile in ["genesis", "custom"] {
            XCTAssertNil(try base(#"{"profile": "\#(profile)"}"#), profile)
            XCTAssertNil(try base(#"{"profile": "\#(profile)", "hlidacURL": "hlidac.test"}"#), profile)
            XCTAssertNil(try base(#"{"profile": "\#(profile)", "hlidacURL": "not a url"}"#), profile)
            XCTAssertEqual(try base(#"{"profile": "\#(profile)", "hlidacURL": "https://h.test"}"#)?.host(), "h.test")
        }
        // A Debug override replaces a configured Hlídač, never turns one on.
        XCTAssertEqual(try base("{}", override: "http://127.0.0.1:8787")?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(try base("{}", override: "hlidac.test"), URL(string: "hlidac.test"))
        XCTAssertNil(try base(#"{"profile": "genesis"}"#, override: "http://127.0.0.1:8787"))
        XCTAssertNil(try base(#"{"profile": "genesis", "hlidacURL": "https://h.test"}"#, override: "not a url"))
    }

    /// The apps shelf is example's; another profile reads none.
    func testTheShelfFollowsTheProfile() throws {
        func shelf(_ json: String) throws -> URL? {
            try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)).runtimeConfig.shelf
        }
        XCTAssertEqual(try shelf("{}")?.absoluteString, "https://downloads.example.invalid")
        XCTAssertNil(try shelf(#"{"shelfURL": ""}"#))
        XCTAssertNil(try shelf(#"{"profile": "genesis"}"#))
        XCTAssertNil(try shelf(#"{"profile": "custom"}"#))
        XCTAssertEqual(try shelf(#"{"profile": "genesis", "shelfURL": "https://shelf.test"}"#)?.host(), "shelf.test")
    }

    /// Each toolkit call site keeps the order it always had, with only the
    /// configured path in front: the Toolkit module and Stop… the install
    /// paths (no PATH), Sessions' Focus `/usr/bin/env toolkit`.
    func testToolkitKeepsEachCallSitesOrder() {
        let homebrew = "/opt/homebrew/bin/toolkit"
        let local = NSHomeDirectory() + "/.local/bin/toolkit"
        XCTAssertEqual(ToolkitClient.installPaths, [homebrew, "/usr/local/bin/toolkit", local])
        XCTAssertEqual(ToolkitClient.path(configured: nil, isExecutable: { _ in true }), homebrew)
        XCTAssertEqual(ToolkitClient.path(configured: nil, isExecutable: { $0 != homebrew }), "/usr/local/bin/toolkit")
        XCTAssertEqual(ToolkitClient.path(configured: nil, isExecutable: { $0 == local }), local)
        XCTAssertNil(ToolkitClient.path(configured: nil, isExecutable: { $0.hasPrefix("/usr/bin") }), "no PATH step")
        XCTAssertEqual(ToolkitClient.path(configured: "/pinned/toolkit", isExecutable: { _ in true }), "/pinned/toolkit")
        XCTAssertNil(ToolkitClient.path(configured: "/pinned/toolkit", isExecutable: { $0 != "/pinned/toolkit" }))
        XCTAssertNil(ToolkitClient.path(configured: "bin/toolkit", isExecutable: { _ in true }))

        let focus = ["fleet", "focus", "--session", "s1"]
        let plain = ToolkitClient.focusCommand(focus, configured: nil, isExecutable: { _ in false })
        XCTAssertEqual(plain?.executable.path, "/usr/bin/env")
        XCTAssertEqual(plain?.arguments, ["toolkit"] + focus)
        XCTAssertEqual(ToolkitClient.focusPATH, "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin")
        let pinned = ToolkitClient.focusCommand(focus, configured: "~/pinned/toolkit", isExecutable: { _ in true })
        XCTAssertEqual(pinned?.executable.path, NSHomeDirectory() + "/pinned/toolkit")
        XCTAssertEqual(pinned?.arguments, focus)
        XCTAssertNil(ToolkitClient.focusCommand(focus, configured: "/pinned/toolkit", isExecutable: { _ in false }))
        XCTAssertNil(ToolkitClient.focusCommand(focus, configured: "toolkit", isExecutable: { _ in true }))
    }
}
