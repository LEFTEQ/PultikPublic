//! Viewport-first layout: only the rows a [`Viewport`] shows, each with its text and every
//! char's column, built into buffers the [`Layout`] keeps, so a steady frame allocates
//! nothing. Rows follow [`Placer`], the rule the line index counts rows by.

use crate::buffer::{Buffer, TextChunks};
use crate::lines::{LineInfo, MIN_WRAP, Placer};
use ropey::Rope;
use std::ops::Range;

/// What a code view shows: visual rows from `top`, `cols` wide.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Viewport {
    /// The first visual row shown.
    pub top: u64,
    /// How far `top` is scrolled out of view, in pixels: the drawing's offset, carried
    /// along for it; layout does not read it.
    pub offset: f32,
    /// Rows to lay out: every row at least partly visible.
    pub rows: u32,
    /// Columns visible, and the wrap width when `wrap`.
    pub cols: u32,
    pub wrap: bool,
}

impl Viewport {
    /// The wrap the buffer's line index must hold for this viewport.
    pub fn wrap_cols(&self) -> Option<u32> {
        self.wrap.then_some(self.cols.max(MIN_WRAP))
    }
}

/// One laid-out row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub line: usize,
    /// The row within its line: 0 unless the line wraps.
    pub segment: u32,
    /// The row's chars in the buffer, line ending excluded.
    pub bytes: Range<usize>,
    text: Range<usize>,
    cols: Range<usize>,
}

/// The visible rows of one viewport; [`Layout::build`] refills it in place.
#[derive(Debug, Default)]
pub struct Layout {
    rows: Vec<Row>,
    text: String,
    cols: Vec<u16>,
}

impl Layout {
    /// Lay out `vp` over `buf`. The buffer's wrap must be the viewport's
    /// ([`Viewport::wrap_cols`]).
    pub fn build(&mut self, buf: &Buffer, vp: &Viewport) {
        self.rows.clear();
        self.text.clear();
        self.cols.clear();
        let lines = buf.lines();
        assert_eq!(
            lines.wrap(),
            vp.wrap_cols(),
            "the buffer's wrap is not the viewport's"
        );
        if vp.rows == 0 || vp.top >= lines.rows() {
            return;
        }
        let (first, segment) = lines.row_to_line(vp.top);
        for (line, start, info) in lines.lines_from(first) {
            let from = if line == first { segment } else { 0 };
            if !self.line(buf.rope(), vp, line, start, info, from) {
                return;
            }
        }
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    /// The row's chars.
    pub fn text(&self, row: &Row) -> &str {
        &self.text[row.text.clone()]
    }

    /// Each char's column in the row, then the column after the row's last char (0 for a
    /// row without chars): one more entry than the row has chars. A char's width is the
    /// next entry minus its own: 0 for a combining mark, 2 for a wide char, a tab's run.
    pub fn cols(&self, row: &Row) -> &[u16] {
        &self.cols[row.cols.clone()]
    }

    /// Lay out `line`'s rows from segment `from`; false once the viewport is full.
    fn line(
        &mut self,
        rope: &Rope,
        vp: &Viewport,
        line: usize,
        start: usize,
        info: LineInfo<'_>,
        from: u32,
    ) -> bool {
        let wrap = vp.wrap_cols();
        let end = content_end(rope, start, info.bytes);
        let mut placer = Placer::new(wrap);
        let mut row = RowBuild::open(self, line, from, start);
        let mut byte = start;
        'text: for chunk in TextChunks::new(rope, start..end) {
            for (i, c) in chunk.char_indices() {
                let p = placer.place(c);
                if p.row < from {
                    continue;
                }
                let at = byte + i;
                while p.row > row.segment {
                    if !row.close(self, vp) {
                        return false;
                    }
                    row = RowBuild::open(self, line, row.segment + 1, at);
                }
                if wrap.is_none() && p.width > 0 && p.x >= vp.cols {
                    break 'text;
                }
                self.text.push(c);
                self.cols.push(p.x.min(u32::from(u16::MAX)) as u16);
                if !row.chars {
                    (row.start, row.chars) = (at, true);
                }
                row.end = at + c.len_utf8();
                row.end_x = p.x + p.width;
            }
            byte += chunk.len();
        }
        if !row.chars {
            // An empty line, or a row past the line's last char: it sits at the line's end.
            (row.start, row.end) = (end, end);
        }
        // A tab past the last row's end can leave rows with no chars after it.
        let rows = if wrap.is_some() { placer.rows() } else { 1 };
        while row.segment + 1 < rows {
            if !row.close(self, vp) {
                return false;
            }
            row = RowBuild::open(self, line, row.segment + 1, end);
        }
        row.close(self, vp)
    }
}

/// A row being laid out: where its text and columns start, and where its chars lie.
struct RowBuild {
    line: usize,
    segment: u32,
    chars: bool,
    start: usize,
    end: usize,
    end_x: u32,
    text: usize,
    cols: usize,
}

impl RowBuild {
    fn open(layout: &Layout, line: usize, segment: u32, at: usize) -> Self {
        Self {
            line,
            segment,
            chars: false,
            start: at,
            end: at,
            end_x: 0,
            text: layout.text.len(),
            cols: layout.cols.len(),
        }
    }

    /// Push the row; false once the viewport is full.
    fn close(&self, layout: &mut Layout, vp: &Viewport) -> bool {
        layout.cols.push(self.end_x.min(u32::from(u16::MAX)) as u16);
        layout.rows.push(Row {
            line: self.line,
            segment: self.segment,
            bytes: self.start..self.end,
            text: self.text..layout.text.len(),
            cols: self.cols..layout.cols.len(),
        });
        layout.rows.len() < vp.rows as usize
    }
}

/// Where the chars of the line at `start`, `bytes` long, end: before its `\n` or `\r\n`.
pub(crate) fn content_end(rope: &Rope, start: usize, bytes: usize) -> usize {
    let mut end = start + bytes;
    if end > start && rope.byte(end - 1) == b'\n' {
        end -= 1;
        if end > start && rope.byte(end - 1) == b'\r' {
            end -= 1;
        }
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(buf: &mut Buffer, vp: Viewport) -> Vec<(usize, u32, String, Vec<u16>)> {
        buf.set_wrap(vp.wrap_cols());
        let mut layout = Layout::default();
        layout.build(buf, &vp);
        layout
            .rows()
            .iter()
            .map(|r| {
                (
                    r.line,
                    r.segment,
                    layout.text(r).to_owned(),
                    layout.cols(r).to_vec(),
                )
            })
            .collect()
    }

    #[test]
    fn wrapped_rows_start_mid_line_and_tabs_expand() {
        let mut buf = Buffer::from_text("ab\tcdefgh\n\n日x\r\n");
        let vp = Viewport {
            top: 1,
            offset: 0.0,
            rows: 4,
            cols: 4,
            wrap: true,
        };
        assert_eq!(
            rows(&mut buf, vp),
            vec![
                (0, 1, "cdef".into(), vec![0, 1, 2, 3, 4]),
                (0, 2, "gh".into(), vec![0, 1, 2]),
                (1, 0, String::new(), vec![0]),
                (2, 0, "日x".into(), vec![0, 2, 3]),
            ]
        );
        let unwrapped = Viewport {
            top: 0,
            rows: 1,
            wrap: false,
            ..vp
        };
        assert_eq!(
            rows(&mut buf, unwrapped),
            vec![(0, 0, "ab\t".into(), vec![0, 1, 2, 4])],
            "clipped to the visible columns"
        );
    }
}
