//! The editor's code view (workbench W2, W3): code-core's viewport-first [`Layout`] over a
//! buffer, the visible lines' highlights, and its rows painted into two reused [`CodeRows`]:
//! the gutter (line numbers and each line's worst diagnostic) and the code (the current line,
//! selections, find matches, the syntax colours and the carets).
//!
//! The editor island draws through it, and `cargo xtask scroll-bench` times exactly this
//! path ([`EditorView::layout`], [`EditorView::highlight`], [`EditorView::paint`]), so the
//! frame gate measures the island's own work. A steady frame allocates nothing: every buffer
//! is refilled in place once the renderer has let go of the last frame's rows.

use crate::code_view::{CodeColors, push_layout_row};
use canvas_draw::{CellSpan, CodeRows, Rgba};
use code_core::syntax::{Span, Syntax, SyntaxError};
use code_core::{Buffer, Layout, Row, Selection, Viewport};
use std::fmt::Write;
use std::ops::Range;
use std::sync::Arc;

/// The fewest digits the gutter keeps for line numbers.
const MIN_DIGITS: usize = 3;
/// What marks a line with a diagnostic in the gutter.
const MARK: char = '●';

/// A gutter mark: a line's worst diagnostic, in its colour.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Mark {
    pub line: usize,
    pub color: Rgba,
}

/// What the view draws over its text this frame.
#[derive(Debug, Default, Clone, Copy)]
pub struct Decor<'a> {
    /// Every selection (a caret where anchor = head), sorted by start.
    pub selections: &'a [Selection],
    /// The primary selection's index: its head's line is the current line.
    pub primary: usize,
    /// Draw the carets (the island is being edited); selections show either way.
    pub carets: bool,
    /// Find matches as char ranges, in order; `current` is drawn over once more.
    pub matches: &'a [Range<usize>],
    pub current: Option<usize>,
    /// Gutter marks, sorted by line.
    pub marks: &'a [Mark],
}

/// One editor viewport over a buffer, and the rows it last painted.
#[derive(Debug)]
pub struct EditorView {
    /// What it shows: the top row, how far that row is scrolled out, rows and columns. The
    /// buffer's wrap must be `view.wrap_cols()`.
    pub view: Viewport,
    layout: Layout,
    spans: Vec<Span>,
    code: Arc<CodeRows>,
    gutter: Arc<CodeRows>,
    digits: usize,
    scratch: String,
    scratch_cols: Vec<u16>,
}

impl Default for EditorView {
    fn default() -> Self {
        Self::new(Viewport {
            top: 0,
            offset: 0.0,
            rows: 0,
            cols: 80,
            wrap: true,
        })
    }
}

/// `rows`' buffers to refill: the Arc's own when the renderer let go of it, else a new one.
fn refill(rows: &mut Arc<CodeRows>) -> &mut CodeRows {
    if Arc::get_mut(rows).is_none() {
        *rows = Arc::new(CodeRows::default());
    }
    let rows = Arc::get_mut(rows).expect("a new Arc is unique");
    rows.clear();
    rows
}

impl EditorView {
    pub fn new(view: Viewport) -> Self {
        Self {
            view,
            layout: Layout::default(),
            spans: Vec::new(),
            code: Arc::new(CodeRows::default()),
            gutter: Arc::new(CodeRows::default()),
            digits: MIN_DIGITS,
            scratch: String::new(),
            scratch_cols: Vec::new(),
        }
    }

    /// Lay out the viewport's rows over `buf` (whose wrap is the viewport's).
    pub fn layout(&mut self, buf: &Buffer) {
        self.layout.build(buf, &self.view);
    }

    /// The rows laid out last.
    pub fn rows(&self) -> &[Row] {
        self.layout.rows()
    }

    /// The layout itself: each row's text and columns.
    pub fn laid_out(&self) -> &Layout {
        &self.layout
    }

    /// The lines the laid-out rows show.
    pub fn lines(&self) -> Range<usize> {
        match (self.layout.rows().first(), self.layout.rows().last()) {
            (Some(first), Some(last)) => first.line..last.line + 1,
            _ => 0..0,
        }
    }

    /// The visible lines' spans from `syntax` (none: plain text).
    pub fn highlight(
        &mut self,
        syntax: Option<&mut Syntax>,
        buf: &Buffer,
    ) -> Result<(), SyntaxError> {
        match syntax {
            Some(syntax) => syntax.highlight(buf, self.lines(), &mut self.spans),
            None => {
                self.spans.clear();
                Ok(())
            }
        }
    }

    /// The visible lines' syntax spans from the last highlight.
    pub fn spans(&self) -> &[Span] {
        &self.spans
    }

    /// The gutter's width in columns: the digits the last line's number needs, a space, the
    /// mark and a space.
    pub fn gutter_cols(&self) -> u16 {
        (self.digits + 3) as u16
    }

    /// The gutter's digits for a buffer of `lines` lines.
    fn digits_for(lines: usize) -> usize {
        let mut digits = 1;
        let mut n = lines.max(1);
        while n >= 10 {
            n /= 10;
            digits += 1;
        }
        digits.max(MIN_DIGITS)
    }

    /// The gutter the next [`EditorView::paint`] makes for `buf`, in columns: the island sizes
    /// its code column from it before laying out.
    pub fn gutter_cols_for(buf: &Buffer) -> u16 {
        (Self::digits_for(buf.lines().len_lines()) + 3) as u16
    }

    /// The gutter's rows, as the last paint left them.
    pub fn gutter(&self) -> &Arc<CodeRows> {
        &self.gutter
    }

    /// The code's rows, as the last paint left them.
    pub fn code(&self) -> &Arc<CodeRows> {
        &self.code
    }

    /// Paint the laid-out rows: the gutter, then the code with `decor` over it.
    pub fn paint(&mut self, buf: &Buffer, colors: &CodeColors, decor: &Decor<'_>) {
        self.digits = Self::digits_for(buf.lines().len_lines());
        let p = *colors.palette();
        let rgba = |c: theme::Rgba| Rgba::new(c.r, c.g, c.b, c.a);
        let rope = buf.rope();
        let current_line = decor
            .selections
            .get(decor.primary)
            .map(|s| buf.lines().byte_to_point(rope.char_to_byte(s.head)).0);

        // The gutter: each line's number on its first row, its mark, the current line's
        // number in the foreground.
        let gutter = refill(&mut self.gutter);
        gutter.fg = rgba(p.line_number);
        let mut marks = decor.marks.iter().peekable();
        for (i, row) in self.layout.rows().iter().enumerate() {
            self.scratch.clear();
            let first = row.segment == 0;
            if first {
                write!(self.scratch, "{:>w$} ", row.line + 1, w = self.digits)
            } else {
                write!(self.scratch, "{:>w$} ", "", w = self.digits)
            }
            .expect("writing to a String");
            while marks.peek().is_some_and(|m| m.line < row.line) {
                marks.next();
            }
            let mark = marks.peek().filter(|m| first && m.line == row.line);
            self.scratch.push(if mark.is_some() { MARK } else { ' ' });
            self.scratch.push(' ');
            self.scratch_cols.clear();
            self.scratch_cols
                .extend(0..=self.scratch.chars().count() as u16);
            gutter.push_row(&self.scratch, &self.scratch_cols);
            let end = self.scratch_cols.len() as u16 - 1;
            gutter.backgrounds.push(CellSpan {
                row: i as u32,
                start: 0,
                end,
                color: rgba(p.gutter),
            });
            if Some(row.line) == current_line && first {
                gutter.push_span(0, self.digits as u16, rgba(p.foreground));
            }
            if let Some(m) = mark {
                let at = self.digits as u16 + 1;
                gutter.push_span(at, at + 1, m.color);
            }
        }

        let code = refill(&mut self.code);
        code.fg = colors.fg();
        let width = self.view.cols as u16;
        for (i, row) in self.layout.rows().iter().enumerate() {
            push_layout_row(code, &self.layout, row, &self.spans, colors);
            if Some(row.line) == current_line {
                code.backgrounds.push(CellSpan {
                    row: i as u32,
                    start: 0,
                    end: width,
                    color: rgba(p.current_line),
                });
            }
        }
        let Some((first, last)) = self.layout.rows().first().zip(self.layout.rows().last()) else {
            return;
        };
        // Only what the rows show: a char range ends before the first row or starts after
        // the last one is skipped by a binary search, so a million carets cost nothing.
        let (shown_from, shown_to) = (
            rope.byte_to_char(first.bytes.start),
            rope.byte_to_char(last.bytes.end),
        );
        let shaded = |code: &mut CodeRows, chars: Range<usize>, color: Rgba| {
            let (b0, b1) = (rope.char_to_byte(chars.start), rope.char_to_byte(chars.end));
            for (i, row) in self.layout.rows().iter().enumerate() {
                if let Some((a, z)) = row_cols(&self.layout, buf, row, b0..b1) {
                    code.backgrounds.push(CellSpan {
                        row: i as u32,
                        start: a,
                        end: z.max(a + u16::from(a == z)),
                        color,
                    });
                }
            }
        };
        let from = decor.matches.partition_point(|m| m.end < shown_from);
        for (k, m) in decor.matches[from..].iter().enumerate() {
            if m.start > shown_to {
                break;
            }
            shaded(code, m.clone(), rgba(p.find_match));
            if decor.current == Some(from + k) {
                shaded(code, m.clone(), rgba(p.find_match));
            }
        }
        let from = decor.selections.partition_point(|s| s.end() < shown_from);
        for s in &decor.selections[from..] {
            if s.start() > shown_to {
                break;
            }
            if !s.is_caret() {
                shaded(code, s.range(), rgba(p.selection));
            }
            if decor.carets
                && let Some((row, col)) = cell_in(&self.layout, buf, s.head)
            {
                code.carets.push(CellSpan {
                    row: row as u32,
                    start: col,
                    end: col,
                    color: rgba(p.cursor),
                });
            }
        }
    }

    /// The visible row and column `char` sits at (a caret's cell), if a row shows it.
    pub fn cell_of(&self, buf: &Buffer, char: usize) -> Option<(usize, u16)> {
        cell_in(&self.layout, buf, char)
    }

    /// The char a click at column `col` of visible row `row` lands before: the nearer edge
    /// of the char under it. Past the rows, the end of the last one.
    pub fn char_at(&self, buf: &Buffer, row: usize, col: f32) -> usize {
        let rows = self.layout.rows();
        let Some(r) = rows.get(row.min(rows.len().saturating_sub(1))) else {
            return 0;
        };
        let cols = self.layout.cols(r);
        let text = self.layout.text(r);
        let past = row >= rows.len();
        let mut k = 0;
        if past {
            k = cols.len() - 1;
        } else {
            while k + 1 < cols.len() {
                let (a, b) = (f32::from(cols[k]), f32::from(cols[k + 1]));
                if col < (a + b) * 0.5 {
                    break;
                }
                k += 1;
            }
        }
        let byte = text.char_indices().nth(k).map_or(text.len(), |(at, _)| at);
        buf.rope().byte_to_char(r.bytes.start + byte)
    }

    /// The columns `bytes` covers on visible row `row` (the row's end counts one column more
    /// when the range runs on past it, as a selected line ending does).
    pub fn span_cols(&self, buf: &Buffer, row: usize, bytes: Range<usize>) -> Option<(u16, u16)> {
        let r = self.layout.rows().get(row)?;
        row_cols(&self.layout, buf, r, bytes)
    }

    /// The last row `view.top` may be: the text's end at the view's bottom.
    pub fn max_top(&self, buf: &Buffer) -> u64 {
        buf.lines()
            .rows()
            .saturating_sub(u64::from(self.view.rows.max(2)) - 2)
    }

    /// Scroll by `dy` points (down positive) with rows `row_h` points tall.
    pub fn scroll(&mut self, buf: &Buffer, dy: f64, row_h: f32) {
        let row_h = f64::from(row_h.max(1.0));
        let max = self.max_top(buf) as f64 * row_h;
        let y = (self.view.top as f64 * row_h + f64::from(self.view.offset) + dy).clamp(0.0, max);
        self.view.top = (y / row_h) as u64;
        self.view.offset = (y - self.view.top as f64 * row_h) as f32;
    }

    /// Scroll as little as keeps `char`'s row `margin` rows inside the view.
    pub fn reveal(&mut self, buf: &Buffer, char: usize, margin: u64) {
        let byte = buf.rope().char_to_byte(char.min(buf.rope().len_chars()));
        let (line, column) = buf.lines().byte_to_point(byte);
        let lines = buf.lines();
        // The row inside a wrapped line: count its segments' bytes up to the column.
        let mut row = lines.line_to_row(line);
        if lines.line_rows(line) > 1 {
            row += self.segment_of(buf, line, column);
        }
        let visible = u64::from(self.view.rows.saturating_sub(1)).max(1);
        let margin = margin.min(visible / 2);
        if row < self.view.top + margin {
            self.view.top = row.saturating_sub(margin);
            self.view.offset = 0.0;
        } else if row + margin >= self.view.top + visible {
            self.view.top = (row + margin + 1).saturating_sub(visible);
            self.view.offset = 0.0;
        }
    }

    /// Which wrapped segment of `line` byte column `column` falls in.
    fn segment_of(&self, buf: &Buffer, line: usize, column: usize) -> u64 {
        let start = buf.lines().line_to_byte(line);
        let mut placer = code_core::Placer::new(self.view.wrap_cols());
        let slice = buf.rope().byte_slice(start..start + column);
        let mut segment = 0;
        for c in slice.chars() {
            let placed = placer.place(c);
            segment = placed.row;
        }
        u64::from(segment)
    }
}

/// The visible row and column `char` sits at in `layout`.
fn cell_in(layout: &Layout, buf: &Buffer, char: usize) -> Option<(usize, u16)> {
    let byte = buf.rope().char_to_byte(char.min(buf.rope().len_chars()));
    let (line, _) = buf.lines().byte_to_point(byte);
    let rows = layout.rows();
    let lines = buf.lines();
    let i = rows.iter().position(|r| {
        r.line == line
            && (r.bytes.contains(&byte)
                || (byte == r.bytes.end && r.segment + 1 >= lines.line_rows(line)))
    })?;
    let row = &rows[i];
    let k = layout.text(row)[..byte - row.bytes.start].chars().count();
    Some((i, layout.cols(row)[k]))
}

/// The columns `bytes` covers on `row`, if it touches it; the row's end counts one column
/// more when the range runs past its last segment (a selected line ending).
fn row_cols(layout: &Layout, buf: &Buffer, row: &Row, bytes: Range<usize>) -> Option<(u16, u16)> {
    let (rs, re) = (row.bytes.start, row.bytes.end);
    let last_segment = row.segment + 1 >= buf.lines().line_rows(row.line);
    let touches = bytes.start < re
        || (bytes.start == re && (bytes.end > re || bytes.is_empty()) && last_segment);
    if bytes.end < rs || (bytes.end == rs && !bytes.is_empty()) || !touches {
        return None;
    }
    let text = layout.text(row);
    let cols = layout.cols(row);
    let col = |byte: usize| cols[text[..byte - rs].chars().count()];
    let a = col(bytes.start.clamp(rs, re));
    let z = col(bytes.end.clamp(rs, re));
    let past = bytes.end > re && last_segment;
    Some((a, z + u16::from(past)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_core::Editor;

    fn view(buf: &mut Buffer, cols: u32, rows: u32) -> EditorView {
        let mut v = EditorView::new(Viewport {
            top: 0,
            offset: 0.0,
            rows,
            cols,
            wrap: true,
        });
        buf.set_wrap(v.view.wrap_cols());
        v.layout(buf);
        v
    }

    #[test]
    fn it_paints_numbers_marks_the_current_line_selections_and_carets() {
        let mut ed = Editor::from_text("fn main() {\n    let x = 1;\n}\n");
        ed.set_wrap(Some(40));
        let buf = ed.buffer();
        let mut v = EditorView::new(Viewport {
            top: 0,
            offset: 0.0,
            rows: 10,
            cols: 40,
            wrap: true,
        });
        v.layout(buf);
        let colors = CodeColors::new(theme::default_theme());
        // A caret in `let` and a selection over `x`.
        let sel = [Selection::caret(16), Selection::new(20, 21)];
        let marks = [Mark {
            line: 1,
            color: Rgba::WHITE,
        }];
        v.paint(
            buf,
            &colors,
            &Decor {
                selections: &sel,
                primary: 0,
                carets: true,
                marks: &marks,
                ..Decor::default()
            },
        );
        let g = v.gutter();
        assert_eq!(g.row_text(&g.rows[0]), "  1   ");
        assert_eq!(g.row_text(&g.rows[1]), format!("  2 {MARK} "));
        assert_eq!(v.gutter_cols(), 6);
        let c = v.code();
        assert_eq!(c.row_text(&c.rows[1]), "    let x = 1;");
        let current = rgba(colors.palette().current_line);
        assert!(
            c.backgrounds
                .iter()
                .any(|b| b.row == 1 && b.color == current && b.end == 40),
            "the caret's line is the current line"
        );
        let selection = rgba(colors.palette().selection);
        assert!(
            c.backgrounds
                .iter()
                .any(|b| b.row == 1 && b.color == selection && (b.start, b.end) == (8, 9))
        );
        let carets: Vec<(u32, u16)> = c.carets.iter().map(|k| (k.row, k.start)).collect();
        assert_eq!(carets, vec![(1, 4), (1, 9)]);
    }

    fn rgba(c: theme::Rgba) -> Rgba {
        Rgba::new(c.r, c.g, c.b, c.a)
    }

    #[test]
    fn clicks_land_between_chars_and_reveal_scrolls_a_wrapped_line_in() {
        let text = format!("{}\n{}\n", "a".repeat(30), "b\n".repeat(50));
        let mut buf = Buffer::from_text(&text);
        let mut v = view(&mut buf, 12, 5);
        // Row 1 is the long line's second segment (12 columns wide).
        assert_eq!(v.char_at(&buf, 1, 2.4), 14);
        assert_eq!(v.char_at(&buf, 1, 2.6), 15);
        assert_eq!(v.cell_of(&buf, 14), Some((1, 2)));
        // A line ending clicked past: the end of its row.
        assert_eq!(v.char_at(&buf, 3, 50.0), 32);
        v.reveal(&buf, buf.rope().len_chars(), 1);
        v.layout(&buf);
        assert!(v.lines().end >= buf.lines().len_lines() - 1);
        v.reveal(&buf, 25, 0);
        v.layout(&buf);
        assert_eq!(v.view.top, 2, "the third segment of the first line");
    }
}
