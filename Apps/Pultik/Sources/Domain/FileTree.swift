import Foundation

/// The Files changed tab's tree (PR workbench WP4, D6): folders, then files,
/// each level alphabetical; a folder whose only child is a folder folds into
/// one row (`Sources/Views/Modules`); a file carries its status letter; a
/// filter keeps every match and the folders above it. Foundation-only.
struct FileTree: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        /// A file's path, or a folder's `path/`.
        let id: String
        /// `Modules/PRs` for a compressed folder, the file's name otherwise.
        let name: String
        let depth: Int
        let isFolder: Bool
        /// A file's `A`, `M`, `D`, `R` or `C`; nil for a folder.
        let letter: String?
        let additions: Int
        let deletions: Int

        /// The file's path (a folder's without its slash).
        var path: String { isFolder ? String(id.dropLast()) : id }
    }

    let rows: [Row]

    /// `folded` holds folder paths (no trailing slash) shown shut.
    init(_ files: [ChangedFile], filter: String = "", folded: Set<String> = []) {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = needle.isEmpty ? files : files.filter { $0.path.lowercased().contains(needle) }
        let root = Folder(name: "")
        for file in kept {
            var folder = root
            let parts = file.path.split(separator: "/").map(String.init)
            for part in parts.dropLast() { folder = folder.child(part) }
            folder.files.append(file)
        }
        var rows: [Row] = []
        // A filter opens every folder it keeps: the match is the point.
        Self.flatten(root, prefix: "", depth: 0, folded: needle.isEmpty ? folded : [], into: &rows)
        self.rows = rows
    }

    static func letter(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: "A"
        case .removed: "D"
        case .renamed: "R"
        case .copied: "C"
        case .modified, .changed, .unchanged: "M"
        }
    }

    private final class Folder {
        let name: String
        var folders: [String: Folder] = [:]
        var files: [ChangedFile] = []

        init(name: String) {
            self.name = name
        }

        func child(_ name: String) -> Folder {
            if let existing = folders[name] { return existing }
            let folder = Folder(name: name)
            folders[name] = folder
            return folder
        }

        var additions: Int { files.reduce(0) { $0 + $1.additions } + folders.values.reduce(0) { $0 + $1.additions } }
        var deletions: Int { files.reduce(0) { $0 + $1.deletions } + folders.values.reduce(0) { $0 + $1.deletions } }
    }

    private static func flatten(_ folder: Folder, prefix: String, depth: Int, folded: Set<String>, into rows: inout [Row]) {
        for name in folder.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var node = folder.folders[name]!
            var label = name
            // A chain of single folders is one row.
            while node.files.isEmpty, node.folders.count == 1, let only = node.folders.values.first {
                label += "/" + only.name
                node = only
            }
            let path = prefix + label
            rows.append(Row(id: path + "/", name: label, depth: depth, isFolder: true, letter: nil,
                            additions: node.additions, deletions: node.deletions))
            if !folded.contains(path) {
                flatten(node, prefix: path + "/", depth: depth + 1, folded: folded, into: &rows)
            }
        }
        for file in folder.files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            rows.append(Row(id: file.path, name: (file.path as NSString).lastPathComponent, depth: depth, isFolder: false,
                            letter: letter(file.status), additions: file.additions, deletions: file.deletions))
        }
    }
}
