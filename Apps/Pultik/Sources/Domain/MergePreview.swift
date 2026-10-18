import Foundation

/// One file both sides of a merge changed (vt-7968): its text at the merge base, on each side
/// and, for a past merge, as the merge commit committed it. What the merge canvas draws; an
/// empty text is a side that has no such file.
struct MergeFile: Equatable, Sendable, Identifiable {
    let path: String
    let base: String
    let ours: String
    let theirs: String
    /// A past merge's own text; nil for a preview.
    let committed: String?

    var id: String { path }
}

/// A merge to draw (`docs/specs/2026-10-18-merge-view-decisions.md` M1): ours — the base
/// branch's tip, or a merge commit's first parent — and theirs — the head, or its second
/// parent — over their merge base, with every file both changed. Nothing is merged here: the
/// Rust engine merges each file as the canvas opens it.
struct MergePreview: Equatable, Sendable {
    let ours: String
    let theirs: String
    let base: String
    /// The merge commit, for a past merge.
    let commit: String?
    let files: [MergeFile]
    /// Files both sides changed that are binary or too large to draw: listed, not drawn.
    let skipped: [String]
}
