//! The diff model: `code_core::diff`, Pultík's `DiffLine`, `DiffDocument` and `DiffLayout`,
//! plus the text diff (hunks, word diffs, side-by-side rows) and the column rule. Notes are
//! data (`CODE_CORE_NOTE_*`): the app words them.

use crate::search::CodeCoreRange;
use crate::syntax::code;
use crate::{
    CODE_CORE_NONE, CodeCoreNumbers, CodeCoreStatus, CodeCoreStr, Failure, call, numbers_result,
    owned, put, slice, utf16,
};
use code_core::TAB;
use code_core::diff::{
    self, ChangedFile, DiffDocument, DiffLayout, DiffLine, DocRow, FileNote, FileStatus, LineKind,
    Metrics, SplitRow, TextDiff,
};
use std::collections::HashSet;
use std::ffi::c_char;

/// A tab runs to the next multiple of this many columns.
pub const CODE_CORE_TAB_WIDTH: u32 = 4;
/// A file whose patch has more lines than this starts folded (as a generated file does).
pub const CODE_CORE_COLLAPSE_LINES: u32 = 1500;
// Literals, so the header carries numbers; held to the core's own here.
const _: () = assert!(CODE_CORE_TAB_WIDTH == TAB);
const _: () = assert!(CODE_CORE_COLLAPSE_LINES as usize == DiffDocument::COLLAPSE_LINES);

pub const CODE_CORE_LINE_HUNK: u8 = 0;
pub const CODE_CORE_LINE_CONTEXT: u8 = 1;
pub const CODE_CORE_LINE_ADDED: u8 = 2;
pub const CODE_CORE_LINE_REMOVED: u8 = 3;
pub const CODE_CORE_LINE_NOTE: u8 = 4;

pub const CODE_CORE_ROW_HEADER: u8 = 0;
pub const CODE_CORE_ROW_LINE: u8 = 1;
pub const CODE_CORE_ROW_NOTE: u8 = 2;
pub const CODE_CORE_ROW_GAP: u8 = 3;

/// No patch: past the patch budget.
pub const CODE_CORE_NOTE_PAST_BUDGET: u8 = 0;
/// No patch: binary, renamed or empty.
pub const CODE_CORE_NOTE_NO_DIFF: u8 = 1;
/// Folded: `count` lines, `generated` or long.
pub const CODE_CORE_NOTE_FOLDED: u8 = 2;
/// The patch was cut here.
pub const CODE_CORE_NOTE_CUT_HERE: u8 = 3;
/// The host listed only the first `count` files.
pub const CODE_CORE_NOTE_HOST_LISTS_FIRST: u8 = 4;

pub const CODE_CORE_SPLIT_HUNK: u8 = 0;
pub const CODE_CORE_SPLIT_NOTE: u8 = 1;
pub const CODE_CORE_SPLIT_PAIR: u8 = 2;

/// One diff line as drawn: its kind, its 1-based gutter numbers (`CODE_CORE_NONE` where the
/// side has none) and its text, without the `+`/`-`/` ` marker.
#[repr(C)]
pub struct CodeCoreDiffLine {
    pub kind: u8,
    pub old_number: u32,
    pub new_number: u32,
    pub text: CodeCoreStr,
}

#[repr(C)]
pub struct CodeCoreDiffLines {
    pub lines: *const CodeCoreDiffLine,
    pub count: usize,
}

fn kind(kind: LineKind) -> u8 {
    match kind {
        LineKind::Hunk => CODE_CORE_LINE_HUNK,
        LineKind::Context => CODE_CORE_LINE_CONTEXT,
        LineKind::Added => CODE_CORE_LINE_ADDED,
        LineKind::Removed => CODE_CORE_LINE_REMOVED,
        LineKind::Note => CODE_CORE_LINE_NOTE,
    }
}

fn line_views(lines: &[DiffLine]) -> Vec<CodeCoreDiffLine> {
    lines
        .iter()
        .map(|l| CodeCoreDiffLine {
            kind: kind(l.kind),
            old_number: l.old.unwrap_or(CODE_CORE_NONE),
            new_number: l.new.unwrap_or(CODE_CORE_NONE),
            text: CodeCoreStr::of(&l.text),
        })
        .collect()
}

type LinesData = (Vec<DiffLine>, Vec<CodeCoreDiffLine>);

/// A unified patch as drawn lines: a `@@ -a,b +c,d @@` header resets both counters, and
/// `\ No newline at end of file` is a note.
///
/// # Safety
/// `patch` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_diff_lines_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_parse(
    patch: CodeCoreStr,
    out: *mut *mut CodeCoreDiffLines,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let lines = DiffLine::parse(unsafe { patch.text() }?);
        let views = line_views(&lines);
        let result = owned::into_raw((lines, views), |(_, views): &LinesData| CodeCoreDiffLines {
            lines: views.as_ptr(),
            count: views.len(),
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free drawn lines; null is a no-op.
///
/// # Safety
/// `lines` is null or came from `code_core_diff_parse`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_lines_free(lines: *mut CodeCoreDiffLines) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreDiffLines, LinesData>(lines) }
}

/// One file of a change set, as far as its rows need it.
#[repr(C)]
pub struct CodeCoreChangedFile {
    pub path: CodeCoreStr,
    /// Ignored unless `has_patch`: a binary file, one the source would not diff, or one past
    /// the patch budget has none.
    pub patch: CodeCoreStr,
    pub has_patch: bool,
    /// The patch was cut at its source's line limit or dropped past its byte budget.
    pub trimmed: bool,
}

/// A file of a document: its drawn lines, its language (`CODE_CORE_NONE` for plain text),
/// whether it is folded, and each line's place in its side's patch-only text
/// (`old_fragment`, `new_fragment`: `line_count` entries, `CODE_CORE_NONE` where the line
/// is not that side's).
#[repr(C)]
pub struct CodeCoreDiffFile {
    pub lines: *const CodeCoreDiffLine,
    pub line_count: usize,
    pub language: u32,
    pub collapsed: bool,
    pub old_fragment: *const u32,
    pub new_fragment: *const u32,
}

/// One row of the Files changed view. `file` is the file's index; `index` is the line's for
/// a `CODE_CORE_ROW_LINE`; `note`, `count` and `generated` describe a `CODE_CORE_ROW_NOTE`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CodeCoreDocRow {
    pub kind: u8,
    pub file: u32,
    pub index: u32,
    pub note: u8,
    pub count: u32,
    pub generated: bool,
}

/// A change set as rows: each file's header, then (unless folded) its lines, or why it has
/// none; `columns` is each row's width in columns (`row_count` entries), `digits` the gutter's
/// figure width.
#[repr(C)]
pub struct CodeCoreDiffDocument {
    pub files: *const CodeCoreDiffFile,
    pub file_count: usize,
    pub rows: *const CodeCoreDocRow,
    pub row_count: usize,
    pub columns: *const u32,
    pub digits: u32,
}

// `lines` and `fragments` are never read: they own what the view points into.
#[allow(dead_code)]
struct DocumentData {
    document: DiffDocument,
    lines: Vec<Vec<CodeCoreDiffLine>>,
    fragments: Vec<(Vec<u32>, Vec<u32>)>,
    files: Vec<CodeCoreDiffFile>,
    rows: Vec<CodeCoreDocRow>,
}

fn row(row: &DocRow) -> CodeCoreDocRow {
    let blank = CodeCoreDocRow {
        kind: CODE_CORE_ROW_GAP,
        file: 0,
        index: 0,
        note: 0,
        count: 0,
        generated: false,
    };
    match *row {
        DocRow::Header { file } => CodeCoreDocRow {
            kind: CODE_CORE_ROW_HEADER,
            file: file as u32,
            ..blank
        },
        DocRow::Line { file, index } => CodeCoreDocRow {
            kind: CODE_CORE_ROW_LINE,
            file: file as u32,
            index: index as u32,
            ..blank
        },
        DocRow::Note { file, note } => {
            let (note, count, generated) = match note {
                FileNote::PastBudget => (CODE_CORE_NOTE_PAST_BUDGET, 0, false),
                FileNote::NoDiff => (CODE_CORE_NOTE_NO_DIFF, 0, false),
                FileNote::Folded { lines, generated } => (CODE_CORE_NOTE_FOLDED, lines, generated),
                FileNote::CutHere => (CODE_CORE_NOTE_CUT_HERE, 0, false),
                FileNote::HostListsFirst { files } => {
                    (CODE_CORE_NOTE_HOST_LISTS_FIRST, files, false)
                }
            };
            CodeCoreDocRow {
                kind: CODE_CORE_ROW_NOTE,
                file: file as u32,
                note,
                count: count as u32,
                generated,
                ..blank
            }
        }
        DocRow::Gap => blank,
    }
}

/// A change set's rows: `files` in drawn order, `truncated` when the host stopped listing
/// before the last file, `toggled` the paths whose fold the reader flipped (a lockfile, a
/// generated file or one past `CODE_CORE_COLLAPSE_LINES` lines starts folded).
///
/// # Safety
/// `files` (`file_count`) and `toggled` (`toggled_count`) are valid for the call; `out` is
/// valid for a write. Free the result with `code_core_diff_document_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_document(
    files: *const CodeCoreChangedFile,
    file_count: usize,
    truncated: bool,
    toggled: *const CodeCoreStr,
    toggled_count: usize,
    out: *mut *mut CodeCoreDiffDocument,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (files, toggled) =
            unsafe { (slice(files, file_count)?, slice(toggled, toggled_count)?) };
        let changed = files
            .iter()
            .map(|f| {
                // SAFETY: per this function's contract.
                let (path, patch) = unsafe { (f.path.text()?, f.patch.text()?) };
                Ok(ChangedFile {
                    path: path.to_owned(),
                    previous_path: None,
                    status: FileStatus::Modified,
                    additions: 0,
                    deletions: 0,
                    patch: f.has_patch.then(|| patch.to_owned()),
                    trimmed: f.trimmed,
                    old_blob: None,
                    new_blob: None,
                })
            })
            .collect::<Result<Vec<_>, Failure>>()?;
        let toggled = toggled
            .iter()
            // SAFETY: per this function's contract.
            .map(|s| unsafe { s.text() }.map(str::to_owned))
            .collect::<Result<HashSet<String>, Failure>>()?;
        let document = DiffDocument::new(changed, truncated, &toggled);
        let lines: Vec<Vec<CodeCoreDiffLine>> = document
            .files
            .iter()
            .map(|f| line_views(&f.lines))
            .collect();
        let fragments = document
            .files
            .iter()
            .map(|f| {
                let side = |fragment: &[Option<u32>]| -> Vec<u32> {
                    fragment
                        .iter()
                        .map(|n| n.unwrap_or(CODE_CORE_NONE))
                        .collect()
                };
                (side(&f.old_fragment), side(&f.new_fragment))
            })
            .collect::<Vec<_>>();
        let views = document
            .files
            .iter()
            .zip(&lines)
            .zip(&fragments)
            .map(|((file, lines), (old, new))| CodeCoreDiffFile {
                lines: lines.as_ptr(),
                line_count: lines.len(),
                language: file.language.map_or(CODE_CORE_NONE, code),
                collapsed: file.collapsed,
                old_fragment: old.as_ptr(),
                new_fragment: new.as_ptr(),
            })
            .collect();
        let rows = document.rows.iter().map(row).collect();
        let data = DocumentData {
            document,
            lines,
            fragments,
            files: views,
            rows,
        };
        let result = owned::into_raw(data, |d: &DocumentData| CodeCoreDiffDocument {
            files: d.files.as_ptr(),
            file_count: d.files.len(),
            rows: d.rows.as_ptr(),
            row_count: d.rows.len(),
            columns: d.document.columns.as_ptr(),
            digits: d.document.digits,
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free a document; null is a no-op.
///
/// # Safety
/// `document` is null or came from `code_core_diff_document`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_document_free(document: *mut CodeCoreDiffDocument) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreDiffDocument, DocumentData>(document) }
}

/// Row heights and the code column's place, in points.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CodeCoreDiffMetrics {
    pub line_height: f64,
    pub header_height: f64,
    pub gap_height: f64,
    pub note_height: f64,
    pub advance: f64,
    /// The code column's left edge: the gutter and the ± marker.
    pub code_x: f64,
}

impl From<Metrics> for CodeCoreDiffMetrics {
    fn from(m: Metrics) -> Self {
        Self {
            line_height: m.line_height,
            header_height: m.header_height,
            gap_height: m.gap_height,
            note_height: m.note_height,
            advance: m.advance,
            code_x: m.code_x,
        }
    }
}

impl From<CodeCoreDiffMetrics> for Metrics {
    fn from(m: CodeCoreDiffMetrics) -> Self {
        Self {
            line_height: m.line_height,
            header_height: m.header_height,
            gap_height: m.gap_height,
            note_height: m.note_height,
            advance: m.advance,
            code_x: m.code_x,
        }
    }
}

/// The metrics a layout starts from.
///
/// # Safety
/// `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_metrics_default(
    out: *mut CodeCoreDiffMetrics,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    // SAFETY: per this function's contract.
    call(error, || unsafe { put(out, Metrics::default().into()) })
}

/// Rows laid out at one width: each row's visual rows (a wrapped line is several) and the
/// running offsets (`row_count + 1`, the last is the height). `wrap_columns` is 0 when lines
/// do not wrap.
#[repr(C)]
pub struct CodeCoreDiffLayout {
    pub wrap_columns: u32,
    pub visual_rows: *const u32,
    pub offsets: *const f64,
    pub row_count: usize,
}

type LayoutData = DiffLayout;

/// Lay `row_count` rows out at `width` points: `row_kinds` are `CODE_CORE_ROW_*`, `columns`
/// each row's width in columns (a document's own). Wrapping fits whole columns after the
/// code column and a 12-point margin, never fewer than 20.
///
/// # Safety
/// `row_kinds` and `columns` hold `row_count` entries valid for the call; `out` is valid
/// for a write. Free the result with `code_core_diff_layout_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_layout(
    row_kinds: *const u8,
    columns: *const u32,
    row_count: usize,
    width: f64,
    wraps: bool,
    metrics: CodeCoreDiffMetrics,
    out: *mut *mut CodeCoreDiffLayout,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (kinds, columns) =
            unsafe { (slice(row_kinds, row_count)?, slice(columns, row_count)?) };
        let rows = kinds
            .iter()
            .map(|&k| match k {
                CODE_CORE_ROW_HEADER => Ok(DocRow::Header { file: 0 }),
                CODE_CORE_ROW_LINE => Ok(DocRow::Line { file: 0, index: 0 }),
                CODE_CORE_ROW_NOTE => Ok(DocRow::Note {
                    file: 0,
                    note: FileNote::NoDiff,
                }),
                CODE_CORE_ROW_GAP => Ok(DocRow::Gap),
                _ => Err(Failure::Invalid("an unknown row kind")),
            })
            .collect::<Result<Vec<_>, Failure>>()?;
        // The layout reads only the rows' kinds and columns.
        let document = DiffDocument {
            files: Vec::new(),
            rows,
            columns: columns.to_vec(),
            digits: 0,
        };
        let layout = DiffLayout::new(&document, width, wraps, metrics.into());
        let result = owned::into_raw(layout, |l: &LayoutData| CodeCoreDiffLayout {
            wrap_columns: l.wrap_columns.unwrap_or(0),
            visual_rows: l.visual_rows.as_ptr(),
            offsets: l.offsets.as_ptr(),
            row_count: l.visual_rows.len(),
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free a layout; null is a no-op.
///
/// # Safety
/// `layout` is null or came from `code_core_diff_layout`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_diff_layout_free(layout: *mut CodeCoreDiffLayout) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreDiffLayout, LayoutData>(layout) }
}

/// `text`'s width in columns: a tab runs to the next stop of `CODE_CORE_TAB_WIDTH`, East
/// Asian wide chars and emoji take two, combining marks none.
///
/// # Safety
/// `text` is valid for the call; `columns` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_columns(
    text: CodeCoreStr,
    columns: *mut u32,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let width = diff::columns(unsafe { text.text() }?);
        // SAFETY: per this function's contract.
        unsafe { put(columns, width) }
    })
}

/// A text with its tabs expanded, and each original UTF-16 offset's place in it (`map`, one
/// past the end included: the original's UTF-16 length + 1 entries).
#[repr(C)]
pub struct CodeCoreExpanded {
    pub text: CodeCoreStr,
    pub map: *const u32,
    pub map_count: usize,
}

type ExpandedData = (String, Vec<u32>);

/// `text` with its tabs expanded to their stops, and the UTF-16 offset map between the two.
///
/// # Safety
/// `text` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_expanded_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_expand_tabs(
    text: CodeCoreStr,
    out: *mut *mut CodeCoreExpanded,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (expanded, map) = diff::expand_tabs(unsafe { text.text() }?);
        let map = map.into_iter().map(|n| n as u32).collect();
        let result = owned::into_raw((expanded, map), |(text, map): &ExpandedData| {
            CodeCoreExpanded {
                text: CodeCoreStr::of(text),
                map: map.as_ptr(),
                map_count: map.len(),
            }
        });
        // SAFETY: per this function's contract.
        unsafe { put(out, result) }
    })
}

/// Free an expanded text; null is a no-op.
///
/// # Safety
/// `expanded` is null or came from `code_core_expand_tabs`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_expanded_free(expanded: *mut CodeCoreExpanded) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreExpanded, ExpandedData>(expanded) }
}

/// Where each visual row after the first starts in a line wrapped at `columns` (its drawn
/// text, tabs expanded), in UTF-16 units: the drawing half of the layout's wrap rule. A wide
/// char on a row's last column stays on it; a line never draws more rows than its layout.
///
/// # Safety
/// `text` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_numbers_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_row_starts(
    text: CodeCoreStr,
    columns: u32,
    out: *mut *mut CodeCoreNumbers,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let text = unsafe { text.text() }?;
        let mut cursor = utf16::Cursor::default();
        let starts = diff::row_starts(text, columns)
            .into_iter()
            .map(|at| cursor.at(text, at) as u32)
            .collect();
        // SAFETY: per this function's contract.
        unsafe { put(out, numbers_result(starts)) }
    })
}

/// Whether a path is a lockfile or a generated file (they start folded).
///
/// # Safety
/// `path` is valid for the call; `generated` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_is_generated(
    path: CodeCoreStr,
    generated: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let found = diff::is_generated(unsafe { path.text() }?);
        // SAFETY: per this function's contract.
        unsafe { put(generated, found) }
    })
}

/// Whether a file starts folded: a lockfile or generated file, or a patch of more than
/// `CODE_CORE_COLLAPSE_LINES` lines.
///
/// # Safety
/// `path` is valid for the call; `collapsed` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_collapsed_by_default(
    path: CodeCoreStr,
    lines: usize,
    collapsed: *mut bool,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        let file = ChangedFile {
            // SAFETY: per this function's contract.
            path: unsafe { path.text() }?.to_owned(),
            previous_path: None,
            status: FileStatus::Modified,
            additions: 0,
            deletions: 0,
            patch: None,
            trimmed: false,
            old_blob: None,
            new_blob: None,
        };
        let folded = DiffDocument::collapsed_by_default(&file, lines);
        // SAFETY: per this function's contract.
        unsafe { put(collapsed, folded) }
    })
}

/// A diff: unified lines, their hunks, each line's changed words (UTF-16 ranges of its text:
/// line `i`'s are `words[word_starts[i] .. word_starts[i + 1]]`) and the side-by-side rows.
#[repr(C)]
pub struct CodeCoreTextDiff {
    pub lines: *const CodeCoreDiffLine,
    pub line_count: usize,
    pub hunks: *const CodeCoreHunk,
    pub hunk_count: usize,
    pub words: *const CodeCoreRange,
    pub word_starts: *const u32,
    pub split: *const CodeCoreSplitRow,
    pub split_count: usize,
}

/// One hunk: its header line, its ranges, its section heading and its lines after the
/// header (`first_line .. end_line`).
#[repr(C)]
pub struct CodeCoreHunk {
    pub header: u32,
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub section: CodeCoreStr,
    pub first_line: u32,
    pub end_line: u32,
}

/// One side-by-side row: `CODE_CORE_SPLIT_HUNK` or `_NOTE` across both sides (`line`), or a
/// `_PAIR` of line indices (`CODE_CORE_NONE` is a filler).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CodeCoreSplitRow {
    pub kind: u8,
    pub line: u32,
    pub old_line: u32,
    pub new_line: u32,
}

// `diff` is never read: it owns the texts the view points into.
#[allow(dead_code)]
struct TextDiffData {
    diff: TextDiff,
    lines: Vec<CodeCoreDiffLine>,
    hunks: Vec<CodeCoreHunk>,
    words: Vec<CodeCoreRange>,
    word_starts: Vec<u32>,
    split: Vec<CodeCoreSplitRow>,
}

fn text_diff(diff: TextDiff) -> *mut CodeCoreTextDiff {
    let index = |n: Option<usize>| n.map_or(CODE_CORE_NONE, |n| n as u32);
    let lines = line_views(&diff.lines);
    let hunks = diff
        .hunks
        .iter()
        .map(|h| CodeCoreHunk {
            header: h.header as u32,
            old_start: h.old_start,
            old_lines: h.old_lines,
            new_start: h.new_start,
            new_lines: h.new_lines,
            section: CodeCoreStr::of(&h.section),
            first_line: h.lines.start as u32,
            end_line: h.lines.end as u32,
        })
        .collect();
    let (mut words, mut word_starts) = (Vec::new(), Vec::with_capacity(diff.lines.len() + 1));
    for (line, ranges) in diff.lines.iter().zip(&diff.words) {
        word_starts.push(words.len() as u32);
        let mut cursor = utf16::Cursor::default();
        for r in ranges {
            let start = cursor.at(&line.text, r.start) as u32;
            let end = cursor.at(&line.text, r.end) as u32;
            words.push(CodeCoreRange { start, end });
        }
    }
    word_starts.push(words.len() as u32);
    let split = diff
        .split
        .iter()
        .map(|r| match *r {
            SplitRow::Hunk(line) => (CODE_CORE_SPLIT_HUNK, Some(line), None, None),
            SplitRow::Note(line) => (CODE_CORE_SPLIT_NOTE, Some(line), None, None),
            SplitRow::Pair { old, new } => (CODE_CORE_SPLIT_PAIR, None, old, new),
        })
        .map(|(kind, line, old, new)| CodeCoreSplitRow {
            kind,
            line: index(line),
            old_line: index(old),
            new_line: index(new),
        })
        .collect();
    let data = TextDiffData {
        diff,
        lines,
        hunks,
        words,
        word_starts,
        split,
    };
    owned::into_raw(data, |d: &TextDiffData| CodeCoreTextDiff {
        lines: d.lines.as_ptr(),
        line_count: d.lines.len(),
        hunks: d.hunks.as_ptr(),
        hunk_count: d.hunks.len(),
        words: d.words.as_ptr(),
        word_starts: d.word_starts.as_ptr(),
        split: d.split.as_ptr(),
        split_count: d.split.len(),
    })
}

/// `old_text` → `new_text` with `context` lines around each change (patience, git's hunk ranges, the
/// missing final newline as a note).
///
/// # Safety
/// Texts are valid for the call; `out` is valid for a write. Free the result with
/// `code_core_text_diff_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_text_diff(
    old_text: CodeCoreStr,
    new_text: CodeCoreStr,
    context: u32,
    out: *mut *mut CodeCoreTextDiff,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (old, new) = unsafe { (old_text.text()?, new_text.text()?) };
        let diff = TextDiff::new(old, new, context as usize);
        // SAFETY: per this function's contract.
        unsafe { put(out, text_diff(diff)) }
    })
}

/// A unified patch (a file's part of `git diff`, from its first `@@`) as a text diff.
///
/// # Safety
/// `patch` is valid for the call; `out` is valid for a write. Free the result with
/// `code_core_text_diff_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_patch_diff(
    patch: CodeCoreStr,
    out: *mut *mut CodeCoreTextDiff,
    error: *mut *mut c_char,
) -> CodeCoreStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let diff = TextDiff::from_patch(unsafe { patch.text() }?);
        // SAFETY: per this function's contract.
        unsafe { put(out, text_diff(diff)) }
    })
}

/// Free a text diff; null is a no-op.
///
/// # Safety
/// `diff` is null or came from `code_core_text_diff` / `code_core_patch_diff`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn code_core_text_diff_free(diff: *mut CodeCoreTextDiff) {
    // SAFETY: per this function's contract.
    unsafe { owned::free::<CodeCoreTextDiff, TextDiffData>(diff) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{read, s};
    use crate::{CODE_CORE_OK, code_core_numbers_free};
    use std::ptr::null_mut;

    fn changed(path: &str, patch: Option<&str>, trimmed: bool) -> CodeCoreChangedFile {
        CodeCoreChangedFile {
            path: s(path),
            patch: s(patch.unwrap_or("")),
            has_patch: patch.is_some(),
            trimmed,
        }
    }

    /// The document crosses whole: rows with their notes as data, columns, digits, each
    /// file's lines, language, fold and fragments; then lays out by its row kinds.
    #[test]
    fn a_change_set_crosses_as_rows_and_lays_out() {
        let patch = "@@ -9,2 +9,2 @@\n fn a() {}\n-let x = 1;\n+let 漢 = 2;";
        let files = [
            changed("src/a.rs", Some(patch), false),
            changed("yarn.lock", Some("@@ -1 +1 @@\n-a\n+b"), false),
            changed("img.png", None, false),
            changed("long.ts", None, true),
        ];
        let toggled = [s("nothing")];
        let mut out = null_mut();
        // SAFETY: valid arguments; freed below.
        let document = unsafe {
            let status = code_core_diff_document(
                files.as_ptr(),
                files.len(),
                true,
                toggled.as_ptr(),
                1,
                &mut out,
                null_mut(),
            );
            assert_eq!(status, CODE_CORE_OK);
            &*out
        };
        // SAFETY: arrays of the result's counts.
        let (rows, columns, docs) = unsafe {
            (
                std::slice::from_raw_parts(document.rows, document.row_count),
                std::slice::from_raw_parts(document.columns, document.row_count),
                std::slice::from_raw_parts(document.files, document.file_count),
            )
        };
        let kinds: Vec<(u8, u8)> = rows.iter().map(|r| (r.kind, r.note)).collect();
        use crate::diff::{
            CODE_CORE_NOTE_FOLDED as F, CODE_CORE_NOTE_HOST_LISTS_FIRST as H,
            CODE_CORE_NOTE_NO_DIFF as N, CODE_CORE_NOTE_PAST_BUDGET as P, CODE_CORE_ROW_GAP as G,
            CODE_CORE_ROW_HEADER as R, CODE_CORE_ROW_LINE as L, CODE_CORE_ROW_NOTE as T,
        };
        assert_eq!(
            kinds,
            [
                (R, 0),
                (L, 0),
                (L, 0),
                (L, 0),
                (L, 0),
                (G, 0),
                (R, 0),
                (T, F),
                (G, 0),
                (R, 0),
                (T, N),
                (G, 0),
                (R, 0),
                (T, P),
                (T, H)
            ]
        );
        assert_eq!((rows[7].count, rows[7].generated), (3, true));
        assert_eq!(rows[14].count, 4);
        assert_eq!(columns[4], 11, "`let 漢 = 2;`: the wide char counts two");
        assert_eq!(document.digits, 3);
        let a = &docs[0];
        assert_eq!(
            (a.language, a.collapsed),
            (crate::syntax::CODE_CORE_LANGUAGE_RUST, false)
        );
        // SAFETY: arrays of the file's line count.
        let (lines, old, new) = unsafe {
            (
                std::slice::from_raw_parts(a.lines, a.line_count),
                std::slice::from_raw_parts(a.old_fragment, a.line_count),
                std::slice::from_raw_parts(a.new_fragment, a.line_count),
            )
        };
        let read_lines: Vec<_> = lines
            .iter()
            .map(|l| (l.kind, l.old_number, l.new_number, read(l.text)))
            .collect();
        assert_eq!(
            read_lines[2],
            (
                CODE_CORE_LINE_REMOVED,
                10,
                CODE_CORE_NONE,
                "let x = 1;".into()
            )
        );
        assert_eq!(old, [CODE_CORE_NONE, 0, 1, CODE_CORE_NONE]);
        assert_eq!(new, [CODE_CORE_NONE, 0, CODE_CORE_NONE, 1]);
        assert!(docs[1].collapsed);

        let kinds: Vec<u8> = rows.iter().map(|r| r.kind).collect();
        let metrics = CodeCoreDiffMetrics {
            advance: 10.0,
            code_x: 0.0,
            ..Metrics::default().into()
        };
        let mut laid = null_mut();
        // SAFETY: valid arrays; freed below.
        let layout = unsafe {
            let status = code_core_diff_layout(
                kinds.as_ptr(),
                columns.as_ptr(),
                kinds.len(),
                1012.0,
                true,
                metrics,
                &mut laid,
                null_mut(),
            );
            assert_eq!(status, CODE_CORE_OK);
            &*laid
        };
        assert_eq!(layout.wrap_columns, 100);
        // SAFETY: the result's arrays.
        let offsets = unsafe { std::slice::from_raw_parts(layout.offsets, layout.row_count + 1) };
        assert_eq!(offsets[1], 30.0, "a header");
        // SAFETY: freed once each.
        unsafe {
            code_core_diff_layout_free(laid);
            code_core_diff_document_free(out);
        }
    }

    #[test]
    fn columns_tabs_and_row_starts_in_utf16() {
        let (mut columns, mut out) = (0, null_mut());
        // SAFETY: valid arguments; freed below.
        unsafe {
            code_core_columns(s("\t漢x"), &mut columns, null_mut());
            assert_eq!(columns, 7);
            code_core_expand_tabs(s("😀\tb"), &mut out, null_mut());
            assert_eq!(read((*out).text), "😀  b");
            let map = std::slice::from_raw_parts((*out).map, (*out).map_count);
            assert_eq!(map, [0, 1, 2, 4, 5]);
            code_core_expanded_free(out);
            let mut starts = null_mut();
            code_core_row_starts(s(&"😀".repeat(30)), 20, &mut starts, null_mut());
            let starts_read = std::slice::from_raw_parts((*starts).values, (*starts).count);
            assert_eq!(starts_read, [20, 40], "ten emoji a row, two units each");
            code_core_numbers_free(starts);
            let mut generated = false;
            code_core_is_generated(s("web/app.min.js"), &mut generated, null_mut());
            assert!(generated);
            let mut folded = false;
            code_core_collapsed_by_default(s("src/a.rs"), 1501, &mut folded, null_mut());
            assert!(folded, "past the line limit");
            code_core_collapsed_by_default(s("src/a.rs"), 1500, &mut folded, null_mut());
            assert!(!folded);
        }
    }

    #[test]
    fn a_text_diff_pairs_and_marks_words() {
        let mut out = null_mut();
        // SAFETY: valid arguments; freed below.
        unsafe {
            let status = code_core_text_diff(
                s("a\nlet é = 1;\nz\n"),
                s("a\nlet é = 2;\nz\n"),
                3,
                &mut out,
                null_mut(),
            );
            assert_eq!(status, CODE_CORE_OK);
            let d = &*out;
            let lines = std::slice::from_raw_parts(d.lines, d.line_count);
            let kinds: Vec<u8> = lines.iter().map(|l| l.kind).collect();
            assert_eq!(
                kinds,
                [
                    CODE_CORE_LINE_HUNK,
                    CODE_CORE_LINE_CONTEXT,
                    CODE_CORE_LINE_REMOVED,
                    CODE_CORE_LINE_ADDED,
                    CODE_CORE_LINE_CONTEXT
                ]
            );
            let starts = std::slice::from_raw_parts(d.word_starts, d.line_count + 1);
            let words = std::slice::from_raw_parts(d.words, starts[d.line_count] as usize);
            let removed = &words[starts[2] as usize..starts[3] as usize];
            assert_eq!(
                removed,
                [CodeCoreRange { start: 8, end: 9 }],
                "UTF-16, after é"
            );
            let split = std::slice::from_raw_parts(d.split, d.split_count);
            assert!(split.contains(&CodeCoreSplitRow {
                kind: CODE_CORE_SPLIT_PAIR,
                line: CODE_CORE_NONE,
                old_line: 2,
                new_line: 3
            }));
            let hunks = std::slice::from_raw_parts(d.hunks, d.hunk_count);
            assert_eq!(
                (hunks[0].old_start, hunks[0].new_lines, hunks[0].end_line),
                (1, 3, 5)
            );
            code_core_text_diff_free(out);
        }
    }
}
