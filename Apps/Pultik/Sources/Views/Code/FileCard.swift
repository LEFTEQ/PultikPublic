import CodeThemes
import SwiftUI

/// A file at a commit (code navigation, PR workbench D2): `repo@sha:path#line`,
/// the id its card carries on the detail stack.
struct CodeFileRef: Hashable {
    let repo: String
    let sha: String
    let path: String
    /// 1-based; nil = the top.
    let line: Int?

    init(repo: String, sha: String, path: String, line: Int?) {
        self.repo = repo
        self.sha = sha
        self.path = path
        self.line = line
    }

    init?(_ id: String) {
        guard let at = id.firstIndex(of: "@"), let colon = id[at...].firstIndex(of: ":") else { return nil }
        repo = String(id[..<at])
        sha = String(id[id.index(after: at) ..< colon])
        var rest = String(id[id.index(after: colon)...])
        if let hash = rest.lastIndex(of: "#"), let number = Int(rest[rest.index(after: hash)...]) {
            line = number
            rest = String(rest[..<hash])
        } else {
            line = nil
        }
        path = rest
    }

    var id: String { "\(repo)@\(sha):\(path)" + (line.map { "#\($0)" } ?? "") }
}

/// A file card over the PR (stay in Pultík D2): the file at the PR's head on
/// the code canvas, highlighted, scrolled to the line navigation landed on.
/// Esc slides it away; ⌘↵ opens the file on the host.
struct FileCard: View {
    let store: StatusStore
    let file: CodeFileRef
    @State private var document: DiffDocument?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Theme.ink3)
                Text(file.path).font(Theme.Typo.figure).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.head)
                if let line = file.line { Text("L\(line)").font(Theme.Typo.figure).foregroundStyle(Theme.ink3) }
                Text(String(file.sha.prefix(7))).font(Theme.Typo.figure).foregroundStyle(Theme.ink3)
                Spacer(minLength: 6)
                KbdHint("esc")
                Text("back").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
                KbdHint("⌘↵")
                Text("open").font(Theme.Typo.meta).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            // Panel ink on the panel, as the Files tab's status line: a light
            // code theme behind it would swallow it.
            .background(Theme.canvas)
            if let document {
                CodeCanvas(document: document, documentID: file.id, wraps: CodePreferences.shared.wraps, active: true,
                           focusedFile: nil, scrollRequest: nil,
                           blob: { [store, repo = file.repo] sha in try await store.blobText(repo: repo, sha: sha) },
                           reveal: (0, file.line, 1))
            } else if let failure {
                Text(verbatim: "Not loaded — \(failure)").font(Theme.Typo.meta).foregroundStyle(Theme.ink2).padding(14)
            } else {
                SkeletonBars(widths: [0.6, 0.4, 0.7]).padding(14)
            }
            Spacer(minLength: 0)
        }
        .background(CodePreferences.shared.themes.theme[.background].color)
        .task(id: file.id) {
            do {
                let text = try await store.fileText(repo: file.repo, sha: file.sha, path: file.path)
                document = await Task.detached(priority: .userInitiated) { Self.document(text, path: file.path) }.value
            } catch is CancellationError {
            } catch {
                NSLog("pultik: file card %@ failed: %@", file.id, error.localizedDescription)
                failure = error.localizedDescription
            }
        }
    }

    /// The whole file as one hunk of context lines, never folded.
    static func document(_ text: String, path: String) -> DiffDocument {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let patch = "@@ -1,\(lines.count) +1,\(lines.count) @@\n" + lines.map { " " + $0 }.joined(separator: "\n")
        let file = ChangedFile(path: path, previousPath: nil, status: .unchanged, additions: 0, deletions: 0,
                               patch: patch, trimmed: false)
        let folded = DiffDocument.collapsedByDefault(file, lines: lines.count + 1)
        return DiffDocument(ChangeSet(files: [file], truncated: false), collapsed: folded ? [path] : [])
    }
}
