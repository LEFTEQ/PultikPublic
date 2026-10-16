//! The diff model, ported from Pultík's `DiffLine`, `DiffDocument` and `DiffLayout` (PR
//! workbench WP2): a unified patch as drawn lines with both gutter numbers, a change set's
//! files as rows (headers, lines, notes, gaps) and their wrap layout. Added for both apps: a
//! diff built from two texts ([`TextDiff::new`], an agent's change), the hunk model
//! ([`Hunk`]), each changed line's changed words ([`word_diff`]) and side-by-side rows
//! ([`SplitRow`]).
//!
//! Text is the line's own (no `+`/`-`/` ` marker, no line ending). Word ranges are bytes of
//! that text. Columns follow code-core's rule ([`width_at`]): tabs to stops of 4, wide chars
//! two, combining marks none.

use crate::lines::width_at;
use crate::syntax::Language;
use similar::{Algorithm, ChangeTag, DiffOp};
use std::collections::HashSet;
use std::ops::Range;

/// What a drawn diff line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LineKind {
    Hunk,
    Context,
    Added,
    Removed,
    Note,
}

/// One diff line as drawn: its gutter numbers (1-based) and its kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: LineKind,
    pub old: Option<u32>,
    pub new: Option<u32>,
    pub text: String,
}

/// A diff's two sides.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Side {
    Old,
    New,
}

impl DiffLine {
    /// A unified patch → drawn lines. A `@@ -a,b +c,d @@` header resets both counters;
    /// `\ No newline at end of file` is a note.
    pub fn parse(patch: &str) -> Vec<DiffLine> {
        let mut raws: Vec<&str> = patch.split('\n').collect();
        if raws.last() == Some(&"") {
            raws.pop(); // the patch's trailing newline
        }
        let (mut old, mut new) = (0, 0);
        let rest = |line: &str| line.chars().skip(1).collect::<String>();
        raws.into_iter()
            .map(|line| {
                if line.starts_with("@@") {
                    (old, new) = hunk_starts(line);
                    DiffLine {
                        kind: LineKind::Hunk,
                        old: None,
                        new: None,
                        text: line.to_owned(),
                    }
                } else if line.starts_with('+') {
                    new += 1;
                    DiffLine {
                        kind: LineKind::Added,
                        old: None,
                        new: Some(new - 1),
                        text: rest(line),
                    }
                } else if line.starts_with('-') {
                    old += 1;
                    DiffLine {
                        kind: LineKind::Removed,
                        old: Some(old - 1),
                        new: None,
                        text: rest(line),
                    }
                } else if line.starts_with('\\') {
                    DiffLine {
                        kind: LineKind::Note,
                        old: None,
                        new: None,
                        text: line.to_owned(),
                    }
                } else {
                    (old, new) = (old + 1, new + 1);
                    DiffLine {
                        kind: LineKind::Context,
                        old: Some(old - 1),
                        new: Some(new - 1),
                        text: rest(line),
                    }
                }
            })
            .collect()
    }

    /// The side this line draws from in an inline diff: removed lines are the old side's.
    pub fn side(&self) -> Side {
        match self.kind {
            LineKind::Removed => Side::Old,
            _ => Side::New,
        }
    }

    /// This line's 0-based line in `side`'s text, where it has one.
    pub fn source(&self, side: Side) -> Option<usize> {
        let n = match side {
            Side::Old => self.old,
            Side::New => self.new,
        };
        n.and_then(|n| (n as usize).checked_sub(1))
    }
}

/// The first number after `-` and after `+` in a hunk header.
fn hunk_starts(header: &str) -> (u32, u32) {
    let start = |marker: char| {
        header.find(marker).map_or(0, |at| {
            let digits: String = header[at + 1..]
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            digits.parse().unwrap_or(0)
        })
    };
    (start('-'), start('+'))
}

// ---- hunks --------------------------------------------------------------------------------

/// One hunk: its header's ranges, its section heading and where its lines are.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    /// The header's index in the line list.
    pub header: usize,
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    /// What follows the header's second `@@` (the enclosing function, as git guesses it).
    pub section: String,
    /// The hunk's lines after its header.
    pub lines: Range<usize>,
}

/// The hunks of a line list, from their headers.
pub fn hunks(lines: &[DiffLine]) -> Vec<Hunk> {
    let headers: Vec<usize> = (0..lines.len())
        .filter(|&i| lines[i].kind == LineKind::Hunk)
        .collect();
    headers
        .iter()
        .enumerate()
        .map(|(k, &at)| {
            let text = &lines[at].text;
            let range = |marker: char| {
                let Some(from) = text.find(marker) else {
                    return (0, 0);
                };
                let spec: String = text[from + 1..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == ',')
                    .collect();
                let mut parts = spec.split(',');
                let start = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
                let count = parts.next().map_or(1, |s| s.parse().unwrap_or(0));
                (start, count)
            };
            let ((old_start, old_lines), (new_start, new_lines)) = (range('-'), range('+'));
            let section = text
                .get(2..)
                .and_then(|rest| rest.find("@@").map(|i| rest[i + 2..].trim().to_owned()))
                .unwrap_or_default();
            let end = headers.get(k + 1).copied().unwrap_or(lines.len());
            Hunk {
                header: at,
                old_start,
                old_lines,
                new_start,
                new_lines,
                section,
                lines: at + 1..end,
            }
        })
        .collect()
}

// ---- from two texts -----------------------------------------------------------------------

/// `old` → `new` as unified lines, `context` lines around each change (git's default is 3),
/// line by line with the patience diff git's `--patience` uses.
pub fn diff_texts(old: &str, new: &str, context: usize) -> Vec<DiffLine> {
    let diff = similar::TextDiff::configure()
        .algorithm(Algorithm::Patience)
        .diff_lines(old, new);
    let mut lines = Vec::new();
    for group in diff.grouped_ops(context) {
        let (Some(first), Some(last)) = (group.first(), group.last()) else {
            continue;
        };
        let old_range = first.old_range().start..last.old_range().end;
        let new_range = first.new_range().start..last.new_range().end;
        lines.push(DiffLine {
            kind: LineKind::Hunk,
            old: None,
            new: None,
            text: format!(
                "@@ -{} +{} @@",
                unified_range(old_range),
                unified_range(new_range)
            ),
        });
        for op in &group {
            for change in diff.iter_changes(op) {
                let number = |i: Option<usize>| i.map(|i| i as u32 + 1);
                let (kind, old, new) = match change.tag() {
                    ChangeTag::Equal => (
                        LineKind::Context,
                        number(change.old_index()),
                        number(change.new_index()),
                    ),
                    ChangeTag::Delete => (LineKind::Removed, number(change.old_index()), None),
                    ChangeTag::Insert => (LineKind::Added, None, number(change.new_index())),
                };
                let value = change.value();
                lines.push(DiffLine {
                    kind,
                    old,
                    new,
                    text: value.strip_suffix('\n').unwrap_or(value).to_owned(),
                });
                if change.missing_newline() {
                    lines.push(DiffLine {
                        kind: LineKind::Note,
                        old: None,
                        new: None,
                        text: "\\ No newline at end of file".into(),
                    });
                }
            }
        }
    }
    lines
}

/// A hunk header's range as git writes it: `start,count`, the count left out when it is 1,
/// and the start the line before when it is 0.
fn unified_range(r: Range<usize>) -> String {
    match r.len() {
        1 => format!("{}", r.start + 1),
        0 => format!("{},0", r.start),
        n => format!("{},{n}", r.start + 1),
    }
}

// ---- word diffs ---------------------------------------------------------------------------

/// A changed line's words: the bytes of its old and of its new text that differ.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WordDiff {
    pub old: Vec<Range<usize>>,
    pub new: Vec<Range<usize>>,
}

/// The words that differ between a removed line and the added line it pairs with; `None`
/// when the two share too little to read as one line changed (draw them whole).
pub fn word_diff(old: &str, new: &str) -> Option<WordDiff> {
    let (a, b) = (tokens(old), tokens(new));
    let (sa, sb): (Vec<&str>, Vec<&str>) = (
        a.iter().map(|r| &old[r.clone()]).collect(),
        b.iter().map(|r| &new[r.clone()]).collect(),
    );
    let ops = similar::capture_diff_slices(Algorithm::Myers, &sa, &sb);
    let (mut gone, mut came, mut kept) = (Vec::new(), Vec::new(), 0);
    let span =
        |tokens: &[Range<usize>], r: Range<usize>| tokens[r.start].start..tokens[r.end - 1].end;
    let push = |out: &mut Vec<Range<usize>>, r: Range<usize>| match out.last_mut() {
        Some(last) if last.end == r.start => last.end = r.end,
        _ => out.push(r),
    };
    for op in ops {
        match op {
            DiffOp::Equal { old_index, len, .. } => {
                kept += a[old_index..old_index + len]
                    .iter()
                    .filter(|r| !old[(*r).clone()].trim().is_empty())
                    .map(|r| r.len())
                    .sum::<usize>();
            }
            _ => {
                let (ro, rn) = (op.old_range(), op.new_range());
                if !ro.is_empty() {
                    push(&mut gone, span(&a, ro));
                }
                if !rn.is_empty() {
                    push(&mut came, span(&b, rn));
                }
            }
        }
    }
    // Under half the longer line's text kept: it reads as rewritten, not edited.
    let longer = old.trim().len().max(new.trim().len());
    (kept * 2 >= longer).then_some(WordDiff {
        old: gone,
        new: came,
    })
}

/// A line's tokens: runs of letters, digits and `_`, runs of whitespace, any other char alone.
fn tokens(text: &str) -> Vec<Range<usize>> {
    #[derive(PartialEq, Clone, Copy)]
    enum Class {
        Word,
        Space,
        Other,
    }
    let class = |c: char| match c {
        c if c.is_alphanumeric() || c == '_' => Class::Word,
        c if c.is_whitespace() => Class::Space,
        _ => Class::Other,
    };
    let mut out: Vec<Range<usize>> = Vec::new();
    let mut last = None;
    for (at, c) in text.char_indices() {
        let k = class(c);
        match out.last_mut() {
            Some(r) if last == Some(k) && k != Class::Other => r.end = at + c.len_utf8(),
            _ => out.push(at..at + c.len_utf8()),
        }
        last = Some(k);
    }
    out
}

// ---- side by side -------------------------------------------------------------------------

/// One row of a side-by-side diff: a hunk header or a note across both sides, or a line on
/// each side (an index into the line list; `None` is a filler row).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitRow {
    Hunk(usize),
    Note(usize),
    Pair {
        old: Option<usize>,
        new: Option<usize>,
    },
}

/// The paired changes of a line list: in each run of removed lines and the added lines right
/// after it, the i-th removed line pairs with the i-th added one; the longer side's rest pair
/// with fillers. A note inside a run stays on its side.
fn runs(lines: &[DiffLine], mut each: impl FnMut(&[usize], &[usize])) -> Vec<SplitRow> {
    let mut rows = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        match lines[i].kind {
            LineKind::Hunk => rows.push(SplitRow::Hunk(i)),
            LineKind::Note => rows.push(SplitRow::Note(i)),
            LineKind::Context => rows.push(SplitRow::Pair {
                old: Some(i),
                new: Some(i),
            }),
            LineKind::Removed | LineKind::Added => {
                let take = |i: &mut usize, kind: LineKind| {
                    let mut side = Vec::new();
                    while *i < lines.len()
                        && (lines[*i].kind == kind
                            || (lines[*i].kind == LineKind::Note && !side.is_empty()))
                    {
                        side.push(*i);
                        *i += 1;
                    }
                    side
                };
                let old = take(&mut i, LineKind::Removed);
                let new = take(&mut i, LineKind::Added);
                let lines_only = |side: &[usize]| -> Vec<usize> {
                    side.iter()
                        .copied()
                        .filter(|&k| lines[k].kind != LineKind::Note)
                        .collect()
                };
                each(&lines_only(&old), &lines_only(&new));
                for k in 0..old.len().max(new.len()) {
                    rows.push(SplitRow::Pair {
                        old: old.get(k).copied(),
                        new: new.get(k).copied(),
                    });
                }
                continue;
            }
        }
        i += 1;
    }
    rows
}

/// A line list as side-by-side rows.
pub fn side_by_side(lines: &[DiffLine]) -> Vec<SplitRow> {
    runs(lines, |_, _| {})
}

/// Each line's changed words against the line it pairs with (see [`side_by_side`]); empty
/// where it pairs with none or reads as rewritten.
pub fn words(lines: &[DiffLine]) -> Vec<Vec<Range<usize>>> {
    let mut words = vec![Vec::new(); lines.len()];
    runs(lines, |old, new| {
        for (&o, &n) in old.iter().zip(new) {
            if let Some(w) = word_diff(&lines[o].text, &lines[n].text) {
                (words[o], words[n]) = (w.old, w.new);
            }
        }
    });
    words
}

/// A whole diff: unified lines, their hunks, each line's changed words and the side-by-side
/// rows. What an agent's change opens as, inline ([`TextDiff::lines`]) or side by side
/// ([`TextDiff::split`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextDiff {
    pub lines: Vec<DiffLine>,
    pub hunks: Vec<Hunk>,
    pub words: Vec<Vec<Range<usize>>>,
    pub split: Vec<SplitRow>,
}

impl TextDiff {
    /// `old` → `new` with `context` lines around each change.
    pub fn new(old: &str, new: &str, context: usize) -> Self {
        Self::from_lines(diff_texts(old, new, context))
    }

    /// A unified patch (a file's part of `git diff`, from its first `@@`).
    pub fn from_patch(patch: &str) -> Self {
        Self::from_lines(DiffLine::parse(patch))
    }

    fn from_lines(lines: Vec<DiffLine>) -> Self {
        Self {
            hunks: hunks(&lines),
            words: words(&lines),
            split: side_by_side(&lines),
            lines,
        }
    }
}

// ---- Pultík's change set as rows ----------------------------------------------------------

/// A changed file's status, as the host names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileStatus {
    Added,
    Removed,
    Modified,
    Renamed,
    Copied,
    Changed,
    Unchanged,
}

/// One file of a change set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFile {
    pub path: String,
    pub previous_path: Option<String>,
    pub status: FileStatus,
    pub additions: u32,
    pub deletions: u32,
    /// `None` for a binary file, one the source would not diff, or one past the patch
    /// budget (`trimmed`).
    pub patch: Option<String>,
    /// The patch was cut at its source's line limit or dropped past its byte budget.
    pub trimmed: bool,
    /// Each side's blob, where the source names them: highlighting parses the whole file.
    pub old_blob: Option<String>,
    pub new_blob: Option<String>,
}

/// A file of a [`DiffDocument`]: its lines, and each line's place in its side's patch-only
/// text ([`DiffFile::side_text`]), the highlight source when no blob is named.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffFile {
    pub changed: ChangedFile,
    pub lines: Vec<DiffLine>,
    pub language: Option<Language>,
    pub collapsed: bool,
    pub old_fragment: Vec<Option<u32>>,
    pub new_fragment: Vec<Option<u32>>,
}

impl DiffFile {
    pub fn path(&self) -> &str {
        &self.changed.path
    }

    /// Where `lines[index]` sits in `side`'s highlight source: its line in the blob when
    /// there is one, else in the patch-only text.
    pub fn source_line(&self, index: usize, side: Side) -> Option<u32> {
        let line = &self.lines[index];
        match side {
            Side::New if self.changed.new_blob.is_some() => line.new.map(|n| n - 1),
            Side::New => self.new_fragment[index],
            Side::Old if self.changed.old_blob.is_some() => line.old.map(|n| n - 1),
            Side::Old => self.old_fragment[index],
        }
    }

    /// One side's text as the patch alone holds it: context and that side's lines, in order.
    pub fn side_text(&self, side: Side) -> String {
        self.lines
            .iter()
            .filter(|l| match l.kind {
                LineKind::Context => true,
                LineKind::Added => side == Side::New,
                LineKind::Removed => side == Side::Old,
                LineKind::Hunk | LineKind::Note => false,
            })
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// Why a file shows a note row; the app words it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileNote {
    /// No patch: past the patch budget (open it on the host).
    PastBudget,
    /// No patch: binary, renamed or empty.
    NoDiff,
    /// Folded: this many lines, generated or long.
    Folded { lines: usize, generated: bool },
    /// The patch was cut here (the rest is on the host).
    CutHere,
    /// The host listed only the first `files` files.
    HostListsFirst { files: usize },
}

/// One row of the Files changed view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocRow {
    Header {
        file: usize,
    },
    Line {
        file: usize,
        index: usize,
    },
    Note {
        file: usize,
        note: FileNote,
    },
    /// The space between two files.
    Gap,
}

/// A change set as rows: each file's header, then — unless it is folded — its hunks and
/// lines, or why it has none. Built once per change set and fold state; a view lays it out
/// per width and draws only the rows on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffDocument {
    pub files: Vec<DiffFile>,
    pub rows: Vec<DocRow>,
    /// Each row's drawn width in columns: the wrap model's input.
    pub columns: Vec<u32>,
    /// The gutter's figure width, shared by every file so the code column lines up.
    pub digits: u32,
}

impl DiffDocument {
    /// A lockfile or generated file, or one past this many lines, starts folded.
    pub const COLLAPSE_LINES: usize = 1_500;

    /// `files` as rows; `truncated` when the host stopped listing before the last file;
    /// `toggled` the paths whose fold the reader flipped.
    pub fn new(files: Vec<ChangedFile>, truncated: bool, toggled: &HashSet<String>) -> Self {
        let (mut out, mut rows, mut columns, mut widest) = (Vec::new(), Vec::new(), Vec::new(), 0);
        for changed in files {
            let lines = changed
                .patch
                .as_deref()
                .map(DiffLine::parse)
                .unwrap_or_default();
            let index = out.len();
            let folded = Self::collapsed_by_default(&changed, lines.len())
                != toggled.contains(&changed.path);
            let (mut old_fragment, mut new_fragment) = (Vec::new(), Vec::new());
            let (mut old, mut new) = (0, 0);
            for line in &lines {
                let (o, n) = match line.kind {
                    LineKind::Context => (Some(old), Some(new)),
                    LineKind::Added => (None, Some(new)),
                    LineKind::Removed => (Some(old), None),
                    LineKind::Hunk | LineKind::Note => (None, None),
                };
                old += u32::from(o.is_some());
                new += u32::from(n.is_some());
                old_fragment.push(o);
                new_fragment.push(n);
                widest = widest.max(line.old.unwrap_or(0)).max(line.new.unwrap_or(0));
            }
            if index > 0 {
                rows.push(DocRow::Gap);
                columns.push(0);
            }
            rows.push(DocRow::Header { file: index });
            columns.push(0);
            let note = |note| DocRow::Note { file: index, note };
            if lines.is_empty() {
                rows.push(note(match changed.trimmed {
                    true => FileNote::PastBudget,
                    false => FileNote::NoDiff,
                }));
                columns.push(0);
            } else if folded {
                rows.push(note(FileNote::Folded {
                    lines: lines.len(),
                    generated: is_generated(&changed.path),
                }));
                columns.push(0);
            } else {
                for (k, line) in lines.iter().enumerate() {
                    rows.push(DocRow::Line {
                        file: index,
                        index: k,
                    });
                    columns.push(self::columns(&line.text));
                }
                if changed.trimmed {
                    rows.push(note(FileNote::CutHere));
                    columns.push(0);
                }
            }
            out.push(DiffFile {
                language: Language::from_path(&changed.path),
                changed,
                lines,
                collapsed: folded,
                old_fragment,
                new_fragment,
            });
        }
        if truncated {
            rows.push(DocRow::Note {
                file: out.len().saturating_sub(1),
                note: FileNote::HostListsFirst { files: out.len() },
            });
            columns.push(0);
        }
        Self {
            files: out,
            rows,
            columns,
            digits: (widest.to_string().len() as u32).max(3),
        }
    }

    pub fn collapsed_by_default(file: &ChangedFile, lines: usize) -> bool {
        is_generated(&file.path) || lines > Self::COLLAPSE_LINES
    }

    /// The first row of each file, by file index: what ⇥ and the tree jump to.
    pub fn header_rows(&self) -> Vec<usize> {
        (0..self.rows.len())
            .filter(|&i| matches!(self.rows[i], DocRow::Header { .. }))
            .collect()
    }
}

/// `text`'s width in columns (code-core's rule: tabs to stops of 4, wide chars two).
pub fn columns(text: &str) -> u32 {
    text.chars().fold(0, |col, c| col + width_at(c, col))
}

/// `text` with its tabs expanded to their stops, and each original UTF-16 offset's place in it
/// (one past the end included), so runs, selection and hit-testing map between the two.
pub fn expand_tabs(text: &str) -> (String, Vec<usize>) {
    let mut out = String::with_capacity(text.len());
    let mut map = Vec::with_capacity(text.len() + 1);
    let (mut col, mut units) = (0, 0);
    for c in text.chars() {
        let width = width_at(c, col);
        for k in 0..c.len_utf16() {
            map.push(units + k);
        }
        if c == '\t' {
            out.extend(std::iter::repeat_n(' ', width as usize));
            units += width as usize;
        } else {
            out.push(c);
            units += c.len_utf16();
        }
        col += width;
    }
    map.push(units);
    (out, map)
}

/// Where each visual row after the first starts in a wrapped line's drawn text (tabs already
/// expanded), in bytes: the drawing half of [`DiffLayout`]'s rule. A char sits on the row its
/// first column falls in, so a wide char at a row's last column runs one column past it, and a
/// zero-width char stays with the char before it. A line never draws more rows than the
/// layout counts for it (`columns(text).div_ceil(cols)`).
pub fn row_starts(text: &str, cols: u32) -> Vec<usize> {
    let cols = cols.max(1);
    let (mut starts, mut col, mut row) = (Vec::new(), 0, 0);
    for (at, c) in text.char_indices() {
        let width = width_at(c, col);
        while width > 0 && row < col / cols {
            row += 1;
            starts.push(at);
        }
        col += width;
    }
    starts
}

/// Files whose diff nobody reads line by line start folded: lockfiles and generated files.
pub fn is_generated(path: &str) -> bool {
    const NAMES: &[&str] = &[
        "package-lock.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        "bun.lock",
        "bun.lockb",
        "cargo.lock",
        "go.sum",
        "composer.lock",
        "gemfile.lock",
        "poetry.lock",
        "podfile.lock",
        "package.resolved",
        "flake.lock",
    ];
    const SUFFIXES: &[&str] = &[
        ".min.js",
        ".min.css",
        ".snap",
        ".pb.go",
        "_generated.go",
        ".generated.ts",
        ".g.dart",
        ".map",
    ];
    let name = path.rsplit('/').next().unwrap_or(path).to_lowercase();
    NAMES.contains(&name.as_str()) || SUFFIXES.iter().any(|s| name.ends_with(s))
}

// ---- layout at one width ------------------------------------------------------------------

/// Row heights and the code column's place, in points (Pultík's canvas).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metrics {
    pub line_height: f64,
    pub header_height: f64,
    pub gap_height: f64,
    pub note_height: f64,
    pub advance: f64,
    /// The code column's left edge: the gutter and the ± marker.
    pub code_x: f64,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            line_height: 18.0,
            header_height: 30.0,
            gap_height: 12.0,
            note_height: 24.0,
            advance: 7.2,
            code_x: 0.0,
        }
    }
}

/// A document laid out at one width (PR workbench D9): each row's height (a wrapped line is
/// several visual rows) and the running offsets a binary search finds the rows on screen with.
#[derive(Debug, Clone, PartialEq)]
pub struct DiffLayout {
    pub metrics: Metrics,
    /// Columns per visual row; `None` = no wrapping.
    pub wrap_columns: Option<u32>,
    /// Visual rows per row (1 for headers, notes and gaps).
    pub visual_rows: Vec<u32>,
    /// `offsets[i]` is row i's top; the last is the height.
    pub offsets: Vec<f64>,
}

impl DiffLayout {
    pub fn new(document: &DiffDocument, width: f64, wraps: bool, metrics: Metrics) -> Self {
        let available = ((width - metrics.code_x - 12.0) / metrics.advance).floor();
        let wrap_columns = wraps.then(|| (available.max(0.0) as u32).max(20));
        let mut visual_rows = Vec::with_capacity(document.rows.len());
        let mut offsets = Vec::with_capacity(document.rows.len() + 1);
        let mut y = 0.0;
        offsets.push(y);
        for (i, row) in document.rows.iter().enumerate() {
            let (count, height) = match row {
                DocRow::Header { .. } => (1, metrics.header_height),
                DocRow::Gap => (1, metrics.gap_height),
                DocRow::Note { .. } => (1, metrics.note_height),
                DocRow::Line { .. } => {
                    let count = wrap_columns.map_or(1, |w| document.columns[i].div_ceil(w).max(1));
                    (count, f64::from(count) * metrics.line_height)
                }
            };
            visual_rows.push(count);
            y += height;
            offsets.push(y);
        }
        Self {
            metrics,
            wrap_columns,
            visual_rows,
            offsets,
        }
    }

    pub fn height(&self) -> f64 {
        self.offsets.last().copied().unwrap_or(0.0)
    }

    /// Row `row`'s top and height.
    pub fn frame(&self, row: usize) -> (f64, f64) {
        (self.offsets[row], self.offsets[row + 1] - self.offsets[row])
    }

    /// The row whose span holds `y` (clamped to the document).
    pub fn row_at(&self, y: f64) -> usize {
        let count = self.offsets.len() - 1;
        if count == 0 {
            return 0;
        }
        self.offsets[..count]
            .partition_point(|&top| top <= y)
            .saturating_sub(1)
    }

    /// The rows intersecting `min_y..max_y`.
    pub fn rows(&self, min_y: f64, max_y: f64) -> Range<usize> {
        let count = self.offsets.len() - 1;
        if count == 0 {
            return 0..0;
        }
        self.row_at(min_y.max(0.0))..count.min(self.row_at(max_y) + 1)
    }
}
