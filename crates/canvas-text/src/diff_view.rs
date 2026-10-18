//! The diff view (D1, docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md): a change set — code-core's [`DiffDocument`], one file or many
//! — laid out inline or side by side and painted into ops for the rows in view. Pultík's Files
//! changed and the editor shell's diff islands both draw through it, so there is one diff painter.
//!
//! The rows are code-core's; this view gives them heights (a wrapped line is several visual
//! rows, by code-core's diff rule: a char sits on the row its first column falls in), paints
//! file headers, the sticky header, notes, gutters, washes, changed words, the selection, marks
//! and a scroll indicator, and hit-tests a point back to a file, a line and a byte. Colours are
//! a theme's ([`CodeColors`]); the host adds only its accent ([`DiffDecor`]). A steady frame
//! reshapes nothing: rows are refilled in place into pooled [`CodeRows`] once the renderer has
//! let go of the last frame's.

use crate::code_view::CodeColors;
use canvas_draw::{
    Border, CellSpan, CodeBlock, CodeRows, Op, Point, Rect, Rgba, RoundedRect, Size, TextRun,
};
use code_core::diff::{
    DiffDocument, DiffFile, DiffLine, DocRow, FileNote, FileStatus, LineKind, Side, SplitRow,
    columns, side_by_side, words,
};
use code_core::syntax::LineTokens;
use code_core::{Placer, search};
use std::fmt::Write;
use std::ops::{Range, RangeInclusive};
use std::sync::Arc;

fn rgba(c: theme::Rgba) -> Rgba {
    Rgba::new(c.r, c.g, c.b, c.a)
}

/// How the view lays out a change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DiffMode {
    #[default]
    Inline,
    Split,
}

/// Row heights and the code font, in points at the view's zoom.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DiffMetrics {
    /// One code cell: the code font's advance and the line height.
    pub cell: Size,
    /// The code font's point size.
    pub font_size: f32,
    pub header_height: f32,
    pub gap_height: f32,
    pub note_height: f32,
    /// The UI font size a note is worded in.
    pub note_size: f32,
}

impl DiffMetrics {
    /// The PR workbench's proportions for a code cell: an 18 pt line, a 30 pt header (D9,
    /// docs/specs/2026-10-15-pr-workbench-decisions.md).
    pub fn for_cell(cell: Size, font_size: f32) -> Self {
        let k = cell.h / 18.0;
        Self {
            cell,
            font_size,
            header_height: 30.0 * k,
            gap_height: 12.0 * k,
            note_height: 24.0 * k,
            note_size: 11.0 * k,
        }
    }

    fn k(&self) -> f32 {
        self.cell.h / 18.0
    }
}

/// One row of the view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewRow {
    Header {
        file: usize,
    },
    /// The space between two files.
    Gap,
    Note {
        file: usize,
        note: FileNote,
    },
    /// Inline: one line of a file.
    Line {
        file: usize,
        index: usize,
    },
    /// Side by side: a line on each side or a filler; a hunk header or a note names the same
    /// line on both.
    Pair {
        file: usize,
        old: Option<usize>,
        new: Option<usize>,
    },
}

impl ViewRow {
    pub fn file(&self) -> Option<usize> {
        match *self {
            ViewRow::Header { file }
            | ViewRow::Note { file, .. }
            | ViewRow::Line { file, .. }
            | ViewRow::Pair { file, .. } => Some(file),
            ViewRow::Gap => None,
        }
    }
}

/// What a point is over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffHit {
    Header {
        file: usize,
    },
    /// A line's gutter: where a review comment starts.
    Gutter {
        file: usize,
        index: usize,
    },
    /// A line's code, at a byte of its text.
    Code {
        file: usize,
        index: usize,
        byte: usize,
    },
    Note {
        file: usize,
    },
    None,
}

/// A place in the view's text: a row and a byte of its line (0 on a row with no line).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Caret {
    pub row: usize,
    pub byte: usize,
}

/// What the host draws over the change this frame.
#[derive(Debug, Clone)]
pub struct DiffDecor<'a> {
    /// The host's accent: the focused file's ring, marks and the anchor's wash.
    pub accent: Rgba,
    /// The file whose header is ringed.
    pub focused: Option<usize>,
    /// Lines with a gutter mark (a pending comment, an open thread), as (file, line index),
    /// sorted.
    pub marks: &'a [(usize, usize)],
    /// The lines a comment is being written about: a file and its line indices.
    pub anchor: Option<(usize, RangeInclusive<usize>)>,
    /// Draw the scroll indicator.
    pub indicator: bool,
}

/// One change set on screen: its rows at a width, where the view sits, and its selection.
#[derive(Debug)]
pub struct DiffView {
    document: DiffDocument,
    /// Each file's highlights by side (old, new), as they land.
    tokens: Vec<[Option<LineTokens>; 2]>,
    /// Each file's changed words by line, bytes.
    words: Vec<Vec<Vec<Range<usize>>>>,
    mode: DiffMode,
    wraps: bool,
    /// Draw file headers and the gaps between files (a one-file island draws neither).
    headers: bool,
    metrics: DiffMetrics,
    /// The view's top-left in the host's points.
    pub origin: Point,
    size: Size,
    top: f64,
    left: f32,
    rows: Vec<ViewRow>,
    visual: Vec<u32>,
    offsets: Vec<f64>,
    header_rows: Vec<Option<usize>>,
    wrap: Option<u32>,
    gutter_cols: u16,
    code_cols: u32,
    widest: u32,
    /// The anchor and the head.
    selection: Option<(Caret, Caret)>,
    pool: Vec<Arc<CodeRows>>,
    used: usize,
    cols: Vec<u16>,
    byte_cols: Vec<u16>,
    text: String,
    /// Where each visual row of the line being filled starts, in bytes.
    starts: Vec<usize>,
}

impl DiffView {
    pub fn new(document: DiffDocument, metrics: DiffMetrics, headers: bool) -> Self {
        let mut view = Self {
            tokens: Vec::new(),
            words: Vec::new(),
            document,
            mode: DiffMode::Inline,
            wraps: false,
            headers,
            metrics,
            origin: Point::ZERO,
            size: Size::new(0.0, 0.0),
            top: 0.0,
            left: 0.0,
            rows: Vec::new(),
            visual: Vec::new(),
            offsets: vec![0.0],
            header_rows: Vec::new(),
            wrap: None,
            gutter_cols: 0,
            code_cols: 0,
            widest: 0,
            selection: None,
            pool: Vec::new(),
            used: 0,
            cols: Vec::new(),
            byte_cols: Vec::new(),
            text: String::new(),
            starts: Vec::new(),
        };
        view.reset_files();
        view.relayout();
        view
    }

    fn reset_files(&mut self) {
        self.tokens = self.document.files.iter().map(|_| [None, None]).collect();
        self.words = self
            .document
            .files
            .iter()
            .map(|f| words(&f.lines))
            .collect();
    }

    pub fn document(&self) -> &DiffDocument {
        &self.document
    }

    /// A new change set (or a fold flipped). Highlights and the reader's place survive when
    /// it lists the same files in the same order.
    pub fn set_document(&mut self, document: DiffDocument) {
        let same = self.document.files.len() == document.files.len()
            && self
                .document
                .files
                .iter()
                .zip(&document.files)
                .all(|(a, b)| a.changed == b.changed);
        let anchor = same.then(|| self.anchor()).flatten();
        self.document = document;
        // A fold keeps every file's highlights; only its rows change.
        if !same {
            self.reset_files();
        }
        self.selection = None;
        self.relayout_keeping(anchor);
    }

    /// One side of one file's highlights landed: its rows draw coloured from the next paint.
    pub fn set_tokens(&mut self, file: usize, side: Side, tokens: LineTokens) {
        if let Some(t) = self.tokens.get_mut(file) {
            t[side_index(side)] = Some(tokens);
        }
    }

    pub fn has_tokens(&self, file: usize, side: Side) -> bool {
        self.tokens
            .get(file)
            .is_some_and(|t| t[side_index(side)].is_some())
    }

    pub fn mode(&self) -> DiffMode {
        self.mode
    }

    pub fn set_mode(&mut self, mode: DiffMode) {
        if mode != self.mode {
            let anchor = self.anchor();
            self.mode = mode;
            self.selection = None;
            self.relayout_keeping(anchor);
        }
    }

    pub fn wraps(&self) -> bool {
        self.wraps
    }

    /// Wrap long lines under the gutter (the reader's line stays at the top).
    pub fn set_wraps(&mut self, wraps: bool) {
        if wraps != self.wraps {
            let anchor = self.anchor();
            self.wraps = wraps;
            self.left = 0.0;
            self.relayout_keeping(anchor);
        }
    }

    pub fn metrics(&self) -> DiffMetrics {
        self.metrics
    }

    /// The code font changed size (a zoom): rows are measured again.
    pub fn set_metrics(&mut self, metrics: DiffMetrics) {
        if metrics != self.metrics {
            let anchor = self.anchor();
            self.metrics = metrics;
            self.relayout_keeping(anchor);
        }
    }

    pub fn size(&self) -> Size {
        self.size
    }

    /// The view's size in points: a new width wraps again, keeping the reader's line.
    pub fn resize(&mut self, size: Size) {
        if size == self.size {
            return;
        }
        let width_moved = (size.w - self.size.w).abs() > 0.5;
        self.size = size;
        if width_moved {
            let anchor = self.anchor();
            self.relayout_keeping(anchor);
        } else {
            self.clamp();
        }
    }

    // ---- layout -------------------------------------------------------------------------

    /// The row at the top of the view and how far into it.
    fn anchor(&self) -> Option<(ViewRow, f64)> {
        if self.rows.is_empty() {
            return None;
        }
        let row = self.row_at(self.top);
        Some((self.rows[row], self.top - self.offsets[row]))
    }

    fn relayout_keeping(&mut self, anchor: Option<(ViewRow, f64)>) {
        self.relayout();
        if let Some((row, into)) = anchor
            && let Some(at) = self.rows.iter().position(|r| *r == row)
        {
            self.top = self.offsets[at] + into.min(self.offsets[at + 1] - self.offsets[at]);
        }
        self.clamp();
    }

    fn relayout(&mut self) {
        let m = self.metrics;
        let digits = self.document.digits as u16;
        let advance = m.cell.w.max(0.1);
        // " old new ± " inline; " n ± " on each side.
        self.gutter_cols = match self.mode {
            DiffMode::Inline => 2 * (digits + 1) + 3,
            DiffMode::Split => digits + 4,
        };
        let pane = match self.mode {
            DiffMode::Inline => self.size.w,
            DiffMode::Split => self.size.w / 2.0,
        };
        let room = pane - f32::from(self.gutter_cols) * advance - 12.0 * m.k();
        self.code_cols = ((room / advance).floor().max(0.0) as u32).max(20);
        self.wrap = self.wraps.then_some(self.code_cols);
        self.rows.clear();
        self.visual.clear();
        self.offsets.clear();
        self.offsets.push(0.0);
        self.header_rows = vec![None; self.document.files.len()];
        self.widest = 0;
        // Visual rows a line of `cols` columns takes: code-core's diff rule, over the
        // document's measured columns (side by side measures each pair's lines).
        let wrap = self.wrap;
        let rows_for = |cols: u32| wrap.map_or(1, |w| cols.div_ceil(w).max(1));
        let mut split_done = None;
        for (i, row) in self.document.rows.iter().enumerate() {
            let (view_row, count) = match *row {
                DocRow::Header { file } if self.headers => {
                    self.header_rows[file] = Some(self.rows.len());
                    (ViewRow::Header { file }, 1)
                }
                DocRow::Gap if self.headers => (ViewRow::Gap, 1),
                DocRow::Header { .. } | DocRow::Gap => continue,
                DocRow::Note { file, note } => (ViewRow::Note { file, note }, 1),
                DocRow::Line { file, index } => {
                    self.widest = self.widest.max(self.document.columns[i]);
                    if self.mode == DiffMode::Inline {
                        let cols = self.document.columns[i];
                        (ViewRow::Line { file, index }, rows_for(cols))
                    } else {
                        if split_done != Some(file) {
                            split_done = Some(file);
                            let lines = &self.document.files[file].lines;
                            for split in side_by_side(lines) {
                                let (old, new) = match split {
                                    SplitRow::Hunk(i) | SplitRow::Note(i) => (Some(i), Some(i)),
                                    SplitRow::Pair { old, new } => (old, new),
                                };
                                let count = [old, new]
                                    .into_iter()
                                    .flatten()
                                    .map(|i| rows_for(columns(&lines[i].text)))
                                    .max()
                                    .unwrap_or(1);
                                self.rows.push(ViewRow::Pair { file, old, new });
                                self.visual.push(count);
                            }
                        }
                        continue;
                    }
                }
            };
            self.rows.push(view_row);
            self.visual.push(count);
        }
        let mut y = 0.0;
        for (row, &count) in self.rows.iter().zip(&self.visual) {
            y += f64::from(match row {
                ViewRow::Header { .. } => m.header_height,
                ViewRow::Gap => m.gap_height,
                ViewRow::Note { .. } => m.note_height,
                ViewRow::Line { .. } | ViewRow::Pair { .. } => count as f32 * m.cell.h,
            });
            self.offsets.push(y);
        }
    }

    pub fn rows(&self) -> &[ViewRow] {
        &self.rows
    }

    /// The whole change's height in points.
    pub fn height(&self) -> f64 {
        self.offsets.last().copied().unwrap_or(0.0)
    }

    /// Row `row`'s top and height in the change's points.
    pub fn frame(&self, row: usize) -> (f64, f64) {
        (self.offsets[row], self.offsets[row + 1] - self.offsets[row])
    }

    /// The row whose span holds `y` (clamped to the change).
    pub fn row_at(&self, y: f64) -> usize {
        let count = self.rows.len();
        if count == 0 {
            return 0;
        }
        self.offsets[..count]
            .partition_point(|&top| top <= y)
            .saturating_sub(1)
    }

    /// Where the code column starts, in points from the view's left edge (each pane's, side by
    /// side).
    pub fn code_x(&self) -> f32 {
        f32::from(self.gutter_cols) * self.metrics.cell.w
    }

    /// Code columns per wrapped row (each side's, side by side).
    pub fn code_cols(&self) -> u32 {
        self.code_cols
    }

    // ---- scrolling ----------------------------------------------------------------------

    pub fn top(&self) -> f64 {
        self.top
    }

    pub fn left(&self) -> f32 {
        self.left
    }

    pub fn max_top(&self) -> f64 {
        (self.height() - f64::from(self.size.h)).max(0.0)
    }

    fn max_left(&self) -> f32 {
        if self.wrap.is_some() || self.mode == DiffMode::Split {
            return 0.0;
        }
        let code_w = self.size.w - self.code_x();
        (self.widest as f32 * self.metrics.cell.w + 24.0 * self.metrics.k() - code_w).max(0.0)
    }

    fn clamp(&mut self) {
        self.top = self.top.clamp(0.0, self.max_top());
        self.left = self.left.clamp(0.0, self.max_left());
    }

    /// Scroll by points (a gesture's delta: positive moves the view down and right).
    pub fn scroll_by(&mut self, dx: f32, dy: f64) {
        self.top += dy;
        self.left += dx;
        self.clamp();
    }

    /// Put `y` (change points) at the top, clamped.
    pub fn set_top(&mut self, y: f64) {
        self.top = y;
        self.clamp();
    }

    /// A file header's top: where ⇥ and the tree jump to.
    pub fn header_top(&self, file: usize) -> Option<f64> {
        let row = (*self.header_rows.get(file)?)?;
        Some(self.offsets[row])
    }

    /// The top of the row drawing a file's new-side line `line` (1-based), if it is shown.
    pub fn line_top(&self, file: usize, line: u32) -> Option<f64> {
        let lines = &self.document.files.get(file)?.lines;
        let index = lines.iter().position(|l| l.new == Some(line))?;
        let row = self.rows.iter().position(|r| match *r {
            ViewRow::Line { file: f, index: i } => f == file && i == index,
            ViewRow::Pair { file: f, new, .. } => f == file && new == Some(index),
            _ => false,
        })?;
        Some(self.offsets[row])
    }

    /// The file whose rows are at the top of the view (a gap belongs to the file below it).
    pub fn top_file(&self) -> Option<usize> {
        if self.rows.is_empty() {
            return None;
        }
        let row = self.row_at(self.top);
        self.rows[row]
            .file()
            .or_else(|| self.rows.get(row + 1).and_then(ViewRow::file))
    }

    /// The file whose rows are at the bottom edge of the view (a gap belongs to the file
    /// above it).
    pub fn bottom_file(&self) -> Option<usize> {
        if self.rows.is_empty() {
            return None;
        }
        let row = self.row_at(self.top + f64::from(self.size.h) - 0.5);
        self.rows[row]
            .file()
            .or_else(|| row.checked_sub(1).and_then(|r| self.rows[r].file()))
    }

    // ---- hit-testing and selection ------------------------------------------------------

    /// The change's point under a view point (relative to `origin`).
    fn change_y(&self, p: Point) -> f64 {
        f64::from(p.y - self.origin.y) + self.top
    }

    /// What view point `p` (the host's points) is over.
    pub fn hit(&self, p: Point) -> DiffHit {
        if self.rows.is_empty() || p.y < self.origin.y || p.y >= self.origin.y + self.size.h {
            return DiffHit::None;
        }
        if let Some(file) = self.sticky_hit(p) {
            return DiffHit::Header { file };
        }
        let y = self.change_y(p);
        if y >= self.height() {
            return DiffHit::None;
        }
        let row = self.row_at(y);
        let x = p.x - self.origin.x;
        match self.rows[row] {
            ViewRow::Header { file } => DiffHit::Header { file },
            ViewRow::Note { file, .. } => DiffHit::Note { file },
            ViewRow::Gap => DiffHit::None,
            ViewRow::Line { file, index } => self.line_hit(row, file, index, x, y),
            ViewRow::Pair { file, old, new } => {
                let half = self.size.w / 2.0;
                let (index, x) = match x < half {
                    true => (old, x),
                    false => (new, x - half),
                };
                index.map_or(DiffHit::None, |index| self.line_hit(row, file, index, x, y))
            }
        }
    }

    fn line_hit(&self, row: usize, file: usize, index: usize, x: f32, y: f64) -> DiffHit {
        let line = &self.document.files[file].lines[index];
        if x < self.code_x() - self.metrics.cell.w {
            if matches!(line.kind, LineKind::Hunk | LineKind::Note) {
                return DiffHit::None;
            }
            return DiffHit::Gutter { file, index };
        }
        let byte = self.byte_at(row, &line.text, x, y);
        DiffHit::Code { file, index, byte }
    }

    /// The byte of `text` (row `row`'s line) nearest view x `x` (from the pane's left) at
    /// change y `y`.
    fn byte_at(&self, row: usize, text: &str, x: f32, y: f64) -> usize {
        let m = self.metrics;
        let visual = ((y - self.offsets[row]) / f64::from(m.cell.h))
            .floor()
            .max(0.0) as u32;
        let column = ((x - self.code_x() + self.left) / m.cell.w)
            .round()
            .max(0.0) as u32;
        let target = match self.wrap {
            Some(w) => visual * w + column.min(w),
            None => column,
        };
        let mut placer = Placer::new(None);
        for (at, c) in text.char_indices() {
            let p = placer.place(c);
            if p.width > 0 && p.x >= target {
                return at;
            }
            if p.width > 0 && p.x + p.width > target {
                // Inside a tab or a wide char: the nearer edge.
                return match target - p.x < p.width.div_ceil(2) {
                    true => at,
                    false => at + c.len_utf8(),
                };
            }
        }
        text.len()
    }

    /// The identifier under view point `p`, and its file: what a hover peeks and ⌘-click
    /// follows.
    pub fn word_at(&self, p: Point) -> Option<(usize, String)> {
        let DiffHit::Code { file, index, byte } = self.hit(p) else {
            return None;
        };
        let text = &self.document.files[file].lines[index].text;
        let column = text[..byte].encode_utf16().count();
        search::word_at(text, column as isize).map(|w| (file, w))
    }

    /// The caret at view point `p`: inline only (side by side has no selection).
    fn caret_at(&self, p: Point) -> Option<Caret> {
        if self.mode != DiffMode::Inline || self.rows.is_empty() {
            return None;
        }
        let y = self.change_y(p).clamp(0.0, (self.height() - 0.5).max(0.0));
        let row = self.row_at(y);
        let byte = match self.rows[row] {
            ViewRow::Line { file, index } => {
                let text = &self.document.files[file].lines[index].text;
                self.byte_at(row, text, p.x - self.origin.x, y)
            }
            _ => 0,
        };
        Some(Caret { row, byte })
    }

    /// A press at `p` starts a selection there.
    pub fn select_begin(&mut self, p: Point) {
        self.selection = self.caret_at(p).map(|c| (c, c));
    }

    /// A drag to `p` moves the selection's head.
    pub fn select_extend(&mut self, p: Point) {
        if let (Some((anchor, _)), Some(head)) = (self.selection, self.caret_at(p)) {
            self.selection = Some((anchor, head));
        }
    }

    pub fn clear_selection(&mut self) {
        self.selection = None;
    }

    /// A selection that covers text (not a bare click).
    pub fn has_selection(&self) -> bool {
        self.selection.is_some_and(|(a, h)| a != h)
    }

    fn ordered(&self) -> Option<(Caret, Caret)> {
        let (a, h) = self.selection?;
        (a != h).then(|| if a < h { (a, h) } else { (h, a) })
    }

    /// The selected lines' own text, tabs as written, one line per line.
    pub fn selected_text(&self) -> Option<String> {
        let (from, to) = self.ordered()?;
        let mut out = String::new();
        let mut first = true;
        for row in from.row..=to.row {
            let ViewRow::Line { file, index } = self.rows[row] else {
                continue;
            };
            let text = &self.document.files[file].lines[index].text;
            let a = if row == from.row { from.byte } else { 0 };
            let b = if row == to.row { to.byte } else { text.len() };
            if !first {
                out.push('\n');
            }
            first = false;
            out.push_str(&text[a.min(text.len())..b.clamp(a.min(text.len()), text.len())]);
        }
        (!out.is_empty()).then_some(out)
    }

    /// The text of the rows in view, one line per row: the panel driver's (and a future
    /// accessibility element's) reading of the screen.
    pub fn visible_text(&self) -> String {
        let mut out = String::new();
        if self.rows.is_empty() {
            return out;
        }
        let (a, b) = self.rows_in_view();
        for row in a..b {
            let line = match self.rows[row] {
                ViewRow::Header { file } => Some(self.document.files[file].path()),
                ViewRow::Line { file, index } => {
                    Some(self.document.files[file].lines[index].text.as_str())
                }
                ViewRow::Pair { file, old, new } => new
                    .or(old)
                    .map(|i| self.document.files[file].lines[i].text.as_str()),
                ViewRow::Note { .. } | ViewRow::Gap => None,
            };
            if let Some(line) = line {
                out.push_str(line);
                out.push('\n');
            }
        }
        out
    }

    fn rows_in_view(&self) -> (usize, usize) {
        let a = self.row_at(self.top);
        let b = self.row_at(self.top + f64::from(self.size.h)) + 1;
        (a, b.min(self.rows.len()))
    }

    // ---- painting -----------------------------------------------------------------------

    /// The rows in view into `out`, at `origin`: a clip around the view, then file headers,
    /// notes and blocks of lines, marks, the sticky header and the scroll indicator. `note`
    /// words a note in the host's language.
    pub fn paint(
        &mut self,
        colors: &CodeColors,
        decor: &DiffDecor<'_>,
        note: &dyn Fn(FileNote) -> String,
        out: &mut Vec<Op>,
    ) {
        self.used = 0;
        let view = Rect::new(self.origin.x, self.origin.y, self.size.w, self.size.h);
        out.push(Op::PushClip(view));
        if !self.rows.is_empty() {
            let (a, b) = self.rows_in_view();
            let mut row = a;
            while row < b {
                match self.rows[row] {
                    ViewRow::Header { file } => {
                        let y = self.view_y(row);
                        self.paint_header(file, y, colors, decor, out);
                        row += 1;
                    }
                    ViewRow::Note { note: n, .. } => {
                        self.paint_note(row, &note(n), colors, out);
                        row += 1;
                    }
                    ViewRow::Gap => row += 1,
                    ViewRow::Line { .. } | ViewRow::Pair { .. } => {
                        let file = self.rows[row].file().unwrap_or(0);
                        let end = (row..b)
                            .find(|&r| {
                                !matches!(self.rows[r], ViewRow::Line { .. } | ViewRow::Pair { .. })
                                    || self.rows[r].file() != Some(file)
                            })
                            .unwrap_or(b);
                        self.paint_lines(row..end, colors, decor, out);
                        row = end;
                    }
                }
            }
            if self.mode == DiffMode::Split {
                out.push(Op::Rect(RoundedRect::new(
                    Rect::new(
                        self.origin.x + self.size.w / 2.0 - 0.5,
                        self.origin.y,
                        1.0,
                        self.size.h,
                    ),
                    0.0,
                    rgba(colors.palette().border),
                )));
            }
            self.paint_sticky(colors, decor, out);
            if decor.indicator {
                self.paint_indicator(colors, out);
            }
        }
        out.push(Op::PopClip);
    }

    /// Row `row`'s top in the host's points.
    fn view_y(&self, row: usize) -> f32 {
        self.origin.y + (self.offsets[row] - self.top) as f32
    }

    /// A pooled block, emptied, whose rows the last frame's renderer no longer holds.
    fn block(&mut self) -> usize {
        if self.used == self.pool.len() {
            self.pool.push(Arc::new(CodeRows::default()));
        }
        let k = self.used;
        if Arc::get_mut(&mut self.pool[k]).is_none() {
            self.pool[k] = Arc::new(CodeRows::default());
        }
        Arc::get_mut(&mut self.pool[k])
            .expect("a fresh block is unshared")
            .clear();
        self.used += 1;
        k
    }

    fn rows_mut(&mut self, k: usize) -> &mut CodeRows {
        Arc::get_mut(&mut self.pool[k]).expect("a block is unshared while it is filled")
    }

    fn code_op(&self, k: usize, origin: Point, cell: Size) -> Op {
        Op::Code(CodeBlock {
            origin,
            cell,
            font_size: self.metrics.font_size,
            rows: self.pool[k].clone(),
        })
    }

    fn paint_header(
        &mut self,
        file: usize,
        y: f32,
        colors: &CodeColors,
        decor: &DiffDecor<'_>,
        out: &mut Vec<Op>,
    ) {
        let (m, p) = (self.metrics, *colors.palette());
        let (x, w, h) = (self.origin.x, self.size.w, m.header_height);
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(x, y, w, h),
            0.0,
            rgba(p.header),
        )));
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(x, y + h - 1.0, w, 1.0),
            0.0,
            rgba(p.border),
        )));
        if decor.focused == Some(file) {
            let mut ring = RoundedRect::new(
                Rect::new(x + 1.0, y + 1.0, w - 2.0, h - 2.0),
                0.0,
                Rgba::new(0.0, 0.0, 0.0, 0.0),
            );
            ring.border = Some(Border {
                width: 2.0,
                color: decor.accent,
            });
            out.push(Op::Rect(ring));
        }
        let f = &self.document.files[file];
        let changed = &f.changed;
        let chevron = match (f.lines.is_empty(), f.collapsed) {
            (true, _) => '·',
            (false, true) => '▸',
            (false, false) => '▾',
        };
        let (glyph, tone) = match changed.status {
            FileStatus::Added => ('A', p.added_mark),
            FileStatus::Removed => ('D', p.removed_mark),
            FileStatus::Renamed | FileStatus::Copied => ('R', p.line_number),
            _ => ('M', p.line_number),
        };
        let path = match &changed.previous_path {
            Some(old) => format!("{old} → {}", changed.path),
            None => changed.path.clone(),
        };
        let plus = format!("+{}", changed.additions);
        let minus = format!(" −{}", changed.deletions);
        let total = ((w / m.cell.w).floor() as u32).saturating_sub(1);
        let lead = 5; // " ▾ M "
        let tail = columns(&plus) + columns(&minus) + 1;
        let room = total.saturating_sub(lead + tail + 2);
        let path = truncated_head(&path, room);
        let k = self.block();
        let (text, cols) = (&mut self.text, &mut self.cols);
        text.clear();
        write!(text, " {chevron} {glyph} {path}").expect("writing to a String");
        let used = columns(text);
        let pad = total.saturating_sub(used + tail);
        text.extend(std::iter::repeat_n(' ', pad as usize));
        let plus_at = columns(text) as u16;
        text.push_str(&plus);
        let minus_at = columns(text) as u16;
        text.push_str(&minus);
        place(text, cols);
        let end = *cols.last().unwrap_or(&0);
        let rows = Arc::get_mut(&mut self.pool[k]).expect("a block is unshared while it is filled");
        rows.fg = colors.fg();
        rows.push_row(&self.text, &self.cols);
        rows.push_span(1, 2, rgba(p.line_number));
        rows.push_span(3, 4, rgba(tone));
        rows.push_styled_span(5, plus_at, colors.fg(), 1);
        rows.push_span(plus_at, minus_at, rgba(p.added_mark));
        rows.push_span(minus_at, end, rgba(p.removed_mark));
        let op = self.code_op(k, Point::new(x, y), Size::new(m.cell.w, h));
        out.push(op);
    }

    fn paint_note(&mut self, row: usize, text: &str, colors: &CodeColors, out: &mut Vec<Op>) {
        let m = self.metrics;
        let y = self.view_y(row) + (m.note_height - m.note_size * 1.25) / 2.0;
        let x = self.origin.x + self.code_x();
        out.push(Op::Text(TextRun::new(
            text,
            Point::new(x, y),
            m.note_size,
            rgba(colors.palette().line_number),
        )));
    }

    /// Rows `rows` (lines of one file, in view) as blocks: a gutter and code column inline,
    /// two of each side by side.
    fn paint_lines(
        &mut self,
        rows: Range<usize>,
        colors: &CodeColors,
        decor: &DiffDecor<'_>,
        out: &mut Vec<Op>,
    ) {
        let m = self.metrics;
        let y = self.view_y(rows.start);
        let panes: &[(f32, Option<Side>)] = match self.mode {
            DiffMode::Inline => &[(0.0, None)],
            DiffMode::Split => &[(0.0, Some(Side::Old)), (0.5, Some(Side::New))],
        };
        let selection = self.ordered();
        for &(at, side) in panes {
            let x = self.origin.x + self.size.w * at;
            let (gutter, code) = (self.block(), self.block());
            for row in rows.clone() {
                self.fill_row(row, side, (gutter, code), colors, decor, selection);
            }
            let code_x = x + self.code_x();
            let pane_w = match self.mode {
                DiffMode::Inline => self.size.w,
                DiffMode::Split => self.size.w / 2.0,
            };
            out.push(self.code_op(gutter, Point::new(x, y), m.cell));
            out.push(Op::PushClip(Rect::new(
                code_x,
                self.origin.y,
                (x + pane_w - code_x).max(0.0),
                self.size.h,
            )));
            out.push(self.code_op(code, Point::new(code_x - self.left, y), m.cell));
            out.push(Op::PopClip);
        }
        // Marks over the gutter's left edge.
        let k = m.k();
        for row in rows {
            let (file, index) = match self.rows[row] {
                ViewRow::Line { file, index } => (file, Some(index)),
                ViewRow::Pair { file, new, old } => (file, new.or(old)),
                _ => continue,
            };
            if let Some(index) = index
                && decor.marks.binary_search(&(file, index)).is_ok()
            {
                let (top, h) = self.frame(row);
                let y = self.origin.y + (top - self.top) as f32;
                out.push(Op::Rect(RoundedRect::new(
                    Rect::new(self.origin.x, y + 3.0 * k, 3.0 * k, h as f32 - 6.0 * k),
                    0.0,
                    decor.accent,
                )));
            }
        }
    }

    /// One view row into a pane's gutter and code blocks: one block row per visual row.
    fn fill_row(
        &mut self,
        row: usize,
        side: Option<Side>,
        (gutter, code): (usize, usize),
        colors: &CodeColors,
        decor: &DiffDecor<'_>,
        selection: Option<(Caret, Caret)>,
    ) {
        let p = *colors.palette();
        let count = self.visual[row];
        let (file, index) = match (self.rows[row], side) {
            (ViewRow::Line { file, index }, _) => (file, Some(index)),
            (ViewRow::Pair { file, old, .. }, Some(Side::Old)) => (file, old),
            (ViewRow::Pair { file, new, .. }, _) => (file, new),
            _ => return,
        };
        let Some(index) = index else {
            // A side with no line: filler rows.
            let (gutter_cols, fill_cols) = (self.gutter_cols, self.fill_cols());
            for _ in 0..count {
                self.filler(gutter, gutter_cols, rgba(p.gutter));
                self.filler(code, fill_cols, rgba(p.gutter));
            }
            return;
        };
        let f = &self.document.files[file];
        let line = &f.lines[index];
        let kind = line.kind;
        let fill_cols = self.fill_cols();
        let anchored = decor
            .anchor
            .as_ref()
            .is_some_and(|(af, lines)| *af == file && lines.contains(&index));
        let accent_wash = decor.accent.with_alpha(0.16);
        let (wash, word) = match kind {
            LineKind::Added => (Some(p.added_line), p.added_word),
            LineKind::Removed => (Some(p.removed_line), p.removed_word),
            LineKind::Hunk => (Some(p.hunk), p.hunk),
            LineKind::Context | LineKind::Note => (None, p.hunk),
        };
        // Gutter: the numbers on the first visual row, then the ± marker.
        let digits = self.document.digits as usize;
        let (marker, mark, fill) = match kind {
            LineKind::Added => ('+', p.added_mark, p.added_gutter),
            LineKind::Removed => ('−', p.removed_mark, p.removed_gutter),
            LineKind::Hunk => (' ', p.line_number, p.hunk),
            _ => (' ', p.line_number, p.gutter),
        };
        let numbers: &[Option<u32>] = match side {
            None => &[line.old, line.new],
            Some(Side::Old) => &[line.old],
            Some(Side::New) => &[line.new],
        };
        let numbers = if matches!(kind, LineKind::Hunk | LineKind::Note) {
            &[None, None][..numbers.len()]
        } else {
            numbers
        };
        let gutter_cols = self.gutter_cols;
        for visual in 0..count {
            let text = &mut self.text;
            text.clear();
            text.push(' ');
            for n in numbers {
                match (visual, n) {
                    (0, Some(n)) => write!(text, "{n:>digits$} "),
                    _ => write!(text, "{:>digits$} ", ""),
                }
                .expect("writing to a String");
            }
            let at = columns(text) as u16;
            text.push(if visual == 0 { marker } else { ' ' });
            text.push(' ');
            place(text, &mut self.cols);
            let rows = Arc::get_mut(&mut self.pool[gutter]).expect("unshared while filled");
            rows.fg = rgba(p.line_number);
            let r = rows.rows.len() as u32;
            rows.push_row(&self.text, &self.cols);
            rows.push_span(at, at + 1, rgba(mark));
            rows.backgrounds.push(span(r, 0, gutter_cols, rgba(fill)));
            if anchored {
                rows.backgrounds.push(span(r, 0, gutter_cols, accent_wash));
            }
        }
        // Code: the line's chars on their visual rows, coloured by its side's highlights.
        let line_side = match side {
            Some(s) => s,
            None => line.side(),
        };
        let runs = match kind {
            LineKind::Hunk | LineKind::Note => &[][..],
            _ => f
                .source_line(index, line_side)
                .zip(self.tokens[file][side_index(line_side)].as_ref())
                .map_or(&[][..], |(n, t)| t.runs(n as usize)),
        };
        let words = &self.words[file][index];
        let (sel_a, sel_b) = selected_bytes(selection, row, line.text.len());
        let text = line.text.as_str();
        let wrap = self.wrap;
        let first_row = self.pool[code].rows.len() as u32;
        let rows = Arc::get_mut(&mut self.pool[code]).expect("unshared while filled");
        rows.fg = colors.fg();
        let cols = &mut self.cols;
        let byte_cols = &mut self.byte_cols;
        // Each byte's column on its visual row, and where each visual row starts: a char sits
        // on the row its first column falls in, a zero-width one with the char before it.
        byte_cols.clear();
        let mut placer = Placer::new(None);
        let starts = &mut self.starts;
        starts.clear();
        starts.push(0);
        let mut v = 0;
        for (at, c) in text.char_indices() {
            let p = placer.place(c);
            if let Some(w) = wrap
                && p.width > 0
            {
                v = (p.x / w).min(count - 1);
            }
            while starts.len() <= v as usize {
                starts.push(at);
            }
            let x = p.x - wrap.map_or(0, |w| v * w);
            byte_cols.extend(std::iter::repeat_n(
                x.min(u32::from(u16::MAX)) as u16,
                c.len_utf8(),
            ));
        }
        let end_col = |row_end: usize, byte_cols: &[u16], text: &str| -> u16 {
            // A row's end column: one past its last char.
            text[..row_end].char_indices().last().map_or(0, |(at, c)| {
                byte_cols[at] + code_core::width_at(c, u32::from(byte_cols[at])).max(1) as u16
            })
        };
        for v in 0..count as usize {
            let a = starts.get(v).copied().unwrap_or(text.len());
            let b = starts.get(v + 1).copied().unwrap_or(text.len());
            let b = b.max(a);
            cols.clear();
            cols.extend(text[a..b].char_indices().map(|(i, _)| byte_cols[a + i]));
            let end = if b > a {
                end_col(b, byte_cols, text)
            } else {
                0
            };
            cols.push(end);
            let r = first_row + v as u32;
            rows.push_row(&text[a..b], cols);
            let col_of = |byte: usize| -> u16 {
                if byte >= b {
                    end
                } else if byte <= a {
                    if a < b { byte_cols[a] } else { 0 }
                } else {
                    byte_cols[byte]
                }
            };
            if let Some(wash) = wash {
                rows.backgrounds.push(span(r, 0, fill_cols, rgba(wash)));
            }
            for w in words {
                let (x0, x1) = (col_of(w.start.max(a)), col_of(w.end.min(b)));
                if w.start < b && w.end > a && x0 < x1 {
                    rows.backgrounds.push(span(r, x0, x1, rgba(word)));
                }
            }
            if anchored {
                rows.backgrounds.push(span(r, 0, fill_cols, accent_wash));
            }
            // A selection running on past the line's end takes one more cell (its newline).
            if sel_a < sel_b {
                let past = sel_b > text.len() && v + 1 == count as usize && sel_a <= b;
                let (s0, s1) = (sel_a.max(a), sel_b.min(b));
                if s0 < s1 || past {
                    let x0 = col_of(s0.min(b));
                    let x1 = if past { end + 1 } else { col_of(s1) };
                    rows.backgrounds
                        .push(span(r, x0, x1.max(x0 + 1), rgba(p.selection)));
                }
            }
            match kind {
                LineKind::Hunk | LineKind::Note => {
                    rows.push_span(0, end, rgba(p.line_number));
                }
                _ => {
                    for run in runs {
                        let (s, e) = (run.start as usize, (run.start + run.len) as usize);
                        if s < b && e > a {
                            let (x0, x1) = (col_of(s.max(a)), col_of(e.min(b)));
                            if x0 < x1 {
                                rows.push_styled_span(
                                    x0,
                                    x1,
                                    colors.role(run.role),
                                    colors.face(run.role),
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    /// A block row with no text on a fill.
    fn filler(&mut self, k: usize, cols: u16, color: Rgba) {
        let rows = self.rows_mut(k);
        let r = rows.rows.len() as u32;
        rows.push_row("", &[0]);
        rows.backgrounds.push(span(r, 0, cols, color));
    }

    /// Columns a row's wash spans: past every char the view can show.
    fn fill_cols(&self) -> u16 {
        let shown = ((self.size.w + self.left) / self.metrics.cell.w.max(0.1)).ceil() as u32;
        shown.max(self.code_cols).min(u32::from(u16::MAX)) as u16
    }

    /// The header of the file at the top, pushed up by the next file's as it arrives.
    fn paint_sticky(&mut self, colors: &CodeColors, decor: &DiffDecor<'_>, out: &mut Vec<Op>) {
        if let Some((file, y)) = self.sticky() {
            self.paint_header(file, y, colors, decor, out);
        }
    }

    /// The sticky header's file and top, in the host's points.
    fn sticky(&self) -> Option<(usize, f32)> {
        if !self.headers || self.top <= 0.0 {
            return None;
        }
        let file = self.top_file()?;
        let header = self.header_top(file)?;
        if header >= self.top {
            return None;
        }
        let m = self.metrics;
        let next = self
            .header_top(file + 1)
            .map_or(f64::INFINITY, |y| y - self.top);
        let push = (next - f64::from(m.header_height) - f64::from(m.gap_height)).min(0.0);
        Some((file, self.origin.y + push as f32))
    }

    fn sticky_hit(&self, p: Point) -> Option<usize> {
        let (file, y) = self.sticky()?;
        (p.y >= y && p.y < y + self.metrics.header_height).then_some(file)
    }

    fn paint_indicator(&self, colors: &CodeColors, out: &mut Vec<Op>) {
        let (h, total) = (f64::from(self.size.h), self.height());
        if total <= h || h <= 0.0 {
            return;
        }
        let k = self.metrics.k();
        let length = (h * h / total).max(f64::from(24.0 * k));
        let y = self.top / (total - h) * (h - length);
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(
                self.origin.x + self.size.w - 5.0 * k,
                self.origin.y + y as f32,
                3.0 * k,
                length as f32,
            ),
            1.5 * k,
            rgba(colors.palette().line_number).with_alpha(0.45),
        )));
    }
}

fn side_index(side: Side) -> usize {
    match side {
        Side::Old => 0,
        Side::New => 1,
    }
}

fn span(row: u32, start: u16, end: u16, color: Rgba) -> CellSpan {
    CellSpan {
        row,
        start,
        end,
        color,
    }
}

/// Each char of `text`'s column from 0, then the end column, into `cols`.
fn place(text: &str, cols: &mut Vec<u16>) {
    cols.clear();
    let mut placer = Placer::new(None);
    let mut end = 0;
    for c in text.chars() {
        let p = placer.place(c);
        cols.push(p.x.min(u32::from(u16::MAX)) as u16);
        end = (p.x + p.width).min(u32::from(u16::MAX)) as u16;
    }
    cols.push(end);
}

/// The selection's bytes on row `row` (a line of `len` bytes); past `len` when it runs on to
/// the next line, empty when it misses the row.
fn selected_bytes(selection: Option<(Caret, Caret)>, row: usize, len: usize) -> (usize, usize) {
    let Some((from, to)) = selection else {
        return (0, 0);
    };
    if row < from.row || row > to.row {
        return (0, 0);
    }
    let a = if row == from.row { from.byte } else { 0 };
    let b = if row == to.row { to.byte } else { len + 1 };
    (a, b)
}

/// `…/deep/path/file.ts`: the head goes first, the name stays, within `room` columns.
fn truncated_head(text: &str, room: u32) -> std::borrow::Cow<'_, str> {
    if columns(text) <= room || room < 4 {
        return text.into();
    }
    let mut start = 0;
    for (at, _) in text.char_indices() {
        if columns(&text[at..]) < room {
            start = at;
            break;
        }
    }
    format!("…{}", &text[start..]).into()
}

/// A one-file change as a document: what a diff island draws (no header row).
pub fn single_file(path: &str, lines: Vec<DiffLine>) -> DiffDocument {
    use code_core::diff::ChangedFile;
    let (mut additions, mut deletions) = (0, 0);
    for l in &lines {
        additions += u32::from(l.kind == LineKind::Added);
        deletions += u32::from(l.kind == LineKind::Removed);
    }
    let widest = lines
        .iter()
        .flat_map(|l| [l.old, l.new])
        .flatten()
        .max()
        .unwrap_or(0);
    let mut rows = vec![DocRow::Header { file: 0 }];
    let mut cols = vec![0];
    for (index, line) in lines.iter().enumerate() {
        rows.push(DocRow::Line { file: 0, index });
        cols.push(columns(&line.text));
    }
    // Whole-text highlights: each line's place in its side's text is its number.
    let old_fragment = lines.iter().map(|l| l.old.map(|n| n - 1)).collect();
    let new_fragment = lines.iter().map(|l| l.new.map(|n| n - 1)).collect();
    DiffDocument {
        files: vec![DiffFile {
            changed: ChangedFile {
                path: path.to_string(),
                previous_path: None,
                status: FileStatus::Modified,
                additions,
                deletions,
                patch: None,
                trimmed: false,
                old_blob: None,
                new_blob: None,
            },
            language: code_core::Language::from_path(path),
            lines,
            collapsed: false,
            old_fragment,
            new_fragment,
        }],
        rows,
        columns: cols,
        digits: (widest.to_string().len() as u32).max(3),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_core::diff::ChangedFile;
    use std::collections::HashSet;

    fn file(path: &str, patch: &str) -> ChangedFile {
        ChangedFile {
            path: path.into(),
            previous_path: None,
            status: FileStatus::Modified,
            additions: 1,
            deletions: 1,
            patch: Some(patch.into()),
            trimmed: false,
            old_blob: None,
            new_blob: None,
        }
    }

    fn view(files: Vec<ChangedFile>, wraps: bool) -> DiffView {
        let doc = DiffDocument::new(files, false, &HashSet::new());
        let mut v = DiffView::new(doc, DiffMetrics::for_cell(Size::new(7.2, 18.0), 12.0), true);
        v.set_wraps(wraps);
        v.resize(Size::new(800.0, 400.0));
        v
    }

    fn line_row(v: &DiffView, file: usize, index: usize) -> usize {
        v.rows()
            .iter()
            .position(|r| *r == ViewRow::Line { file, index })
            .expect("the line is shown")
    }

    /// The view point over byte `byte` of a line row's first visual row.
    fn point_at(v: &DiffView, row: usize, col: u32) -> Point {
        let (top, _) = v.frame(row);
        let x = v.code_x() + col as f32 * v.metrics().cell.w;
        Point::new(x, (top - v.top()) as f32 + 4.0)
    }

    #[test]
    fn a_long_line_wraps_by_the_diff_rule_and_wrap_keeps_the_readers_line() {
        let long = "x".repeat(250);
        let patch = format!("@@ -1,2 +1,2 @@\n a\n-{long}\n+{long}y");
        let mut v = view(vec![file("a.rs", &patch)], true);
        let row = line_row(&v, 0, 2);
        let cols = v.code_cols();
        assert_eq!(cols, 98);
        let (_, h) = v.frame(row);
        assert_eq!(h, f64::from(250u32.div_ceil(cols)) * 18.0);
        // Scroll to the third line's top, then unwrap: it is still the line at the top.
        v.resize(Size::new(800.0, 10.0));
        let target = line_row(&v, 0, 3);
        v.set_top(v.frame(target).0);
        v.set_wraps(false);
        assert_eq!(v.row_at(v.top()), line_row(&v, 0, 3));
    }

    #[test]
    fn a_selection_across_a_tab_and_a_wide_char_copies_the_text_as_written() {
        let patch = "@@ -1,2 +1,2 @@\n-\tfn 名前() {}\n+\tfn name() {}\n ok";
        let mut v = view(vec![file("a.rs", patch)], false);
        let (first, last) = (line_row(&v, 0, 1), line_row(&v, 0, 3));
        // From inside the tab's columns (nearer its start) to after "ok".
        v.select_begin(point_at(&v, first, 1));
        v.select_extend(point_at(&v, last, 2));
        assert_eq!(
            v.selected_text().as_deref(),
            Some("\tfn 名前() {}\n\tfn name() {}\nok")
        );
        // "名" takes columns 7 and 8: column 8 is its second half, nearer its end.
        v.select_begin(point_at(&v, first, 7));
        v.select_extend(point_at(&v, first, 8));
        assert_eq!(v.selected_text().as_deref(), Some("名"));
    }

    #[test]
    fn the_sticky_header_is_pushed_up_by_the_next_file_and_top_file_follows_files() {
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d";
        let mut v = view(vec![file("a.rs", patch), file("b.rs", patch)], false);
        v.resize(Size::new(800.0, 50.0));
        assert_eq!(v.top_file(), Some(0));
        let m = v.metrics();
        let b_header = v.header_top(1).unwrap();
        // Just past a.rs's header: a.rs sticks at the top.
        v.set_top(f64::from(m.header_height) + 1.0);
        assert_eq!(v.sticky(), Some((0, 0.0)));
        // b.rs's header 30 pt below the top: a.rs's is pushed up to make room for it.
        v.set_top(b_header - 30.0);
        let (file, y) = v.sticky().unwrap();
        assert_eq!(file, 0);
        assert!((y - (30.0 - m.header_height - m.gap_height)).abs() < 1e-3);
        // The gap above b.rs belongs to b.rs.
        v.set_top(b_header - f64::from(m.gap_height) + 1.0);
        assert_eq!(v.top_file(), Some(1));
    }

    #[test]
    fn a_gutter_click_names_the_line_and_a_header_click_the_file() {
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d";
        let v = view(vec![file("a.rs", patch)], false);
        let row = line_row(&v, 0, 3);
        let (top, _) = v.frame(row);
        let gutter = Point::new(10.0, top as f32 + 4.0);
        assert_eq!(v.hit(gutter), DiffHit::Gutter { file: 0, index: 3 });
        assert_eq!(v.hit(Point::new(300.0, 4.0)), DiffHit::Header { file: 0 });
        // The hunk header's gutter starts nothing.
        let hunk = Point::new(10.0, v.frame(line_row(&v, 0, 0)).0 as f32 + 4.0);
        assert_eq!(v.hit(hunk), DiffHit::None);
    }

    #[test]
    fn the_word_under_a_point_is_code_cores_word_past_expanded_tabs() {
        let patch = "@@ -1 +1 @@\n-\tlet total = 1;\n+\tlet grand_total = 1;";
        let v = view(vec![file("a.rs", patch)], false);
        let row = line_row(&v, 0, 2);
        // Columns: the tab takes 0..4, "let " 4..8, "grand_total" from 8.
        assert_eq!(
            v.word_at(point_at(&v, row, 10)),
            Some((0, "grand_total".to_string()))
        );
        assert_eq!(
            search::word_at("\tlet grand_total = 1;", 7),
            Some("grand_total".to_string())
        );
    }

    #[test]
    fn side_by_side_pairs_lines_and_paints_a_gutter_and_code_block_per_side() {
        let patch = "@@ -1,3 +1,2 @@\n a\n-b\n-c\n+C\n d";
        let mut v = view(vec![file("a.rs", patch)], false);
        v.set_mode(DiffMode::Split);
        let pairs: Vec<_> = v
            .rows()
            .iter()
            .filter_map(|r| match *r {
                ViewRow::Pair { old, new, .. } => Some((old, new)),
                _ => None,
            })
            .collect();
        assert_eq!(
            pairs,
            [
                (Some(0), Some(0)),
                (Some(1), Some(1)),
                (Some(2), Some(4)),
                (Some(3), None),
                (Some(5), Some(5))
            ]
        );
        let colors = CodeColors::new(theme::default_theme());
        let decor = DiffDecor {
            accent: Rgba::new(1.0, 0.5, 0.0, 1.0),
            focused: None,
            marks: &[],
            anchor: None,
            indicator: true,
        };
        let mut ops = Vec::new();
        v.paint(&colors, &decor, &|_| String::new(), &mut ops);
        let code = ops.iter().filter(|o| matches!(o, Op::Code(_))).count();
        // The header's row, then a gutter and a code block for each side.
        assert_eq!(code, 1 + 4);
        let rows = ops.iter().find_map(|o| match o {
            Op::Code(c) if c.rows.rows.len() == 5 => Some(c.rows.clone()),
            _ => None,
        });
        assert!(rows.is_some(), "every pair is one block row on each side");
    }

    #[test]
    fn a_steady_repaint_reuses_its_blocks() {
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n+c\n d";
        let mut v = view(vec![file("a.rs", patch)], false);
        let colors = CodeColors::new(theme::default_theme());
        let decor = DiffDecor {
            accent: Rgba::new(1.0, 0.5, 0.0, 1.0),
            focused: Some(0),
            marks: &[(0, 2)],
            anchor: Some((0, 2..=3)),
            indicator: false,
        };
        let mut ops = Vec::new();
        v.paint(&colors, &decor, &|_| String::new(), &mut ops);
        let pool = v.pool.len();
        drop(ops);
        let mut ops = Vec::new();
        v.paint(&colors, &decor, &|_| String::new(), &mut ops);
        assert_eq!(v.pool.len(), pool);
        assert!(
            ops.iter()
                .any(|o| matches!(o, Op::Rect(r) if r.border.is_some()))
        );
    }

    #[test]
    fn reveal_finds_a_new_side_line() {
        let patch = "@@ -10,3 +10,3 @@\n a\n-b\n+c\n d";
        let v = view(vec![file("a.rs", patch)], false);
        assert_eq!(v.line_top(0, 11), Some(v.frame(line_row(&v, 0, 3)).0));
        assert_eq!(v.line_top(0, 99), None);
    }
}
