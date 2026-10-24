import Foundation

// MARK: - Profiles (docs/specs/2026-10-23-pultik-profiles-decisions.md)
//
// Pultík was written for one estate, and its defaults name that estate's
// hosts, devbox and repos. A profile says whose defaults a Mac gets.
// settings.json `profile` names it; absent means `.example`, so every install
// that predates profiles keeps exactly the defaults it had. A key that
// settings.json sets always wins: a profile only fills what the file leaves
// out. Foundation-only, so the contract harness tests it without the app.

enum PultikProfile: String, CaseIterable, Sendable {
    /// The estate Pultík was written for: its hosts, its devbox, its repos,
    /// ⌥Space and the login item on the first run.
    case example
    /// Another operator's Mac: ⌃Space, no login item, none of example's hosts,
    /// the devbox CLI only where it is installed and ssh only with a key.
    case genesis
    /// Safe empty defaults: no estate host, no ssh probe, no login item.
    /// settings.json says the rest (`pultik install --profile custom` writes
    /// every profile key for editing).
    case custom

    /// settings.json's `profile`. Absent is example; a value no case names is
    /// custom, which names no host, so a typo can never poll an estate.
    static func named(_ raw: String?) -> PultikProfile {
        guard let raw else { return .example }
        return PultikProfile(rawValue: raw) ?? .custom
    }

    /// The `profile` of a settings.json the full decode refused (a trailing
    /// comma, a key of the wrong type), so a broken genesis file never runs
    /// on example's estate. Valid JSON: its string value; a `profile` of
    /// another type is custom; none (or null) is nil, example. Invalid JSON:
    /// the first `"profile": "<known name>"` in the text; a `profile` key
    /// with anything else is custom; no `profile` key at all is nil, so a
    /// broken file that predates profiles keeps example.
    static func peek(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let value = object["profile"], !(value is NSNull) else { return nil }
            return value as? String ?? PultikProfile.custom.rawValue
        }
        let text = String(decoding: data, as: UTF8.self)
        if let match = text.firstMatch(of: #/"profile"\s*:\s*"(example|genesis|custom)"/#) {
            return String(match.1)
        }
        if text.contains(#/"profile"\s*:\s*null/#) { return nil }
        return text.contains(#/"profile"\s*:/#) ? PultikProfile.custom.rawValue : nil
    }

    /// The summon combo when settings.json names none, or one that does not
    /// parse. ⌥Space is Spotlight on some Macs, so genesis takes ⌃Space.
    var hotkey: String {
        self == .genesis ? "control+space" : "option+space"
    }

    /// Whether the first run registers the login item.
    var loginItemOnFirstRun: Bool {
        self == .example
    }

    /// example's estate migrations (a new server, a new service tile, the
    /// prod board's pointers) add example's hosts, so only example runs them.
    var seedsShippedEstate: Bool {
        self == .example
    }

    // Hosts. "" is none: the lane that reads it sends nothing.

    static let exampleHlidacURL = "https://hlidac.ops.example.invalid"

    var prometheusURL: String {
        self == .example ? "http://192.0.2.10:9090" : ""
    }

    var lokiURL: String {
        self == .example ? "http://192.0.2.10:3100" : ""
    }

    var hlidacURL: String {
        self == .example ? Self.exampleHlidacURL : ""
    }

    var eveURL: String {
        self == .example ? "https://app.assistant.example.invalid" : ""
    }

    var sentryURL: String {
        self == .example ? "https://sentry.ops.example.invalid" : ""
    }

    /// The apps shelf Prod's Releases section reads on entering Prod.
    var shelfURL: String {
        self == .example ? "https://downloads.example.invalid" : ""
    }

    // Devbox.

    /// The forced-command ssh key. "" is none, so no ssh probe runs at all.
    var devboxIdentityFile: String {
        self == .example ? "~/.ssh/pultik_devbox" : ""
    }

    /// Where `devbox` is looked for when settings.json names none: example
    /// keeps `~/bin/devbox` alone; the others try PATH first.
    var devboxSearchesPath: Bool {
        self != .example
    }

    /// The boxes polled while `devbox boxes --json` has never answered.
    var devboxFallbackBoxes: [DevboxEndpoint] {
        self == .example ? [.fallback] : []
    }

    /// genesis's projects: the repos its issue and PR searches reach. No prod
    /// pointers (`prod: []` is a deliberate none).
    static let genesisProjects = [
        ProjectSpec(
            key: "genesis", title: "Genesis",
            repos: ["example-org/GenesisTools", "example-org/example-agent-config",
                    "example-org/example-playground", "example-org/example-mobile-app"],
            prod: []
        ),
        ProjectSpec(
            key: "pultik", title: "Pultík · Toolkit",
            repos: ["example-org/pultik", "example-org/toolkit"],
            prod: []
        ),
    ]
}

// MARK: - What clients read

/// The settings a client reads outside `StatusStore`: the estate hosts, the
/// devbox key and executable, toolkit's path, resolved from settings.json over
/// its profile's defaults. `StatusStore` publishes it on launch and on every
/// settings change. Until then nothing is configured, so no client calls out
/// on a guess.
struct RuntimeConfig: Equatable, Sendable {
    var profile: PultikProfile = .custom
    var prometheus: URL?
    var loki: URL?
    var eve: URL?
    var sentry: URL?
    var shelf: URL?
    /// The devbox ssh key, tilde expanded; nil = none configured. A relative
    /// path stays relative and is never used.
    var devboxIdentityFile: String?
    /// settings.json `devboxExecutable`, tilde expanded; nil = search. Set,
    /// it is the only candidate (`ExecutableSearch.find`).
    var devboxExecutable: String?
    var devboxSearchesPath = false
    /// settings.json `toolkitPath`, tilde expanded; nil = search. Set, it is
    /// the only candidate.
    var toolkitPath: String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = RuntimeConfig()

    static var current: RuntimeConfig {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// A configured host: "" (or an unparsable value) is none.
    static func host(_ configured: String?, default fallback: String) -> URL? {
        let raw = (configured ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    /// The devbox key ssh may offer: configured AND present. A missing key
    /// means no ssh at all, because ssh would try anyway and every refused
    /// login counts towards fail2ban.
    func devboxIdentity(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let path = devboxIdentityFile, path.hasPrefix("/"), exists(path) else { return nil }
        return path
    }

    /// The `devbox` CLI: settings.json's path, else example's `~/bin/devbox`
    /// alone, else PATH then `~/bin/devbox`. nil = not installed.
    func devboxCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                   isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let home = NSHomeDirectory() + "/bin/devbox"
        return ExecutableSearch.find(
            "devbox", configured: devboxExecutable, fallbacks: [home],
            environment: devboxSearchesPath ? environment : [:], isExecutable: isExecutable
        )
    }
}

/// A host neither settings.json nor its profile names: the client sends
/// nothing and says which key would set it.
struct UnconfiguredHost: LocalizedError, Equatable {
    let key: String

    var errorDescription: String? {
        "not configured: settings.json \(key) is unset for this profile"
    }
}
