import Foundation

// MARK: - Palette modes ("." prefix — easy on a Czech keyboard, unlike ">")

/// A scoped ALL-view the palette can enter: ".p" → every prod error,
/// ".t" → every todo, ".v" → every listener. Text after the mode token
/// filters within the mode. Esc exits. A mode that maps to a `module` is an
/// alias for it: `.c failed` enters CI with `failed` as its filter.
enum PaletteMode: String, CaseIterable {
    case todos, schedule, prod, vit, boards, issues, fans, notes, organize, work, devbox, ci, estate, health, mac
    // Declared last, so a prefix they share keeps its older mode: `.p` is prod, `.h` health.
    case home, prs

    var title: String {
        switch self {
        case .todos: "All todos"
        case .schedule: "Schedule"
        case .prod: "All prod errors"
        case .vit: "Vitrinka listeners"
        case .boards: "Boards"
        case .issues: "GitHub issues"
        case .fans: "Fan deck"
        case .notes: "All notes"
        case .organize: "Organize workspaces"
        case .work: "Today’s work"
        case .devbox: "Devbox workspaces"
        case .ci: "CI jobs"
        case .estate: "Estate"
        case .health: "Prod"
        case .mac: "Mac health"
        case .home: "Home"
        case .prs: "Pull requests"
        }
    }

    var blurb: String {
        switch self {
        case .todos: "vitrinka todos, every open item — all projects"
        case .schedule: "scheduled vitrinka todos — today, this week, later"
        case .prod: "sentry, last 12 days, staggered"
        case .vit: "boards a session is tuned into"
        case .boards: "recent vitrinka boards, newest first — all projects"
        case .issues: "search every issue in your repos"
        case .fans: "this Mac — fans, temps, vitals"
        case .notes: "scratch notes — read, edit, promote"
        case .organize: "route Warp windows to their displays — hammerspoon"
        case .work: "vitrinka work that needs you — grouped by reason"
        case .devbox: "every workspace — running, held, parked; verbs on hover"
        case .ci: "running jobs, queues and failed runs across lanes"
        case .estate: "servers and every service probe, with latency"
        case .health: "every prod deployment — checks, logs, issues, eve accounts"
        case .mac: "this Mac — likely orphans, memory by family, network (toolkit)"
        case .home: "the Now queue — what needs you, ranked"
        case .prs: "every open PR by repo — checks, reviews, the diff"
        }
    }

    var systemImage: String {
        switch self {
        case .todos: "checklist"
        case .schedule: "calendar.badge.clock"
        case .prod: "exclamationmark.triangle"
        case .vit: "dot.radiowaves.left.and.right"
        case .boards: "rectangle.on.rectangle"
        case .issues: "smallcircle.filled.circle"
        case .fans: "fanblades"
        case .notes: "square.text.square"
        case .organize: "rectangle.3.group"
        case .work: "tray.full"
        case .devbox: "shippingbox"
        case .ci: "gearshape.2"
        case .estate: "server.rack"
        case .health: "waveform.path.ecg"
        case .mac: "memorychip"
        case .home: "house"
        case .prs: "arrow.triangle.pull"
        }
    }

    /// The palette's placeholder inside the mode. Issues are the one mode
    /// whose field searches GitHub rather than filtering what's loaded.
    var fieldHint: String {
        switch self {
        case .issues: "Search issues — text, or #812…"
        case .fans: "Filter sensors…"
        // `.v` enters Sessions: agent sessions, eve approvals and listeners.
        case .vit: "Filter sessions, approvals and listeners…"
        case .organize: "Layout — ↵ runs the top match…"
        case .prs: "Filter PRs — title, repo, #number, branch…"
        default: "Filter \(title.lowercased())…"
        }
    }

    /// The module this mode is an alias for (copilot shell D9); nil keeps it
    /// a palette page (notes, organize, issues, schedule, todos, boards and
    /// the prod archive have no module).
    var module: PanelModule? {
        switch self {
        case .ci: .ci
        case .health: .prod
        case .devbox: .devbox
        case .work: .work
        case .vit: .sessions
        case .estate: .estate
        case .mac, .fans: .mac
        case .home: .home
        case .prs: .prs
        case .todos, .schedule, .prod, .boards, .issues, .notes, .organize: nil
        }
    }

    /// Mac's fans and sensors object: `.f` enters Mac with its detail open.
    static let macFans = "mac:fans"

    /// The object entering through this alias opens, beyond the module itself.
    var opens: String? {
        self == .fans ? Self.macFans : nil
    }

    /// The mode a module filters through (its field hint, its `.x` token):
    /// the module's own name, so Mac stays `.mac` though `.f` enters it too.
    static func alias(of module: PanelModule) -> PaletteMode? {
        allCases.first { $0.module == module && $0.opens == nil }
    }

    /// ".prod redis" → (.prod, "redis"). A mode is entered the moment its
    /// prefix is unambiguous — ".p" is already prod, no ↵ needed. `token` is
    /// what was typed of the mode's name (`c` for `.c failed`).
    ///
    /// A prefix two modes share is the first declared (`.p` prod, not prs),
    /// except a module alias waits while the token is unfinished: entering
    /// clears the field, so `.h` holds (the picker shows health and home)
    /// until `e`, `o` or a space says which.
    static func parse(_ text: String) -> (mode: PaletteMode, filter: String, token: String)? {
        guard text.hasPrefix(".") else { return nil }
        let body = text.dropFirst()
        // Any whitespace ends the token: `.note` followed by a pasted blob
        // that starts with a newline is still the notes mode.
        let token = body.prefix(while: { !$0.isWhitespace }).lowercased()
        guard !token.isEmpty else { return nil }
        let matches = allCases.filter { $0.rawValue.hasPrefix(token) }
        let finished = body.count > token.count
        guard let mode = matches.first(where: { $0.rawValue == token })
            ?? (matches.count == 1 || finished || matches.first?.module == nil ? matches.first : nil)
        else { return nil }
        let rest = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (mode, rest, token)
    }
}
