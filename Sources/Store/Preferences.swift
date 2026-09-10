import Foundation

/// Pultík's durable settings.
///
/// Stored as JSON in Application Support rather than `UserDefaults`: the
/// defaults domain is tied to the app bundle and is wiped by `defaults delete`,
/// by clearing caches, and by some rebuild/reinstall flows. A plain file in
/// ~/Library/Application Support/Pultik/settings.json survives all of that,
/// and is editable and backup-able by hand.
struct Preferences: Codable {
    var pinnedRepos: [String] = []
    /// Bundle id the login item was auto-enabled for. Keyed to the bundle id
    /// (not a plain flag) because SMAppService registration is per-bundle:
    /// after a bundle-id change the auto-enable must run once more, while a
    /// manual opt-out in Settings is still never silently re-enabled.
    var loginItemConfiguredFor: String?
    /// Sentry API token override; when nil the SENTRY_AUTH_TOKEN cached in
    /// ~/.claude/.env is used.
    var sentryToken: String?
    /// eve `evk_` API token override; when nil the PULTIK_EVE_TOKEN cached in
    /// ~/.claude/.env is used. (PULTIK_-prefixed on purpose: that file is
    /// sourced by Claude sessions, where a bare EVE_TOKEN would override the
    /// eve CLI's own.)
    var eveToken: String?
    /// Sentry project slugs polled for production issues.
    var sentryProjects: [String] = Preferences.defaultSentryProjects

    static let defaultSentryProjects = ["exampleapp-api", "exampleapp-mobile", "booking-back", "booking"]

    /// Summon combo, e.g. "option+space", "cmd+option+space", "control+p".
    /// Applied at launch; unparseable values fall back to the default.
    var hotkey: String = HotKey.defaultSpec
    /// Panel sections the user switched off (Settings toggles). Known keys:
    /// prod, servers, services, ci, runners, alerts.
    var hiddenSections: [String] = []
    /// VPS cards for the left rail: display name + prometheus instance label.
    var servers: [NamedRef] = Preferences.defaultServers
    /// Service tiles for the right rail: display name + blackbox probe instance.
    var services: [NamedRef] = Preferences.defaultServices
    /// The on-call registry: what each product is made of.
    var projects: [ProjectSpec] = Preferences.defaultProjects
    /// Fixed main-list order: repos whose slug contains one of these names
    /// (case-insensitive) come first, in exactly this sequence; everything
    /// else follows by recency. Predictability over cleverness.
    var repoOrder: [String] = Preferences.defaultRepoOrder

    static let defaultRepoOrder = [
        "ExampleApp", "assistant-service", "vitrinka", "Booking", "example-platform", "example-deployik",
    ]

    /// Eve alert lanes shown in the panel — the ledger stores every lane,
    /// pultik filters client-side. Default: the attention lanes.
    var visibleAlertLanes: [String] = Preferences.defaultAlertLanes

    static let defaultAlertLanes = ["incidents", "exampleapp_prod_alerts", "priority"]

    /// Every lane eve routes to a Telegram forum topic today — the Settings
    /// toggle list. An unknown lane in the feed still shows once toggled in
    /// via settings.json; this is UI vocabulary, not a filter whitelist.
    static let knownAlertLanes = [
        "incidents", "priority", "exampleapp_prod_alerts", "reviews", "leads",
        "inbox", "qa", "system", "general",
    ]

    /// Fan curve currently driving the fans — a `FanCurve` preset id, or nil
    /// for OS-managed. The helper owns the running curve; this is only so a
    /// relaunch knows what to show as selected.
    var activeFanCurve: String?
    /// Edited curve shapes by preset id (decision D6: presets are editable in
    /// place). Absent id = that preset is still its shipped default, which is
    /// also what "Restore default" gets back to by deleting the entry.
    var fanCurves: [String: [CurvePoint]] = [:]
    /// `TempSmoother` time constant for the driving temperature, in seconds.
    /// 0 = react to every reading. Lives here rather than per-curve: it
    /// describes how twitchy the user wants the fans, not the shape of a ramp.
    var fanCurveSmoothing: Double = TempSmoother.defaultSeconds

    // Devbox slot metrics come straight from `devbox hub --json` since the
    // hub verb landed — the old cadvisor instance/name-pattern settings
    // (devboxInstance/devboxNamePattern) are gone; stale keys in
    // settings.json are simply ignored.

    /// Expiry radar watchlist — things with an expiry date that should become
    /// scheduled todos automatically. `tls` items are probed (cert notAfter);
    /// `manual` items carry the date you typed (PATs, domain renewals).
    var expiryWatch: [ExpiryWatchItem] = []

    struct ExpiryWatchItem: Codable, Identifiable, Equatable {
        var kind: String        // "tls" | "manual"
        var host: String?       // tls: hostname, port 443
        var name: String?       // manual: what expires
        var expires: String?    // manual: YYYY-MM-DD
        var lead: String = "21d"

        var id: String { kind == "tls" ? "tls:\(host ?? "")" : "manual:\(name ?? "")" }
        var label: String { kind == "tls" ? (host ?? "?") : (name ?? "?") }
    }

    /// Hold notifications while a macOS Focus is active, flush when it lifts.
    var focusHoldsNotifications: Bool = false

    /// RETIRED 2026-09-05: the Obsidian vault is read-only history; todos live
    /// in vitrinka. Still decoded and re-saved so an old settings.json round-
    /// trips untouched, but nothing reads it.
    var vaultPath: String?
    /// The vitrinka project slug the panel's own writers file into — a
    /// promoted note, an expiry-radar reminder. Nil = unset; those writers
    /// then refuse with a pointer at Settings ▸ General. Sessions never use
    /// it: `vitrinka todo add` files into the checkout's project.
    var todoProject: String?
    /// Code editor for the palette path card (`CodeEditor.known` id: cursor,
    /// vscode, zed). Nil = first installed. Settings ▸ General or `/editor`.
    var codeEditor: String?

    /// Display presets (docs/specs/2026-09-06-display-presets-decisions.md):
    /// absolute brightness percent + Night Shift per named preset, edited in
    /// Settings ▸ Displays. Nil = `DisplayPreset.defaults`.
    var displayPresets: [DisplayPreset]?
    /// RETIRED 2026-09-06 by `displayPresets`; migrated into the Dim preset
    /// by `migrateDisplayPresets()` and then dropped from the file.
    var dimBrightness: Double?
    /// Never Sleep (docs/specs/2026-09-10-never-sleep-decisions.md): true
    /// while the Mac is held awake and unlocked; re-armed at launch. Absent
    /// (never false) when off, so an untouched file stays untouched.
    var neverSleep: Bool?

    /// Right-rail sections the user has folded shut. Collapse is a preference,
    /// not session state — the rail reopens the way you left it. The vitals
    /// dock is deliberately not collapsible and never appears here.
    var collapsedRails: [String] = []

    /// Share of the left column the Vitrinka rail takes above the Devbox
    /// rail (0.2–0.8); the drag handle between them writes it
    /// (spec 2026-09-09 decision 8). nil = the 40 % default.
    var leftRailSplit: Double?

    /// Workspace layouts for the Hammerspoon `.organize` engine
    /// (hammerspoon/organize.lua; docs/specs/2026-09-01-organize-workspaces-
    /// decisions.md). Modeled here even though the app only lists layout
    /// names: a Codable round-trip drops unknown keys on save(), which would
    /// silently erase a section the Lua engine or a hand edit wrote.
    var workspaces: WorkspacesConfig?

    struct WorkspacesConfig: Codable {
        var layouts: [String: WorkspaceLayout]?
    }

    struct WorkspaceLayout: Codable {
        /// Display role → ordered display-name matches ("xdr" → ["Pro Display
        /// XDR", "Built-in"]); the first attached match wins.
        var displays: [String: [String]]?
        var rules: [WorkspaceRule]?
    }

    struct WorkspaceRule: Codable {
        var project: String?
        var app: String?
        var rest: Bool?
        var to: String?
        var spawn: Bool?
    }

    /// One row of Settings ▸ Displays. `brightness` is an integer percent so
    /// the file reads the way the slider does; the bridges take 0…1.
    struct DisplayPreset: Codable, Equatable, Identifiable {
        enum NightShift: String, Codable, CaseIterable {
            /// Force Night Shift on / off, or leave it as the user set it.
            case on, off, keep

            var title: String {
                switch self {
                case .on: "On"
                case .off: "Off"
                case .keep: "Keep"
                }
            }
        }

        /// Stable identity across rename, reorder and delete. Minted when a
        /// hand-edited file omits it, so it is never a required key.
        var id: String
        var name: String
        var brightness: Int
        var nightShift: NightShift
        /// Keyboard backlight percent (spec 2026-09-10 decision 3); nil = keep
        /// whatever it is, which is what every pre-existing preset decodes to.
        var keyboard: Int?

        init(id: String = UUID().uuidString, name: String, brightness: Int, nightShift: NightShift,
             keyboard: Int? = nil) {
            self.id = id
            self.name = name
            self.brightness = brightness
            self.nightShift = nightShift
            self.keyboard = keyboard
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try c.decode(String.self, forKey: .name)
            brightness = try c.decode(Int.self, forKey: .brightness)
            nightShift = try c.decodeIfPresent(NightShift.self, forKey: .nightShift) ?? .keep
            keyboard = try c.decodeIfPresent(Int.self, forKey: .keyboard)
        }

        var level: Double { Double(min(max(brightness, 0), 100)) / 100 }

        var keyboardLevel: Double? { keyboard.map { Double(min(max($0, 0), 100)) / 100 } }

        static let defaults: [DisplayPreset] = [
            DisplayPreset(name: "Dim", brightness: 15, nightShift: .on),
            DisplayPreset(name: "Bright", brightness: 100, nightShift: .off),
        ]
    }

    struct NamedRef: Codable, Identifiable {
        var name: String
        var ref: String
        /// Servers only: what `/ssh <name>` should connect to. Optional, so an
        /// older settings.json without the key still decodes.
        var ssh: String?
        /// Services only: the `servers[].name` of the box this service RUNS on
        /// — which is not where the prober lives (api.example.invalid is probed from
        /// BuildServer and served from AppServer). Drives the services rail's
        /// host grouping; nil files the service under "elsewhere".
        var host: String?
        var id: String { ref }
    }

    /// `ref` is the prometheus instance label; `ssh` is the shell target, which
    /// is a different thing entirely — "build-vps" is not a host you can reach.
    /// BuildServer goes through the `build-server-admin` alias (root@192.0.2.10 on a
    /// destination-scoped key), which since the 2026-08 migration means the
    /// WireGuard mesh has to be up — sshd listens nowhere else. AppServer's
    /// label is still `example-vps`: the estate rename (2026-08-18) deliberately
    /// left Prometheus labels alone, so the label and the name disagree forever.
    static let defaultServers = [
        NamedRef(name: "BuildServer", ref: "build-vps", ssh: "build-server-admin"),
        NamedRef(name: "AppServer", ref: "example-vps", ssh: "app-server"),
        NamedRef(name: "WebServer", ref: "web-server", ssh: "web-server"),
    ]

    /// ssh aliases that no longer exist, and what replaced them. A saved
    /// settings.json pins whatever was current when it was written, so without
    /// this `/ssh build-server` keeps opening a dead alias forever.
    static let retiredSSHAliases = ["devops": "build-server-admin"]

    /// `host` is where the service RUNS, verified against cadvisor rather than
    /// guessed from the probe URL: exampleapp-prod's api containers and vitrinka's
    /// blue/green pair are on AppServer, booking.example.invalid is served by WebServer's
    /// deployik, and the probed `eve-exampleapp-prod` API container is on BuildServer
    /// even though its gateway/chat/litellm tier lives on AppServer.
    static let defaultServices = [
        NamedRef(name: "exampleapp-prod", ref: "https://api.example.invalid/api/v1/health", host: "AppServer"),
        NamedRef(name: "vitrinka-prod", ref: "https://boards.example.invalid", host: "AppServer"),
        NamedRef(name: "eve-exampleapp-prod", ref: "http://eve-exampleapp-prod:3141/eve/v1/health", host: "BuildServer"),
        NamedRef(name: "exampleapp-dev", ref: "https://api.app.dev.example.invalid/api/v1/health", host: "BuildServer"),
        NamedRef(name: "booking-prod", ref: "https://booking.example.invalid", host: "WebServer"),
    ]

    static let defaultProjects = [
        ProjectSpec(
            key: "exampleapp", title: "ExampleApp",
            repos: ["example-org/ExampleApp"],
            sentryProjects: ["exampleapp-api", "exampleapp-mobile"],
            services: ["exampleapp-prod", "exampleapp-dev"],
            links: [
                .init(title: "Status", url: "https://status.example.invalid"),
                .init(title: "Sentry", url: "https://sentry.ops.example.invalid/organizations/sentry/projects/exampleapp-api/"),
                .init(title: "Grafana", url: "https://grafana.ops.example.invalid"),
                .init(title: "Admin dev", url: "https://admin.app.dev.example.invalid"),
            ]
        ),
        ProjectSpec(
            key: "booking", title: "Booking",
            repos: ["Booking/Booking", "Booking/BookingBack", "Booking/Integrations", "Booking/booking.web"],
            sentryProjects: ["booking-back", "booking", "booking-onboarding"],
            services: ["booking-prod"],
            links: [
                .init(title: "booking.example.invalid", url: "https://booking.example.invalid"),
                .init(title: "Sentry", url: "https://sentry.ops.example.invalid/organizations/sentry/projects/booking-back/"),
            ]
        ),
        ProjectSpec(
            key: "eve", title: "eve",
            repos: ["example-org/assistant-service"],
            sentryProjects: ["eve-exampleapp"],
            services: ["eve-exampleapp-prod"],
            links: [
                .init(title: "Console", url: "https://eve.ops.example.invalid"),
                .init(title: "Grafana", url: "https://grafana.ops.example.invalid"),
            ]
        ),
        ProjectSpec(
            key: "vitrinka", title: "vitrinka",
            repos: ["example-org/vitrinka"],
            links: [.init(title: "boards.example.invalid", url: "https://boards.example.invalid")]
        ),
        ProjectSpec(
            key: "example", title: "example",
            repos: ["example-org/trading", "example-org/app-server-infra", "example-org/build-server-infra"],
            links: [
                .init(title: "Trading", url: "https://trading.ops.example.invalid"),
                .init(title: "Grafana", url: "https://grafana.ops.example.invalid"),
            ]
        ),
    ]

    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Pultik", directoryHint: .isDirectory)

    static let fileURL = directory.appending(path: "settings.json")

    /// Pre-rename location (the app used to be Hubbar) — read-only fallback.
    static let legacyFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Hubbar/settings.json")

    /// Decoded field-by-field with `decodeIfPresent` so that adding a property
    /// later can never fail the whole decode — a synthesized `Codable` init
    /// requires every key even when the property has a default, which would
    /// make an older settings.json unreadable and get it overwritten empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinnedRepos = try container.decodeIfPresent([String].self, forKey: .pinnedRepos) ?? []
        loginItemConfiguredFor = try container.decodeIfPresent(String.self, forKey: .loginItemConfiguredFor)
        sentryToken = try container.decodeIfPresent(String.self, forKey: .sentryToken)
        eveToken = try container.decodeIfPresent(String.self, forKey: .eveToken)
        sentryProjects = try container.decodeIfPresent([String].self, forKey: .sentryProjects)
            ?? Preferences.defaultSentryProjects
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? HotKey.defaultSpec
        hiddenSections = try container.decodeIfPresent([String].self, forKey: .hiddenSections) ?? []
        servers = try container.decodeIfPresent([NamedRef].self, forKey: .servers)
            ?? Preferences.defaultServers
        services = try container.decodeIfPresent([NamedRef].self, forKey: .services)
            ?? Preferences.defaultServices
        projects = try container.decodeIfPresent([ProjectSpec].self, forKey: .projects)
            ?? Preferences.defaultProjects
        repoOrder = try container.decodeIfPresent([String].self, forKey: .repoOrder)
            ?? Preferences.defaultRepoOrder
        visibleAlertLanes = try container.decodeIfPresent([String].self, forKey: .visibleAlertLanes)
            ?? Preferences.defaultAlertLanes
        activeFanCurve = try container.decodeIfPresent(String.self, forKey: .activeFanCurve)
        fanCurves = try container.decodeIfPresent([String: [CurvePoint]].self, forKey: .fanCurves)
            ?? [:]
        fanCurveSmoothing = try container.decodeIfPresent(Double.self, forKey: .fanCurveSmoothing)
            ?? TempSmoother.defaultSeconds
        expiryWatch = try container.decodeIfPresent([ExpiryWatchItem].self, forKey: .expiryWatch) ?? []
        focusHoldsNotifications = try container.decodeIfPresent(
            Bool.self, forKey: .focusHoldsNotifications) ?? false
        vaultPath = try container.decodeIfPresent(String.self, forKey: .vaultPath)
        todoProject = try container.decodeIfPresent(String.self, forKey: .todoProject)
        collapsedRails = try container.decodeIfPresent([String].self, forKey: .collapsedRails) ?? []
        leftRailSplit = try container.decodeIfPresent(Double.self, forKey: .leftRailSplit)
        workspaces = try container.decodeIfPresent(WorkspacesConfig.self, forKey: .workspaces)
        displayPresets = try container.decodeIfPresent([DisplayPreset].self, forKey: .displayPresets)
        dimBrightness = try container.decodeIfPresent(Double.self, forKey: .dimBrightness)
        neverSleep = try container.decodeIfPresent(Bool.self, forKey: .neverSleep)
    }

    /// The shape for `id`: the user's edit if there is one, otherwise the
    /// shipped preset. Always guarded — a settings.json edited by hand can
    /// carry a descending ramp, and that must never reach the fans.
    func fanCurve(_ id: String) -> FanCurve? {
        guard let preset = FanCurve.preset(id) else { return nil }
        guard let edited = fanCurves[id] else { return preset }
        return FanCurve(id: preset.id, name: preset.name, points: edited).guarded()
    }

    init(pinnedRepos: [String] = [], loginItemConfiguredFor: String? = nil) {
        self.pinnedRepos = pinnedRepos
        self.loginItemConfiguredFor = loginItemConfiguredFor
    }

    static func load() -> Preferences {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                var loaded = try JSONDecoder().decode(Preferences.self, from: data)
                if loaded.applyMigrations() { loaded.save() }
                return loaded
            } catch {
                // Never silently discard a file we could not parse: keep a copy
                // so nothing is lost, and surface it.
                NSLog("pultik: settings.json unreadable (%@) — backing up", error.localizedDescription)
                try? FileManager.default.moveItem(
                    at: fileURL,
                    to: directory.appending(path: "settings.corrupt.json")
                )
            }
        }
        // One-time migration from the Hubbar-era file (pre-rename).
        if let data = try? Data(contentsOf: legacyFileURL),
           var migrated = try? JSONDecoder().decode(Preferences.self, from: data) {
            // The Hubbar-era file predates every migration below, so it needs
            // them too — it is saved unconditionally here, and skipping them
            // would leave this whole session on a stale estate.
            _ = migrated.applyMigrations()
            migrated.save()
            return migrated
        }
        // One-time migration from the pre-0.3 UserDefaults location.
        if let legacy = UserDefaults.standard.stringArray(forKey: "pinnedRepos"), !legacy.isEmpty {
            let migrated = Preferences(pinnedRepos: legacy)
            migrated.save()
            return migrated
        }
        return Preferences()
    }

    /// Every in-place rewrite a decoded settings file may need, in one place so
    /// each `load()` path gets all of them and none can drift. Returns whether
    /// anything changed, so a file is only rewritten when it actually needs it.
    private mutating func applyMigrations() -> Bool {
        // Deliberately not short-circuited: every migration must run.
        let retired = retireDeadSSHAliases()
        let servers = migrateServerEstate()
        let services = migrateServiceEstate()
        let presets = migrateDisplayPresets()
        let repos = migrateRepoSlugs()
        return retired || servers || services || presets || repos
    }

    /// The 2026-09-08 org rename: the GitHub org `example-org` became
    /// `example-org`, and three repos were themselves renamed along the way
    /// (`example` → `trading`, `example-infra` → `app-server-infra`,
    /// `example-devops-infra` → `build-server-infra`). A saved settings.json pins
    /// both `pinnedRepos` and every `projects[].repos`, so `defaultProjects`
    /// alone never reaches an existing install — rewrite the saved lists.
    ///
    /// An explicit slug map, NOT a blanket owner rewrite: the old owners still
    /// hold repos that did not move, so renaming an owner wholesale would
    /// invent dead slugs. GitHub still redirects the old names today;
    /// this exists because a NEW empty `example-org` org now squats the
    /// freed name, and any repo it creates would capture that redirect.
    ///
    /// Two old slugs can collapse onto one canonical repo (both infra pairs),
    /// so each list is de-duplicated in place, keeping first-seen order.
    /// Built with `uniquingKeysWith` from PAIRS rather than written as a
    /// dictionary literal, and that is load-bearing: the public mirror rewrites
    /// every real owner to one shared placeholder, which collapses distinct keys
    /// here into identical ones. A dictionary LITERAL with duplicate keys is a
    /// runtime trap ("Dictionary literal contains duplicate keys"), so the
    /// rendered public source would crash on first use. Pairs + last-wins-free
    /// uniquing make the sanitized render merely redundant instead of fatal.
    /// Do not "simplify" this back to a literal.
    static let renamedRepoSlugs = Dictionary(
        [
            ("example-org/example-devops-infra", "example-org/build-server-infra"),
            ("example-org/example-infra", "example-org/app-server-infra"),
            ("example-org/example-devops-infra", "example-org/build-server-infra"),
            ("example-org/example-infra", "example-org/app-server-infra"),
            ("example-org/example", "example-org/trading"),
            ("example-org/ExampleApp", "example-org/ExampleApp"),
            ("example-org/assistant-service", "example-org/assistant-service"),
            ("example-org/vitrinka", "example-org/vitrinka"),
            // Not the org rename: the backend repo moved from a personal
            // account into the Booking org, and both slugs were pinned.
            ("example-org/BookingBack", "Booking/BookingBack"),
        ],
        uniquingKeysWith: { first, _ in first }
    )

    /// Rewrite one saved slug list, reporting whether anything moved.
    /// Internal rather than private so `Tests/` can exercise the collapse case.
    static func migrateSlugList(_ slugs: inout [String]) -> Bool {
        var seen = Set<String>()
        var rewritten: [String] = []
        var changed = false
        for slug in slugs {
            var canonical = renamedRepoSlugs[slug]
            if canonical == nil, slug.hasPrefix("example-org/") {
                canonical = "example-org/" + slug.dropFirst("example-org/".count)
            }
            if let canonical {
                NSLog("pultik: repo '%@' re-orged — now '%@'", slug, canonical)
                changed = true
            }
            let final = canonical ?? slug
            if seen.insert(final).inserted { rewritten.append(final) } else { changed = true }
        }
        if changed { slugs = rewritten }
        return changed
    }

    private mutating func migrateRepoSlugs() -> Bool {
        var changed = Self.migrateSlugList(&pinnedRepos)
        for index in projects.indices {
            if Self.migrateSlugList(&projects[index].repos) { changed = true }
        }
        return changed
    }

    /// The 2026-09-06 display presets pass: a saved `dimBrightness` becomes
    /// the Dim preset's percent, then the key leaves the file. (`dimmedFrom`,
    /// the old restore snapshot, is simply no longer decoded — restore is
    /// gone with the toggle.)
    private mutating func migrateDisplayPresets() -> Bool {
        guard let level = dimBrightness else { return false }
        if displayPresets == nil {
            var presets = DisplayPreset.defaults
            presets[0].brightness = Int((level * 100).rounded())
            displayPresets = presets
        }
        dimBrightness = nil
        return true
    }

    /// The 2026-08-27 services pass. Three in-place rewrites of a saved list:
    ///
    /// 1. `assistant-service` was never the eve AI layer — it has always probed the
    ///    `eve-exampleapp-prod` health endpoint, so the tile carried a name that
    ///    described a different thing than the one it was reporting on.
    /// 2. `vitrinka-prod` was missing entirely even though the probe existed.
    /// 3. `host` is new, so every saved service has nil and the whole rail
    ///    would collapse into one "elsewhere" group until it is backfilled.
    ///
    /// Backfill is keyed on `ref`, not `name`: the ref is the probe instance
    /// and is the only stable identity a hand-edited file is guaranteed to keep.
    private mutating func migrateServiceEstate() -> Bool {
        var changed = false

        for index in services.indices where services[index].name == "assistant-service"
            && services[index].ref.contains("eve-exampleapp-prod") {
            services[index].name = "eve-exampleapp-prod"
            changed = true
            NSLog("pultik: service 'assistant-service' renamed — now 'eve-exampleapp-prod' (what it always probed)")
        }

        let hostsByRef = Dictionary(
            uniqueKeysWithValues: Self.defaultServices.map { ($0.ref, $0.host) }
        )
        for index in services.indices where services[index].host == nil {
            guard let host = hostsByRef[services[index].ref] ?? nil else { continue }
            services[index].host = host
            changed = true
        }

        if !services.contains(where: { $0.ref == "https://boards.example.invalid" }),
           let template = Self.defaultServices.first(where: { $0.ref == "https://boards.example.invalid" }) {
            // Beside its estate-mate rather than appended: the rail groups by
            // host, and an append would read as a stray until the next sort.
            let anchor = services.firstIndex { $0.host == "AppServer" }
            services.insert(template, at: anchor.map { $0 + 1 } ?? services.count)
            changed = true
            NSLog("pultik: service 'vitrinka-prod' added to the saved estate")
        }
        return changed
    }

    /// Rewrites saved `ssh` targets that point at an alias which no longer
    /// exists. Returns whether anything changed, so the file is only rewritten
    /// when it actually needs it.
    private mutating func retireDeadSSHAliases() -> Bool {
        var changed = false
        for index in servers.indices {
            guard let current = servers[index].ssh,
                  let replacement = Self.retiredSSHAliases[current] else { continue }
            servers[index].ssh = replacement
            changed = true
            NSLog("pultik: ssh alias '%@' retired — now '%@'", current, replacement)
        }
        return changed
    }

    /// The 2026-08-18 estate rename: "Example" is now AppServer (ExampleApp
    /// production, ssh alias `app-server`), and WebServer (client sites,
    /// 192.0.2.20 — the address the old entry ssh'd into) joined as a third
    /// server. The Prometheus label `example-vps` was deliberately not renamed
    /// server-side, so the ref survives; only the name and shell target move.
    /// A saved settings.json pins the old list, so rewrite it in place.
    private mutating func migrateServerEstate() -> Bool {
        var changed = false
        for index in servers.indices where servers[index].name == "Example" {
            servers[index].name = "AppServer"
            servers[index].ssh = "app-server"
            changed = true
            NSLog("pultik: server 'Example' renamed — now 'AppServer' (ssh 'app-server')")
        }
        if !servers.contains(where: { $0.ref == "web-server" }),
           let anchor = servers.firstIndex(where: { $0.ref == "example-vps" }) {
            servers.insert(
                NamedRef(name: "WebServer", ref: "web-server", ssh: "web-server"),
                at: anchor + 1
            )
            changed = true
            NSLog("pultik: server 'WebServer' added to the saved estate")
        }
        return changed
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("pultik: failed to save settings: %@", error.localizedDescription)
        }
    }
}
