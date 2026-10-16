//! `GitHubPRDetailTests.swift`'s diff lines and `SyntaxEngineTests.swift`'s wrap by columns
//! (PR workbench WP2), then the Rust core's own: hunks, diffs from two texts, word diffs,
//! side-by-side rows, and an agent's change as both (workbench AC4).

use code_core::diff::{
    self, ChangedFile, DiffDocument, DiffLayout, DiffLine, DocRow, FileNote, FileStatus, LineKind,
    Metrics, Side, SplitRow, TextDiff,
};
use std::collections::HashSet;

#[test]
fn diff_lines_carry_both_gutter_numbers_across_hunks() {
    let patch = "@@ -10,3 +10,3 @@ func pool()\n context\n-old\n+new\n \n\\ No newline at end of file\n@@ -40,1 +40,2 @@\n x\n+y\n";
    let lines = DiffLine::parse(patch);
    use LineKind::*;
    assert_eq!(
        lines.iter().map(|l| l.kind).collect::<Vec<_>>(),
        [
            Hunk, Context, Removed, Added, Context, Note, Hunk, Context, Added
        ]
    );
    assert_eq!(lines[1].old, Some(10));
    assert_eq!(lines[2].old, Some(11));
    assert_eq!(lines[2].new, None);
    assert_eq!(lines[3].new, Some(11));
    assert_eq!(
        [lines[4].old, lines[4].new],
        [Some(12), Some(12)],
        "a blank context line is a line"
    );
    assert_eq!(lines[8].new, Some(41));
}

fn changed(path: &str, patch: Option<&str>) -> ChangedFile {
    ChangedFile {
        path: path.into(),
        previous_path: None,
        status: FileStatus::Modified,
        additions: 1,
        deletions: 0,
        patch: patch.map(Into::into),
        trimmed: false,
        old_blob: None,
        new_blob: None,
    }
}

/// Wrapping is computed from columns: a tab runs to the next stop, and a wrapped line takes
/// as many rows as its columns need.
#[test]
fn the_document_wraps_by_columns() {
    assert_eq!(diff::columns("\tab"), 6);
    assert_eq!(diff::expand_tabs("a\tb").0, "a   b");
    let long = "x".repeat(250);
    let patch = format!("@@ -1 +1,2 @@\n ctx\n+{long}");
    let document = DiffDocument::new(vec![changed("a.ts", Some(&patch))], false, &HashSet::new());
    let metrics = Metrics {
        advance: 10.0,
        code_x: 0.0,
        ..Metrics::default()
    };
    let wrapped = DiffLayout::new(&document, 1012.0, true, metrics);
    assert_eq!(wrapped.wrap_columns, Some(100));
    assert_eq!(
        wrapped.visual_rows.last(),
        Some(&3),
        "250 columns at 100 per row"
    );
    let unwrapped = DiffLayout::new(&document, 1012.0, false, metrics);
    assert_eq!(unwrapped.visual_rows.last(), Some(&1));
    assert_eq!(wrapped.row_at(-5.0), 0);
    assert_eq!(wrapped.rows(0.0, wrapped.height()), 0..document.rows.len());
}

/// A wrapped line draws on the rows its columns are laid out on: wide chars count two, a wide
/// char at a row's last column stays on that row, a combining mark stays with its char, and a
/// line never draws more rows than the layout gives it.
#[test]
fn a_wrapped_line_draws_on_the_rows_its_columns_take() {
    assert_eq!(diff::row_starts(&"x".repeat(250), 100), [100, 200]);
    let cjk = "漢".repeat(60);
    assert_eq!(diff::columns(&cjk), 120);
    assert_eq!(diff::row_starts(&cjk, 100), [50 * 3]);
    let straddle = format!("{}漢{}", "x".repeat(99), "x".repeat(100));
    assert_eq!(diff::row_starts(&straddle, 100), [102, 201]);
    let mark = format!("{}e\u{301}x", "x".repeat(99));
    assert_eq!(diff::row_starts(&mark, 100), [102]);
    for text in [cjk.as_str(), &straddle, &mark, "", "abc"] {
        let drawn = diff::row_starts(text, 100).len() + 1;
        assert!(
            drawn as u32 <= diff::columns(text).div_ceil(100).max(1),
            "{text}"
        );
    }
}

/// Rows: a header per file, a gap between files, a fold note for a lockfile (unless toggled),
/// a note for a file without a patch, and the host's truncation last. Each side's patch-only
/// text feeds highlighting when no blob is named.
#[test]
fn a_change_set_reads_as_rows_with_notes_and_folds() {
    let files = vec![
        changed(
            "src/a.rs",
            Some("@@ -1,2 +1,2 @@\n fn a() {}\n-let x = 1;\n+let x = 2;"),
        ),
        changed("Cargo.lock", Some("@@ -1 +1 @@\n-a\n+b")),
        changed("logo.png", None),
    ];
    let document = DiffDocument::new(files.clone(), true, &HashSet::new());
    assert_eq!(
        document.rows,
        [
            DocRow::Header { file: 0 },
            DocRow::Line { file: 0, index: 0 },
            DocRow::Line { file: 0, index: 1 },
            DocRow::Line { file: 0, index: 2 },
            DocRow::Line { file: 0, index: 3 },
            DocRow::Gap,
            DocRow::Header { file: 1 },
            DocRow::Note {
                file: 1,
                note: FileNote::Folded {
                    lines: 3,
                    generated: true
                }
            },
            DocRow::Gap,
            DocRow::Header { file: 2 },
            DocRow::Note {
                file: 2,
                note: FileNote::NoDiff
            },
            DocRow::Note {
                file: 2,
                note: FileNote::HostListsFirst { files: 3 }
            },
        ]
    );
    assert_eq!(document.header_rows(), [0, 6, 9]);
    assert_eq!(document.digits, 3);
    let toggled = HashSet::from(["Cargo.lock".to_owned()]);
    let unfolded = DiffDocument::new(files, false, &toggled);
    assert!(!unfolded.files[1].collapsed);
    let a = &document.files[0];
    assert_eq!(a.side_text(Side::Old), "fn a() {}\nlet x = 1;");
    assert_eq!(a.side_text(Side::New), "fn a() {}\nlet x = 2;");
    assert_eq!(a.source_line(2, Side::Old), Some(1));
    assert_eq!(a.source_line(3, Side::New), Some(1));
    assert_eq!(a.source_line(3, Side::Old), None);
}

#[test]
fn hunks_read_their_headers() {
    let lines =
        DiffLine::parse("@@ -10,3 +10,4 @@ fn pool()\n a\n+b\n c\n d\n@@ -40 +41,0 @@\n-x\n");
    let hunks = diff::hunks(&lines);
    assert_eq!(hunks.len(), 2);
    let h = &hunks[0];
    assert_eq!(
        (
            h.old_start,
            h.old_lines,
            h.new_start,
            h.new_lines,
            h.section.as_str(),
            h.lines.clone()
        ),
        (10, 3, 10, 4, "fn pool()", 1..5)
    );
    let h = &hunks[1];
    assert_eq!(
        (
            h.old_start,
            h.old_lines,
            h.new_start,
            h.new_lines,
            h.section.as_str(),
            h.lines.clone()
        ),
        (40, 1, 41, 0, "", 6..7)
    );
}

/// From two texts: git's unified hunks (context 3, counts left out when 1), and the
/// missing final newline as a note.
#[test]
fn two_texts_diff_as_git_writes_them() {
    let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n";
    let new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk";
    let unified: Vec<String> = diff::diff_texts(old, new, 3)
        .iter()
        .map(|l| match l.kind {
            LineKind::Hunk | LineKind::Note => l.text.clone(),
            LineKind::Context => format!(" {}", l.text),
            LineKind::Added => format!("+{}", l.text),
            LineKind::Removed => format!("-{}", l.text),
        })
        .collect();
    assert_eq!(
        unified,
        [
            "@@ -2,9 +2,10 @@",
            " b",
            " c",
            " d",
            "-e",
            "+E",
            " f",
            " g",
            " h",
            " i",
            " j",
            "+k",
            "\\ No newline at end of file"
        ]
    );
    assert_eq!(diff::diff_texts("x\n", "x\n", 3), []);
}

#[test]
fn word_diffs_mark_changed_tokens_or_nothing_when_rewritten() {
    let (old, new) = ("let total = count + 1;", "let total = count * 2;");
    let words = diff::word_diff(old, new).expect("an edited line");
    let (gone, came) = (words.old, words.new);
    assert_eq!(
        gone.iter().map(|r| &old[r.clone()]).collect::<Vec<_>>(),
        ["+", "1"]
    );
    assert_eq!(
        came.iter().map(|r| &new[r.clone()]).collect::<Vec<_>>(),
        ["*", "2"]
    );
    assert_eq!(diff::word_diff("fn alpha() {}", "struct Beta;"), None);
}

/// An agent's change (the Edit tool's old_string → new_string on a file) opens as an inline
/// diff and a side-by-side diff (workbench AC4): exact rows on both, words on the paired line.
#[test]
fn an_agents_edit_opens_inline_and_side_by_side() {
    let file = "fn total(items: &[u32]) -> u32 {\n    let mut sum = 0;\n    for i in items {\n        sum += i;\n    }\n    sum\n}\n\nfn main() {\n    println!(\"{}\", total(&[1, 2]));\n}\n";
    let (old_string, new_string) = (
        "    let mut sum = 0;\n    for i in items {\n        sum += i;\n    }\n    sum\n",
        "    items.iter().sum()\n",
    );
    let edited = file.replacen(old_string, new_string, 1);
    let diff = TextDiff::new(file, &edited, 3);

    let inline: Vec<(LineKind, Option<u32>, Option<u32>, &str)> = diff
        .lines
        .iter()
        .map(|l| (l.kind, l.old, l.new, l.text.as_str()))
        .collect();
    use LineKind::*;
    assert_eq!(
        inline,
        [
            (Hunk, None, None, "@@ -1,9 +1,5 @@"),
            (
                Context,
                Some(1),
                Some(1),
                "fn total(items: &[u32]) -> u32 {"
            ),
            (Removed, Some(2), None, "    let mut sum = 0;"),
            (Removed, Some(3), None, "    for i in items {"),
            (Removed, Some(4), None, "        sum += i;"),
            (Removed, Some(5), None, "    }"),
            (Removed, Some(6), None, "    sum"),
            (Added, None, Some(2), "    items.iter().sum()"),
            (Context, Some(7), Some(3), "}"),
            (Context, Some(8), Some(4), ""),
            (Context, Some(9), Some(5), "fn main() {"),
        ]
    );
    assert_eq!(diff.hunks.len(), 1);
    let pair = |old, new| SplitRow::Pair { old, new };
    assert_eq!(
        diff.split,
        [
            SplitRow::Hunk(0),
            pair(Some(1), Some(1)),
            pair(Some(2), Some(7)),
            pair(Some(3), None),
            pair(Some(4), None),
            pair(Some(5), None),
            pair(Some(6), None),
            pair(Some(8), Some(8)),
            pair(Some(9), Some(9)),
            pair(Some(10), Some(10)),
        ]
    );
    assert!(
        diff.words[2].is_empty() && diff.words[7].is_empty(),
        "a rewritten line is drawn whole"
    );

    // A one-word change pairs its two lines and marks the word on both sides.
    let renamed = file.replacen("println!(\"{}\", total", "println!(\"{}\", grand_total", 1);
    let diff = TextDiff::new(file, &renamed, 1);
    let split_lines: Vec<_> = diff
        .split
        .iter()
        .filter_map(|r| match r {
            SplitRow::Pair {
                old: Some(o),
                new: Some(n),
            } if o != n => Some((*o, *n)),
            _ => None,
        })
        .collect();
    assert_eq!(
        split_lines.len(),
        1,
        "the changed line pairs with its new self"
    );
    let (o, n) = split_lines[0];
    let word = |i: usize| -> Vec<&str> {
        diff.words[i]
            .iter()
            .map(|r| &diff.lines[i].text[r.clone()])
            .collect()
    };
    assert_eq!((word(o), word(n)), (vec!["total"], vec!["grand_total"]));
}
