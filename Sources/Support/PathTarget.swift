import AppKit
import Foundation

/// A file-system path pasted into the palette, repaired and checked on disk.
///
/// The typical input is what an AI printed into a terminal: an absolute path
/// wrapped mid-word by the terminal (`…/.worktr\n      ees/push`), often with
/// a trailing comma, a quote, or a `:line:col` suffix. Detection is pure — no
/// view state — so the slash verbs and the palette card share one truth.
/// Decisions: docs/specs/2026-09-03-palette-paths-decisions.md.
struct PathTarget: Equatable {
    /// What exists on disk: the repaired path itself, or its deepest existing
    /// ancestor when the tail was mangled or the directory is gone.
    let url: URL
    let isDirectory: Bool
    /// The repaired path as typed when `url` is only its nearest ancestor.
    let missing: String?
    let line: Int?
    let column: Int?

    var isNearest: Bool { missing != nil }
    var name: String { url.lastPathComponent }

    /// The directory a terminal or Finder window should land in.
    var directoryURL: URL { isDirectory ? url : url.deletingLastPathComponent() }

    /// `~`-abbreviated parent directory for the card's dim second line.
    var abbreviatedDirectory: String {
        (directoryURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Detection

    /// Does the text even look like it wants to be a path? Cheap, no I/O —
    /// gates the per-keystroke `detect`. Only absolute forms: a bare word can
    /// never be a path, or every search would stat the disk.
    static func looksLikePath(_ text: String) -> Bool {
        let head = text.drop(while: { $0.isWhitespace || leadingDecoration.contains($0) })
        return head.hasPrefix("/") || head.hasPrefix("~") || head.hasPrefix("file://")
    }

    /// Repairs `text` into candidate paths and returns the first that exists,
    /// else the deepest existing ancestor of the most plausible candidate.
    /// Nil when nothing path-shaped is there.
    static func detect(_ text: String) -> PathTarget? {
        guard looksLikePath(text) else { return nil }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        body = stripQuotes(body)
        body = stripTrailingPunctuation(body)
        let (bare, line, column) = splitLineSuffix(body)
        guard !bare.isEmpty else { return nil }

        let candidates = repairCandidates(bare).map(expand)
        let fm = FileManager.default
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir) {
                return PathTarget(
                    url: URL(filePath: candidate), isDirectory: isDir.boolValue,
                    missing: nil, line: line, column: column
                )
            }
        }
        // Nothing exists as typed. Walk the joined candidate — the one a
        // wrapped terminal line most often is — up to something that does.
        let joined = candidates.count > 1 ? candidates[1] : candidates[0]
        guard let ancestor = deepestExistingAncestor(of: joined) else { return nil }
        return PathTarget(
            url: URL(filePath: ancestor), isDirectory: true,
            missing: joined, line: nil, column: nil
        )
    }

    /// Candidates in the order they are tried. `[1]` is always the
    /// newline-joined form, which `detect` relies on for the ancestor walk.
    static func repairCandidates(_ text: String) -> [String] {
        // Newline plus the indentation of the continuation line removed: the
        // terminal broke the word, nothing else changed.
        let joined = text.replacing(/[\r\n]+[ \t]*/, with: "")
        // Every whitespace run removed: for a paste that came through a
        // renderer that turned the newline into spaces.
        let squeezed = text.replacing(/\s+/, with: "")
        // Whitespace runs collapsed: a path with real spaces broken across
        // lines ("My Documents").
        let collapsed = text.replacing(/\s+/, with: " ")
        var seen = Set<String>()
        return [text, joined, squeezed, collapsed].filter { seen.insert($0).inserted }
    }

    /// Quotes and brackets prose wraps a path in: `("/x")`, `'/x'`, `</x>`.
    private static let leadingDecoration: Set<Character> = ["\"", "'", "`", "(", "[", "<", "{"]

    private static func stripQuotes(_ text: String) -> String {
        var out = Substring(text)
        // Leading decoration goes unconditionally; the matching closer is
        // handled by `stripTrailingPunctuation` whether or not it is there —
        // "'/Users/x' — …" cut in the middle is common.
        while let first = out.first, leadingDecoration.contains(first) { out = out.dropFirst() }
        return String(out)
    }

    private static func stripTrailingPunctuation(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, ",.;)]}>\"'`".contains(last) { out = out.dropLast() }
        return String(out)
    }

    /// `path:12:3` → (path, 12, 3). Only trailing all-digit segments are taken,
    /// so `foo:bar` stays a file name.
    static func splitLineSuffix(_ text: String) -> (path: String, line: Int?, column: Int?) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (text, nil, nil) }
        var numbers: [Int] = []
        var end = parts.count
        while end > 1, numbers.count < 2, let n = Int(parts[end - 1]) {
            numbers.insert(n, at: 0)
            end -= 1
        }
        guard !numbers.isEmpty else { return (text, nil, nil) }
        let path = parts[0..<end].joined(separator: ":")
        return (path, numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func expand(_ path: String) -> String {
        var out = path
        if out.hasPrefix("file://") {
            out = URL(string: out)?.path ?? String(out.dropFirst("file://".count))
        }
        return (out as NSString).expandingTildeInPath
    }

    /// The nearest existing ancestor, but never something so shallow it is
    /// useless: `/Users/x/Wrok/…` may fall back to the home directory, `/foo`
    /// must not fall back to `/`.
    static func deepestExistingAncestor(of path: String) -> String? {
        var current = URL(filePath: path).standardizedFileURL
        let fm = FileManager.default
        while current.pathComponents.count >= 3 {
            current = current.deletingLastPathComponent()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current.path, isDirectory: &isDir), isDir.boolValue {
                return current.pathComponents.count >= 3 ? current.path : nil
            }
        }
        return nil
    }

    /// The nearest enclosing git checkout — a worktree's `.git` is a file, so
    /// existence is what counts, not directory-ness.
    static func gitRoot(of url: URL) -> URL? {
        var current = url.standardizedFileURL
        let fm = FileManager.default
        while current.pathComponents.count > 1 {
            if fm.fileExists(atPath: current.appending(path: ".git").path) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Verbs

    /// Verbs the card offers for this target, in row order. The first is what
    /// bare ↵ runs.
    var verbs: [PathVerb] {
        if isDirectory {
            return [.open, .code, .terminal]
        }
        return [.open, .code, .reveal, .terminal]
    }
}

/// What can be done with a resolved path. Each is one `NSWorkspace` call —
/// no shelling out, so nothing depends on PATH.
enum PathVerb: String, CaseIterable {
    case open, code, reveal, terminal

    /// Chip label; the editor's own name so the row says "Cursor", not "code".
    @MainActor
    func title(for target: PathTarget) -> String {
        switch self {
        case .open: target.isDirectory ? "Finder" : "open"
        case .code:
            if let line = target.line { "\(CodeEditor.current?.name ?? "editor") :\(line)" }
            else { CodeEditor.current?.name ?? "editor" }
        case .reveal: "reveal"
        case .terminal: "Terminal"
        }
    }

    /// The modifier chord that runs this verb from the field regardless of
    /// the highlight. `open` has none: it is what bare ↵ does by default.
    var chord: String? {
        switch self {
        case .open: nil
        case .code: "⌘↵"
        case .reveal: "⌥↵"
        case .terminal: "⇧↵"
        }
    }

    static func forModifiers(_ flags: NSEvent.ModifierFlags) -> PathVerb? {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { return .code }
        if mods.contains(.option) { return .reveal }
        if mods.contains(.shift) { return .terminal }
        return nil
    }

    /// Runs the verb. Returns the line the palette shows back.
    @MainActor
    func run(_ target: PathTarget) -> SlashResult {
        let workspace = NSWorkspace.shared
        switch self {
        case .open:
            workspace.open(target.url)
            return .ok("opening \(target.name)")
        case .reveal:
            workspace.activateFileViewerSelecting([target.url])
            return .ok("revealing \(target.name)")
        case .terminal:
            let dir = target.directoryURL
            guard let app = TerminalApp.installed else {
                workspace.open(dir)
                return .ok("no terminal app found — opened \(dir.lastPathComponent) instead")
            }
            workspace.open([dir], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
            return .ok("\(app.name) at \(dir.lastPathComponent)")
        case .code:
            guard let editor = CodeEditor.current else {
                workspace.open(target.url)
                return .ok("no code editor installed — opened \(target.name) with its app")
            }
            editor.open(target)
            return .ok("\(editor.name): \(target.name)")
        }
    }
}

/// The code editors the `code` verb knows how to drive through their URL
/// scheme. Order is the autodetect order when `codeEditor` is unset.
struct CodeEditor: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    let scheme: String

    static let known: [CodeEditor] = [
        CodeEditor(id: "cursor", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", scheme: "cursor"),
        CodeEditor(id: "vscode", name: "VS Code", bundleID: "com.microsoft.VSCode", scheme: "vscode"),
        CodeEditor(id: "zed", name: "Zed", bundleID: "dev.zed.Zed", scheme: "zed"),
    ]

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var installed: [CodeEditor] { known.filter(\.isInstalled) }

    static func named(_ text: String) -> CodeEditor? {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased().replacing(" ", with: "")
        guard !needle.isEmpty else { return nil }
        return known.first {
            $0.id == needle || $0.name.lowercased().replacing(" ", with: "") == needle
        }
    }

    /// The configured editor when it is installed, else the first installed
    /// known one. A configured-but-missing editor is not an error — the box
    /// simply has a different one today.
    @MainActor
    static var current: CodeEditor? {
        if let id = StatusStore.shared.codeEditor, let chosen = known.first(where: { $0.id == id }),
           chosen.isInstalled {
            return chosen
        }
        return installed.first
    }

    /// Decision 3: a file opens inside its git checkout with the file in
    /// front. `<scheme>://file/<root>` opens (or focuses) the project window,
    /// then the file URL lands in that window — the editor routes a file URL
    /// to the window whose folder contains it. The second open is deferred
    /// so a window still being created does not lose it.
    func open(_ target: PathTarget) {
        let folder = target.isDirectory ? target.url : (PathTarget.gitRoot(of: target.url) ?? target.directoryURL)
        NSWorkspace.shared.open(fileURL(folder.path))
        guard !target.isDirectory else { return }
        var location = target.url.path
        if let line = target.line {
            location += ":\(line)"
            if let column = target.column { location += ":\(column)" }
        }
        let file = fileURL(location)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.open(file)
        }
    }

    private func fileURL(_ path: String) -> URL {
        // Percent-encode the path only; the `:line:col` tail is safe as-is.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(scheme)://file\(encoded)") ?? URL(filePath: path)
    }
}

/// Terminal for the `terminal` verb — the first installed, Warp preferred.
/// Each of these opens a folder dropped on it as a session in that folder.
struct TerminalApp {
    let name: String
    let url: URL

    static var installed: TerminalApp? {
        let candidates = [
            ("Warp", "dev.warp.Warp-Stable"),
            ("iTerm", "com.googlecode.iterm2"),
            ("Ghostty", "com.mitchellh.ghostty"),
            ("Terminal", "com.apple.Terminal"),
        ]
        for (name, bundleID) in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return TerminalApp(name: name, url: url)
            }
        }
        return nil
    }
}
