//! Code views into the code op: an editor viewport's rows coloured by their syntax spans, and
//! a diff, inline or side by side (workbench WP3, AC2 and AC4). The rows, highlights and diff
//! model are code-core's; the colours and faces are a `crates/theme` theme's, through
//! [`CodeColors`]. Colours tint glyphs by column and never split shaping; a role the theme
//! draws bold or italic picks its face (`code.rs`).

use canvas_draw::{CellSpan, CodeRows, Rgba};
use code_core::diff::{DiffLine, LineKind, Side, SplitRow, TextDiff};
use code_core::syntax::{self, LineTokens, Span};
use code_core::{Layout, Placer, Row};
use std::fmt::Write;
use std::ops::Range;
use theme::{Palette, SyntaxRole, Theme};

fn rgba(c: theme::Rgba) -> Rgba {
    Rgba::new(c.r, c.g, c.b, c.a)
}

/// A theme as the code op draws it: every role's colour and face, and the code surface's
/// palette.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CodeColors {
    roles: [Rgba; SyntaxRole::COUNT],
    faces: [u8; SyntaxRole::COUNT],
    palette: Palette,
}

impl CodeColors {
    pub fn new(theme: &Theme) -> Self {
        Self {
            roles: SyntaxRole::ALL.map(|r| rgba(theme.syntax(r).color)),
            faces: SyntaxRole::ALL.map(|r| {
                let style = theme.syntax(r);
                u8::from(style.bold) | u8::from(style.italic) << 1
            }),
            palette: theme.palette,
        }
    }

    pub fn role(&self, role: SyntaxRole) -> Rgba {
        self.roles[role as usize]
    }

    /// The role's face: a `ColorSpan::style` (0 regular, 1 bold, 2 italic, 3 both).
    pub fn face(&self, role: SyntaxRole) -> u8 {
        self.faces[role as usize]
    }

    /// Text outside every span.
    pub fn fg(&self) -> Rgba {
        rgba(self.palette.foreground)
    }

    pub fn background(&self) -> Rgba {
        rgba(self.palette.background)
    }

    pub fn palette(&self) -> &Palette {
        &self.palette
    }
}

/// One laid-out editor row into `rows`, with its spans (sorted, absolute bytes) coloured and
/// in their faces.
pub fn push_layout_row(
    rows: &mut CodeRows,
    layout: &Layout,
    row: &Row,
    spans: &[Span],
    colors: &CodeColors,
) {
    rows.push_row(layout.text(row), layout.cols(row));
    syntax::row_spans(layout, row, spans, |a, b, role| {
        rows.push_styled_span(a, b, colors.role(role), colors.face(role));
    });
}

/// Rows `rows` of `src` into `dst` (emptied first) as a block of their own: their text, colours,
/// backgrounds and carets, numbered from 0. A long diff draws only the rows in view.
pub fn window(dst: &mut CodeRows, src: &CodeRows, rows: Range<usize>) {
    dst.clear();
    dst.fg = src.fg;
    let rows = rows.start.min(src.rows.len())..rows.end.min(src.rows.len());
    for row in &src.rows[rows.clone()] {
        dst.push_row(src.row_text(row), src.row_cols(row));
        for s in src.row_spans(row) {
            dst.push_styled_span(s.start, s.end, s.color, s.style);
        }
    }
    let (a, z) = (rows.start as u32, rows.end as u32);
    let shifted = |c: &CellSpan| CellSpan {
        row: c.row - a,
        ..*c
    };
    let inside = |c: &&CellSpan| (a..z).contains(&c.row);
    dst.backgrounds
        .extend(src.backgrounds.iter().filter(inside).map(shifted));
    dst.carets
        .extend(src.carets.iter().filter(inside).map(shifted));
}

/// A diff pane: the code column and its gutter, one row each per diff row.
#[derive(Debug, Default)]
pub struct DiffPane {
    pub code: CodeRows,
    pub gutter: CodeRows,
    /// Columns the gutter takes.
    pub gutter_cols: u16,
    cols: Vec<u16>,
    byte_cols: Vec<u16>,
    text: String,
    text_cols: Vec<u16>,
}

impl DiffPane {
    fn clear(&mut self, colors: &CodeColors) {
        self.code.clear();
        self.gutter.clear();
        (self.code.fg, self.gutter.fg) = (colors.fg(), rgba(colors.palette.line_number));
    }

    /// `text`'s chars placed from column 0, clipped at `width` columns, into `cols` (with the
    /// end column), and each byte's column into `byte_cols`; returns the bytes kept.
    fn place(&mut self, text: &str, width: u16) -> usize {
        self.cols.clear();
        self.byte_cols.clear();
        let mut placer = Placer::new(None);
        let (mut kept, mut end) = (0, 0);
        for (at, c) in text.char_indices() {
            let p = placer.place(c);
            if p.width > 0 && p.x >= u32::from(width) {
                break;
            }
            let x = p.x.min(u32::from(u16::MAX)) as u16;
            self.cols.push(x);
            self.byte_cols.extend(std::iter::repeat_n(x, c.len_utf8()));
            (kept, end) = (
                at + c.len_utf8(),
                (p.x + p.width).min(u32::from(u16::MAX)) as u16,
            );
        }
        self.cols.push(end);
        self.byte_cols.push(end);
        kept
    }

    fn col(&self, byte: usize) -> u16 {
        self.byte_cols[byte.min(self.byte_cols.len() - 1)]
    }

    /// One diff line's code row: its text with its syntax runs (bytes from the line's start)
    /// and changed words, on its wash; `None` is a filler row.
    fn line(
        &mut self,
        line: Option<&DiffLine>,
        runs: &[syntax::TokenRun],
        words: &[Range<usize>],
        colors: &CodeColors,
        width: u16,
    ) {
        let p = &colors.palette;
        let row = self.code.rows.len() as u32;
        let band = |color: theme::Rgba| CellSpan {
            row,
            start: 0,
            end: width,
            color: rgba(color),
        };
        let Some(line) = line else {
            self.code.push_row("", &[0]);
            self.code.backgrounds.push(band(p.gutter));
            return;
        };
        let kept = self.place(&line.text, width);
        self.code.push_row(&line.text[..kept], &self.cols);
        let (wash, word) = match line.kind {
            LineKind::Added => (Some(p.added_line), p.added_word),
            LineKind::Removed => (Some(p.removed_line), p.removed_word),
            LineKind::Hunk => (Some(p.hunk), p.hunk),
            LineKind::Context | LineKind::Note => (None, p.hunk),
        };
        if let Some(wash) = wash {
            self.code.backgrounds.push(band(wash));
        }
        for w in words {
            let (a, b) = (self.col(w.start), self.col(w.end));
            if a < b {
                self.code.backgrounds.push(CellSpan {
                    row,
                    start: a,
                    end: b,
                    color: rgba(word),
                });
            }
        }
        match line.kind {
            LineKind::Hunk | LineKind::Note => {
                let end = self.col(kept);
                self.code.push_span(0, end, rgba(p.line_number));
            }
            _ => {
                for r in runs {
                    let (start, end) = (r.start as usize, (r.start + r.len) as usize);
                    let (a, b) = (self.col(start), self.col(end));
                    if start < kept && a < b {
                        self.code
                            .push_styled_span(a, b, colors.role(r.role), colors.face(r.role));
                    }
                }
            }
        }
    }

    /// One gutter row: the numbers given, right-aligned in `digits`, then the ± marker.
    fn gutter(
        &mut self,
        numbers: &[Option<u32>],
        digits: usize,
        kind: Option<LineKind>,
        colors: &CodeColors,
    ) {
        let p = &colors.palette;
        self.text.clear();
        for n in numbers {
            match n {
                Some(n) => write!(self.text, "{n:>digits$} "),
                None => write!(self.text, "{:>digits$} ", ""),
            }
            .expect("writing to a String");
        }
        let (marker, mark, fill) = match kind {
            Some(LineKind::Added) => ('+', p.added_mark, p.added_gutter),
            Some(LineKind::Removed) => ('-', p.removed_mark, p.removed_gutter),
            Some(LineKind::Hunk) => (' ', p.line_number, p.hunk),
            _ => (' ', p.line_number, p.gutter),
        };
        self.text.push(marker);
        self.text.push(' ');
        self.text_cols.clear();
        self.text_cols.extend(0..=self.text.chars().count() as u16);
        let row = self.gutter.rows.len() as u32;
        self.gutter.push_row(&self.text, &self.text_cols);
        let at = (numbers.len() * (digits + 1)) as u16;
        self.gutter.push_span(at, at + 1, rgba(mark));
        self.gutter.backgrounds.push(CellSpan {
            row,
            start: 0,
            end: self.text_cols.len() as u16 - 1,
            color: rgba(fill),
        });
        self.gutter_cols = self.text_cols.len() as u16 - 1;
    }
}

/// The digits the widest gutter number needs (at least 3, as Pultík's gutter).
fn digits(diff: &TextDiff) -> usize {
    let widest = diff
        .lines
        .iter()
        .flat_map(|l| [l.old, l.new])
        .flatten()
        .max()
        .unwrap_or(0);
    widest.to_string().len().max(3)
}

/// A diff line's syntax runs: from the old text's highlights for `Side::Old`, the new's for
/// `Side::New`.
fn runs<'t>(
    line: &DiffLine,
    side: Side,
    old: &'t LineTokens,
    new: &'t LineTokens,
) -> &'t [syntax::TokenRun] {
    match (side, line.source(side)) {
        (Side::Old, Some(n)) => old.runs(n),
        (Side::New, Some(n)) => new.runs(n),
        _ => &[],
    }
}

/// An inline diff into `pane`: every line in order, removed lines from the old text's
/// highlights, the rest from the new's. `width` is the code column's in columns.
pub fn push_inline(
    pane: &mut DiffPane,
    diff: &TextDiff,
    (old, new): (&LineTokens, &LineTokens),
    colors: &CodeColors,
    width: u16,
) {
    pane.clear(colors);
    let digits = digits(diff);
    for (i, line) in diff.lines.iter().enumerate() {
        let runs = runs(line, line.side(), old, new);
        pane.line(Some(line), runs, &diff.words[i], colors, width);
        pane.gutter(&[line.old, line.new], digits, Some(line.kind), colors);
    }
}

/// A side-by-side diff into two panes: one row per split row on each side, a filler where a
/// side has no line, hunk headers and notes across both.
pub fn push_split(
    (left, right): (&mut DiffPane, &mut DiffPane),
    diff: &TextDiff,
    (old, new): (&LineTokens, &LineTokens),
    colors: &CodeColors,
    width: u16,
) {
    left.clear(colors);
    right.clear(colors);
    let digits = digits(diff);
    for row in &diff.split {
        let (o, n) = match *row {
            SplitRow::Hunk(i) | SplitRow::Note(i) => (Some(i), Some(i)),
            SplitRow::Pair { old, new } => (old, new),
        };
        for (pane, index, side) in [(&mut *left, o, Side::Old), (&mut *right, n, Side::New)] {
            let line = index.map(|i| &diff.lines[i]);
            let (runs, words) = match (line, index) {
                (Some(l), Some(i)) => (runs(l, side, old, new), diff.words[i].as_slice()),
                _ => (&[][..], &[][..]),
            };
            pane.line(line, runs, words, colors, width);
            let number = line.and_then(|l| match side {
                Side::Old => l.old,
                Side::New => l.new,
            });
            pane.gutter(&[number], digits, line.map(|l| l.kind), colors);
        }
    }
}
