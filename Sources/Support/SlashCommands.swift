import AppKit
import Foundation

/// Slash commands typed into the palette: `/add-link <url> [title]`.
///
/// Distinct from `QuickCommand` on purpose. A QuickCommand is a fuzzy-matched
/// *destination* ("v" → open vitrinka); a slash command is an explicit verb
/// that takes an argument and changes state. Mixing them would mean a typo in
/// a URL could fuzzy-match its way into running something else.
struct SlashCommand {
    let name: String
    let aliases: [String]
    let usage: String
    let blurb: String
    let action: SlashCommandAction

    init(
        name: String,
        aliases: [String],
        usage: String,
        blurb: String,
        run: @escaping @MainActor (_ argument: String) -> SlashResult
    ) {
        self.name = name
        self.aliases = aliases
        self.usage = usage
        self.blurb = blurb
        action = .local(run)
    }

    init(name: String, aliases: [String], usage: String, blurb: String, action: SlashCommandAction) {
        self.name = name
        self.aliases = aliases
        self.usage = usage
        self.blurb = blurb
        self.action = action
    }

    var allNames: [String] { [name] + aliases }

    /// Returns the line shown back to the user for locally-executed commands.
    @MainActor
    func run(_ argument: String) -> SlashResult {
        guard case .local(let run) = action else {
            return .failed("usage: \(usage)")
        }
        return run(argument)
    }
}

enum SlashCommandAction {
    case local(@MainActor (_ argument: String) -> SlashResult)
    /// Routed through `StatusPanelView`, which owns the Eve conversation state.
    case askEve
}

enum SlashResult {
    case ok(String)
    case failed(String)

    var text: String {
        switch self {
        case .ok(let message), .failed(let message): message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum SlashCommands {
    @MainActor
    static let all: [SlashCommand] = [
        SlashCommand(
            name: "ask",
            aliases: [],
            usage: "/ask <prompt>",
            blurb: "ask eve explicitly",
            action: .askEve
        ),
        SlashCommand(
            name: "add-link",
            aliases: ["link", "bookmark"],
            usage: "/add-link <url> [title]",
            blurb: "save a link to the rail"
        ) { argument in
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard let url = parts.first, !url.isEmpty else {
                return .failed("usage: /add-link <url> [title]")
            }
            switch LinkStore.shared.add(url: url, title: parts.count > 1 ? parts[1] : nil) {
            case .success(let link): return .ok("saved “\(link.title)”")
            case .failure(let error): return .failed(error.message)
            }
        },
        SlashCommand(
            name: "rm-link",
            aliases: ["unlink"],
            usage: "/rm-link <text>",
            blurb: "remove a saved link"
        ) { argument in
            guard let removed = LinkStore.shared.remove(matching: argument) else {
                return .failed("no saved link matches “\(argument)”")
            }
            return .ok("removed “\(removed.title)”")
        },
        SlashCommand(
            name: "pin",
            aliases: [],
            usage: "/pin <owner/repo>",
            blurb: "add a repo to the inbox"
        ) { argument in
            let slug = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            // A bare name would be pinned happily and then 404 on every refresh.
            // Same predicate the store enforces, so this reports the problem
            // instead of "pinned" over a silent rejection.
            guard StatusStore.isRepoSlug(slug) else {
                return .failed("needs owner/repo — e.g. /pin example-org/ExampleApp")
            }
            guard !StatusStore.shared.pinned.contains(slug) else {
                return .failed("\(slug) is already pinned")
            }
            StatusStore.shared.pin(slug)
            return .ok("pinned \(slug)")
        },
        SlashCommand(
            name: "unpin",
            aliases: [],
            usage: "/unpin <repo>",
            blurb: "drop a repo from the inbox"
        ) { argument in
            let needle = argument.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return .failed("usage: /unpin <repo>") }
            // Match the short name too — nobody types the owner to remove one.
            guard let slug = StatusStore.shared.pinned.first(where: {
                $0.lowercased() == needle || $0.lowercased().hasSuffix("/\(needle)")
            }) else {
                return .failed("no pinned repo matches “\(argument)”")
            }
            StatusStore.shared.unpin(slug)
            return .ok("unpinned \(slug)")
        },
        SlashCommand(
            name: "hide",
            aliases: [],
            usage: "/hide <section>",
            blurb: "hide a panel section"
        ) { argument in setSection(argument, visible: false) },
        SlashCommand(
            name: "show",
            aliases: [],
            usage: "/show <section>",
            blurb: "bring a section back"
        ) { argument in setSection(argument, visible: true) },
        SlashCommand(
            name: "vault",
            aliases: [],
            usage: "/vault",
            blurb: "retired — todos live in vitrinka now"
        ) { _ in
            // Kept as a signpost for muscle memory, not a verb: the vault is
            // read-only history since 2026-09-05 (`vitrinka import pultik`).
            .failed("the todo vault is retired — todos live in vitrinka (\(VitrinkaClient.shared.myWorkURL.absoluteString)); vitrinka todo | schedule in a terminal")
        },
        SlashCommand(
            name: "ssh",
            aliases: [],
            usage: "/ssh <host>",
            blurb: "open a shell on a VPS"
        ) { argument in
            let servers = StatusStore.shared.servers
            let needle = argument.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else {
                let names = servers.map(\.name).joined(separator: ", ")
                return .failed("usage: /ssh <host> — \(names)")
            }
            guard let server = servers.first(where: { $0.name.lowercased().hasPrefix(needle) })
            else {
                return .failed("no server named “\(argument)”")
            }
            guard let target = server.ssh, !target.isEmpty else {
                return .failed("\(server.name) has no ssh target configured")
            }
            // ssh:// goes to whatever the user registered as the handler —
            // Terminal by default, Warp/iTerm if they claimed the scheme.
            guard let url = URL(string: "ssh://\(target)") else {
                return .failed("“\(target)” is not a usable ssh target")
            }
            NSWorkspace.shared.open(url)
            return .ok("opening \(server.name) (\(target))")
        },
        SlashCommand(
            name: "open",
            aliases: [],
            usage: "/open <path>",
            blurb: "Finder for a directory, its app for a file"
        ) { argument in pathVerb(.open, argument) },
        SlashCommand(
            name: "reveal",
            aliases: [],
            usage: "/reveal <path>",
            blurb: "select the path in Finder"
        ) { argument in pathVerb(.reveal, argument) },
        SlashCommand(
            name: "code",
            aliases: ["edit"],
            usage: "/code <path>[:line]",
            blurb: "open in the code editor"
        ) { argument in pathVerb(.code, argument) },
        SlashCommand(
            name: "term",
            aliases: ["terminal"],
            usage: "/term <path>",
            blurb: "a terminal in that directory"
        ) { argument in pathVerb(.terminal, argument) },
        SlashCommand(
            name: "editor",
            aliases: [],
            usage: "/editor [cursor|vscode|zed|auto]",
            blurb: "which editor /code and ⌘↵ use"
        ) { argument in
            let raw = argument.trimmingCharacters(in: .whitespaces)
            let installed = CodeEditor.installed.map(\.id).joined(separator: ", ")
            guard !raw.isEmpty else {
                let current = CodeEditor.current?.name ?? "none installed"
                let source = StatusStore.shared.codeEditor == nil ? "auto" : "settings.json"
                return .ok("editor: \(current) (\(source)) — installed: \(installed)")
            }
            if raw.lowercased() == "auto" {
                StatusStore.shared.setCodeEditor(nil)
                return .ok("editor: auto — \(CodeEditor.current?.name ?? "none installed")")
            }
            guard let editor = CodeEditor.named(raw) else {
                return .failed("unknown editor — try: \(CodeEditor.known.map(\.id).joined(separator: ", ")), auto")
            }
            StatusStore.shared.setCodeEditor(editor.id)
            return editor.isInstalled
                ? .ok("editor: \(editor.name)")
                : .ok("editor: \(editor.name) — not installed here, using \(CodeEditor.current?.name ?? "none") meanwhile")
        },
        SlashCommand(
            name: "note",
            aliases: [],
            usage: "/note <text>",
            blurb: "jot a scratch note"
        ) { argument in
            guard let note = NoteStore.shared.add(argument) else {
                return .failed("usage: /note <text>")
            }
            return .ok("noted “\(note.text)”")
        },
        SlashCommand(
            name: "rm-note",
            aliases: ["unnote"],
            usage: "/rm-note <text>",
            blurb: "remove a note"
        ) { argument in
            guard let removed = NoteStore.shared.remove(matching: argument) else {
                return .failed("no note matches “\(argument)”")
            }
            return .ok("removed “\(removed.text)”")
        },
    ]

    /// Section keys the panel actually understands. Validated so a typo says so
    /// instead of silently hiding nothing.
    static let sectionKeys = ["prod", "servers", "services", "ci", "runners", "devbox"]

    @MainActor
    private static func setSection(_ argument: String, visible: Bool) -> SlashResult {
        let key = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard sectionKeys.contains(key) else {
            return .failed("unknown section — try: \(sectionKeys.joined(separator: ", "))")
        }
        StatusStore.shared.setSection(key, visible: visible)
        return .ok("\(key) \(visible ? "shown" : "hidden")")
    }


    /// `/open`, `/reveal`, `/code`, `/term` — the same repair and verbs as
    /// the implicit path card, for the times the detector is not trusted.
    @MainActor
    private static func pathVerb(_ verb: PathVerb, _ argument: String) -> SlashResult {
        guard !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("usage: /\(verb.rawValue == "terminal" ? "term" : verb.rawValue) <path>")
        }
        guard let target = PathTarget.detect(argument) else {
            return .failed("no such path — nothing on disk near \(argument.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let result = verb.run(target)
        if let missing = target.missing {
            return .ok("\(result.text) — \((missing as NSString).abbreviatingWithTildeInPath) does not exist, nearest directory")
        }
        return result
    }

    /// Parses "/add-link https://x.dev Title" into a command + its argument.
    /// Returns nil when the text isn't a slash command at all.
    @MainActor
    static func parse(_ text: String) -> (command: SlashCommand, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        let split = body.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = split.first?.lowercased() else { return nil }
        guard let command = all.first(where: { $0.allNames.contains(verb) }) else { return nil }
        return (command, split.count > 1 ? split[1] : "")
    }

    /// Commands whose name starts with what's typed so far — drives the hint
    /// list under the palette while the user is still typing the verb.
    @MainActor
    static func matching(_ text: String) -> [SlashCommand] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.dropFirst().contains(" ") else { return [] }
        let prefix = trimmed.dropFirst().lowercased()
        guard !prefix.isEmpty else { return all }
        return all.filter { command in
            command.allNames.contains { $0.hasPrefix(prefix) }
        }
    }
}
