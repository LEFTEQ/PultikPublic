//! The aggregate line index: every line's bytes and display width, in chunks of about
//! [`CHUNK`] lines that each cache their visual-row sum for the current wrap.
//!
//! - Lines end at `\n` only, as tree-sitter's rows do; a `\r` before it belongs to the
//!   line ending and has no width.
//! - Columns follow [`width_at`]; how a line wraps follows [`Placer`], and [`wrap_rows`]
//!   counts the same rows from the line's width and its wide chars' columns alone, so a
//!   wrap change recounts every chunk without reading text and the index never disagrees
//!   with the rows layout draws.
//! - Queries walk the chunks' sums, then one chunk: O(chunks + chunk). An [`Edit`]
//!   re-measures only the lines it touched and recounts only their chunk.

use crate::buffer::{Edit, TextChunks};
use ropey::Rope;

/// Tab stops every this many columns, counted from the line's start.
pub const TAB: u32 = 4;
/// The narrowest wrap: a wrap below it wraps at it.
pub const MIN_WRAP: u32 = 4;

/// Lines a chunk is built with. Tests use tiny chunks so small documents cross chunks.
const CHUNK: usize = if cfg!(test) { 4 } else { 1024 };
/// A chunk above this many lines is split, one below the minimum is merged into a neighbour.
const CHUNK_MAX: usize = 2 * CHUNK;
const CHUNK_MIN: usize = CHUNK / 2;
/// The bit of [`Line::width`] marking a line with wide chars: its rows need their columns.
const WIDE: u32 = 1 << 31;

/// Columns `c` takes at logical column `col`: a tab runs to the next stop of [`TAB`], East
/// Asian wide chars and emoji take two, combining marks and other zero-width chars none,
/// everything else one (controls included: they draw as a blank cell).
pub fn width_at(c: char, col: u32) -> u32 {
    match c {
        '\t' => TAB - col % TAB,
        ' '..='~' | '\0'..='\x1f' | '\x7f' => 1,
        c => unicode_width::UnicodeWidthChar::width(c).map_or(1, |w| w.min(2) as u32),
    }
}

/// Rows a line takes wrapped at `cols`: `width` columns, with its wide chars at the logical
/// columns `wides`. The one wrap rule, which [`Placer`] places chars by: a wide char that
/// would straddle a row's end moves whole to the next row and leaves a one-column gap;
/// everything else flows on at its column, so a tab may run past a row's end.
pub fn wrap_rows(width: u32, wides: &[u32], cols: u32) -> u32 {
    let cols = cols.max(MIN_WRAP);
    let mut gap = 0;
    for &col in wides {
        if (col + gap) % cols == cols - 1 {
            gap += 1;
        }
    }
    (width + gap).div_ceil(cols).max(1)
}

/// Where a char lands: its row within the line, its column within that row, and its width.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placed {
    pub row: u32,
    pub x: u32,
    pub width: u32,
}

/// Places one line's chars, in order, on its wrapped rows ([`wrap_rows`]'s rule).
#[derive(Debug, Clone, Copy)]
pub struct Placer {
    /// The row width; `u32::MAX` when the line does not wrap.
    cols: u32,
    /// The next char's logical column (tab stops count these).
    col: u32,
    /// The next char's position in the row stream: the logical column plus the gaps left
    /// by wide chars moved to the next row.
    pos: u32,
    /// The row of the last char with a width: a zero-width char after it joins it there,
    /// even when that char (a tab) ran past the row's end.
    row: u32,
}

impl Placer {
    /// `wrap`: the row width in columns, `None` for one row per line.
    pub fn new(wrap: Option<u32>) -> Self {
        Self {
            cols: wrap.map_or(u32::MAX, |c| c.max(MIN_WRAP)),
            col: 0,
            pos: 0,
            row: 0,
        }
    }

    pub fn place(&mut self, c: char) -> Placed {
        let width = width_at(c, self.col);
        if width == 0 {
            return Placed {
                row: self.row,
                x: self.pos - self.row * self.cols,
                width,
            };
        }
        if width == 2 && c != '\t' && self.pos % self.cols == self.cols - 1 {
            self.pos += 1;
        }
        self.row = self.pos / self.cols;
        let placed = Placed {
            row: self.row,
            x: self.pos - self.row * self.cols,
            width,
        };
        self.pos += width;
        self.col += width;
        placed
    }

    /// Rows the chars placed so far take: for a whole line, what [`wrap_rows`] counts.
    pub fn rows(&self) -> u32 {
        self.pos.div_ceil(self.cols).max(1)
    }
}

/// One line's record: its bytes (line ending included) and its width in columns, whose
/// [`WIDE`] bit marks wide chars.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Line {
    bytes: u32,
    width: u32,
}

/// Lines measured from text, and each wide line's wide-char columns by its index.
#[derive(Debug, Default)]
struct Measured {
    lines: Vec<Line>,
    wides: Vec<(u32, Box<[u32]>)>,
}

/// Measures lines from a stream of text chunks: one pass, ASCII a byte at a time.
#[derive(Default)]
struct Measure {
    width: u32,
    bytes: u32,
    /// The last char was a `\r`: a `\n` next makes it part of the line ending.
    cr: bool,
    wides: Vec<u32>,
}

impl Measure {
    /// Measure `s` into `out`; true once `out` holds `limit` lines (the rest is unread).
    fn feed(&mut self, s: &str, out: &mut Measured, limit: usize) -> bool {
        let b = s.as_bytes();
        let (mut i, mut line_start) = (0, 0);
        while i < b.len() {
            let c = b[i];
            if (0x20..0x7f).contains(&c) {
                self.width += 1;
                self.cr = false;
                i += 1;
                continue;
            }
            match c {
                b'\n' => {
                    if self.cr {
                        self.width -= 1;
                    }
                    i += 1;
                    self.bytes += (i - line_start) as u32;
                    line_start = i;
                    self.finish(out);
                    if out.lines.len() >= limit {
                        return true;
                    }
                }
                b'\t' => {
                    self.width += TAB - self.width % TAB;
                    self.cr = false;
                    i += 1;
                }
                0..0x80 => {
                    self.width += 1;
                    self.cr = c == b'\r';
                    i += 1;
                }
                _ => {
                    let Some(ch) = s[i..].chars().next() else {
                        break;
                    };
                    let w = width_at(ch, self.width);
                    if w == 2 {
                        self.wides.push(self.width);
                    }
                    self.width += w;
                    self.cr = false;
                    i += ch.len_utf8();
                }
            }
        }
        self.bytes += (b.len() - line_start) as u32;
        false
    }

    /// Close the current line into `out`.
    fn finish(&mut self, out: &mut Measured) {
        let mut width = self.width.min(WIDE - 1);
        if !self.wides.is_empty() {
            out.wides
                .push((out.lines.len() as u32, self.wides.as_slice().into()));
            self.wides.clear();
            width |= WIDE;
        }
        out.lines.push(Line {
            bytes: self.bytes,
            width,
        });
        (self.width, self.bytes, self.cr) = (0, 0, false);
    }
}

/// Measure `limit` lines of `rope` from the line starting at byte `from` into `out`, or
/// every line to the end when fewer remain.
fn measure(rope: &Rope, from: usize, limit: usize, out: &mut Measured) {
    out.lines.clear();
    out.wides.clear();
    let mut m = Measure::default();
    for chunk in TextChunks::new(rope, from..rope.len_bytes()) {
        if m.feed(chunk, out, limit) {
            return;
        }
    }
    // The last line, which no `\n` ends (empty after a final `\n`).
    m.finish(out);
}

#[derive(Debug, Default)]
struct Chunk {
    lines: Vec<Line>,
    /// The wide lines' wide-char columns, by index in `lines`, ascending.
    wides: Vec<(u32, Box<[u32]>)>,
    /// Every other line's width, ascending: a wrap change walks only the lines wider than
    /// the wrap, the only ones that take more than a row.
    sorted: Vec<u32>,
    bytes: usize,
    /// Visual rows of every line at the index's wrap.
    rows: u64,
}

/// An edit of at most this many lines keeps a chunk's sorted widths in place; a bigger one
/// sorts them again.
const RESORT_ABOVE: usize = 32;

impl Chunk {
    fn wides_of(&self, i: usize) -> &[u32] {
        match self.wides.binary_search_by_key(&(i as u32), |w| w.0) {
            Ok(k) => &self.wides[k].1,
            Err(_) => &[],
        }
    }

    fn rows_of(&self, i: usize, wrap: Option<u32>) -> u32 {
        let Some(cols) = wrap else { return 1 };
        let w = self.lines[i].width;
        if w & WIDE != 0 {
            wrap_rows(w & !WIDE, self.wides_of(i), cols)
        } else if w <= cols {
            1
        } else {
            w.div_ceil(cols)
        }
    }

    fn recount(&mut self, wrap: Option<u32>) {
        self.bytes = self.lines.iter().map(|l| l.bytes as usize).sum();
        self.recount_rows(wrap);
    }

    /// Sort the widths again from the lines.
    fn resort(&mut self) {
        self.sorted.clear();
        self.sorted.extend(
            self.lines
                .iter()
                .filter(|l| l.width & WIDE == 0)
                .map(|l| l.width),
        );
        self.sorted.sort_unstable();
    }

    /// Rows from the widths alone: no text is read. A line no wider than the wrap is one
    /// row, so only the sorted widths past `cols` and the wide lines are visited.
    fn recount_rows(&mut self, wrap: Option<u32>) {
        let Some(cols) = wrap else {
            self.rows = self.lines.len() as u64;
            return;
        };
        let mut rows = self.sorted.len() as u64;
        let long = self.sorted.partition_point(|&w| w <= cols);
        for &w in &self.sorted[long..] {
            rows += u64::from(w.div_ceil(cols) - 1);
        }
        for (i, wides) in &self.wides {
            rows += u64::from(wrap_rows(
                self.lines[*i as usize].width & !WIDE,
                wides,
                cols,
            ));
        }
        self.rows = rows;
    }

    /// Append `other`'s lines.
    fn absorb(&mut self, other: Chunk) {
        let base = self.lines.len() as u32;
        self.lines.extend_from_slice(&other.lines);
        self.wides
            .extend(other.wides.into_iter().map(|(i, w)| (i + base, w)));
        self.sorted.extend_from_slice(&other.sorted);
        self.sorted.sort_unstable();
        self.bytes += other.bytes;
        self.rows += other.rows;
    }

    /// Split off the lines from `at` on into a new chunk.
    fn split_off(&mut self, at: usize, wrap: Option<u32>) -> Chunk {
        let lines = self.lines.split_off(at);
        let k = self.wides.partition_point(|w| (w.0 as usize) < at);
        let wides = self
            .wides
            .split_off(k)
            .into_iter()
            .map(|(i, w)| (i - at as u32, w))
            .collect();
        let mut tail = Chunk {
            lines,
            wides,
            ..Chunk::default()
        };
        for c in [&mut *self, &mut tail] {
            c.resort();
            c.recount(wrap);
        }
        tail
    }
}

/// One line as the index knows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineInfo<'a> {
    /// Bytes, line ending included.
    pub bytes: usize,
    /// Columns, line ending excluded.
    pub width: u32,
    /// Logical columns of its wide chars (empty for most lines).
    pub wides: &'a [u32],
}

/// Where a line's chunk sits: the chunk, the line's offset in it, and the chunk's first
/// line, byte and visual row.
struct At {
    chunk: usize,
    offset: usize,
    line: usize,
    byte: usize,
    row: u64,
}

/// The aggregate line index of one buffer (see the module docs).
#[derive(Debug)]
pub struct LineIndex {
    /// Never empty: an empty text is one empty line.
    chunks: Vec<Chunk>,
    wrap: Option<u32>,
    lines: usize,
    bytes: usize,
    rows: u64,
    /// Lines an edit measured, kept so a steady edit allocates nothing here.
    scratch: Measured,
}

impl LineIndex {
    /// Index `rope` in one pass over its chunks, unwrapped.
    pub fn new(rope: &Rope) -> Self {
        let mut measured = Measured::default();
        measure(rope, 0, usize::MAX, &mut measured);
        let mut wides = measured.wides.into_iter().peekable();
        let chunks: Vec<Chunk> = measured
            .lines
            .chunks(CHUNK)
            .enumerate()
            .map(|(k, lines)| {
                let (base, end) = ((k * CHUNK) as u32, (k * CHUNK + lines.len()) as u32);
                let mut chunk = Chunk {
                    lines: lines.to_vec(),
                    ..Chunk::default()
                };
                while let Some((i, _)) = wides.peek()
                    && *i < end
                {
                    if let Some((i, w)) = wides.next() {
                        chunk.wides.push((i - base, w));
                    }
                }
                chunk.resort();
                chunk.recount(None);
                chunk
            })
            .collect();
        Self {
            lines: measured.lines.len(),
            bytes: rope.len_bytes(),
            rows: measured.lines.len() as u64,
            chunks,
            wrap: None,
            scratch: Measured::default(),
        }
    }

    pub fn len_lines(&self) -> usize {
        self.lines
    }

    pub fn len_bytes(&self) -> usize {
        self.bytes
    }

    /// Visual rows of the whole text at the current wrap.
    pub fn rows(&self) -> u64 {
        self.rows
    }

    /// The wrap width in columns, `None` for one row per line.
    pub fn wrap(&self) -> Option<u32> {
        self.wrap
    }

    /// Wrap at `cols` (at least [`MIN_WRAP`]), or not at all. Recounts every chunk from the
    /// widths it holds; no text is read.
    pub fn set_wrap(&mut self, cols: Option<u32>) {
        let wrap = cols.map(|c| c.max(MIN_WRAP));
        if wrap == self.wrap {
            return;
        }
        self.wrap = wrap;
        self.rows = 0;
        for c in &mut self.chunks {
            c.recount_rows(wrap);
            self.rows += c.rows;
        }
    }

    fn at_line(&self, line: usize) -> At {
        assert!(
            line < self.lines,
            "line {line} out of bounds ({} lines)",
            self.lines
        );
        let mut at = At {
            chunk: 0,
            offset: 0,
            line: 0,
            byte: 0,
            row: 0,
        };
        for (k, c) in self.chunks.iter().enumerate() {
            if line < at.line + c.lines.len() {
                at.chunk = k;
                at.offset = line - at.line;
                return at;
            }
            at.line += c.lines.len();
            at.byte += c.bytes;
            at.row += c.rows;
        }
        unreachable!("the chunks hold every line")
    }

    pub fn line(&self, line: usize) -> LineInfo<'_> {
        let at = self.at_line(line);
        let c = &self.chunks[at.chunk];
        let l = c.lines[at.offset];
        LineInfo {
            bytes: l.bytes as usize,
            width: l.width & !WIDE,
            wides: c.wides_of(at.offset),
        }
    }

    /// The byte a line starts at.
    pub fn line_to_byte(&self, line: usize) -> usize {
        let at = self.at_line(line);
        let c = &self.chunks[at.chunk];
        at.byte
            + c.lines[..at.offset]
                .iter()
                .map(|l| l.bytes as usize)
                .sum::<usize>()
    }

    /// The line holding `byte` and the byte column in it (tree-sitter's point). The end of
    /// the text is in the last line.
    pub fn byte_to_point(&self, byte: usize) -> (usize, usize) {
        assert!(
            byte <= self.bytes,
            "byte {byte} out of bounds ({} bytes)",
            self.bytes
        );
        let (mut line, mut start) = (0, 0);
        for (k, c) in self.chunks.iter().enumerate() {
            if byte >= start + c.bytes && k + 1 < self.chunks.len() {
                line += c.lines.len();
                start += c.bytes;
                continue;
            }
            for (i, l) in c.lines.iter().enumerate() {
                if byte < start + l.bytes as usize || i + 1 == c.lines.len() {
                    return (line + i, byte - start);
                }
                start += l.bytes as usize;
            }
        }
        unreachable!("the last chunk answers")
    }

    /// Rows `line` takes at the current wrap.
    pub fn line_rows(&self, line: usize) -> u32 {
        let at = self.at_line(line);
        self.chunks[at.chunk].rows_of(at.offset, self.wrap)
    }

    /// The first visual row of `line`.
    pub fn line_to_row(&self, line: usize) -> u64 {
        let at = self.at_line(line);
        let c = &self.chunks[at.chunk];
        if self.wrap.is_none() {
            return at.row + at.offset as u64;
        }
        at.row
            + (0..at.offset)
                .map(|i| u64::from(c.rows_of(i, self.wrap)))
                .sum::<u64>()
    }

    /// The line and segment (its row within the line) of visual row `row`; past the end,
    /// the last row.
    pub fn row_to_line(&self, row: u64) -> (usize, u32) {
        let row = row.min(self.rows.saturating_sub(1));
        let (mut line, mut acc) = (0, 0);
        for c in &self.chunks {
            if row >= acc + c.rows {
                line += c.lines.len();
                acc += c.rows;
                continue;
            }
            if self.wrap.is_none() {
                return (line + (row - acc) as usize, 0);
            }
            for i in 0..c.lines.len() {
                let r = u64::from(c.rows_of(i, self.wrap));
                if row < acc + r {
                    return (line + i, (row - acc) as u32);
                }
                acc += r;
            }
        }
        unreachable!("rows never exceed the chunks' sum")
    }

    /// Every line from `line` on, with the byte it starts at.
    pub fn lines_from(&self, line: usize) -> Lines<'_> {
        let at = self.at_line(line);
        Lines {
            index: self,
            chunk: at.chunk,
            offset: at.offset,
            line,
            byte: self.line_to_byte(line),
        }
    }

    /// Bring the index up to date with `edit`, already applied to `rope`: the lines it
    /// replaced are re-measured from the rope, and only their chunk is recounted.
    pub fn apply(&mut self, edit: &Edit, rope: &Rope) {
        let first = edit.start.point.row;
        let removed = edit.old_end.point.row - first + 1;
        let added = edit.new_end.point.row - first + 1;
        let mut fresh = std::mem::take(&mut self.scratch);
        measure(
            rope,
            edit.start.byte - edit.start.point.column,
            added,
            &mut fresh,
        );
        debug_assert_eq!(fresh.lines.len(), added, "{edit:?}");
        self.splice(first, removed, &mut fresh);
        self.scratch = fresh;
        debug_assert_eq!(self.bytes, rope.len_bytes());
    }

    /// Replace `removed` lines from `first` with `fresh`.
    fn splice(&mut self, first: usize, removed: usize, fresh: &mut Measured) {
        let at = self.at_line(first);
        let (ci, o) = (at.chunk, at.offset);
        // The removed lines may run on into later chunks: take those in first.
        while self.chunks[ci].lines.len() < o + removed {
            let next = self.chunks.remove(ci + 1);
            self.chunks[ci].absorb(next);
        }
        let wrap = self.wrap;
        let c = &mut self.chunks[ci];
        self.bytes -= c.bytes;
        self.rows -= c.rows;
        self.lines = self.lines - removed + fresh.lines.len();
        let end = (o + removed) as u32;
        let added = fresh.lines.len();
        let shift = added as i64 - removed as i64;
        let in_place = removed + added <= RESORT_ABOVE;
        if in_place {
            for l in &c.lines[o..o + removed] {
                if l.width & WIDE == 0 {
                    let k = c.sorted.partition_point(|&w| w < l.width);
                    debug_assert_eq!(c.sorted.get(k), Some(&l.width));
                    c.sorted.remove(k);
                }
            }
            for l in &fresh.lines {
                if l.width & WIDE == 0 {
                    let k = c.sorted.partition_point(|&w| w < l.width);
                    c.sorted.insert(k, l.width);
                }
            }
        }
        c.lines.splice(o..o + removed, fresh.lines.drain(..));
        if !in_place {
            c.resort();
        }
        c.wides.retain(|w| w.0 < o as u32 || w.0 >= end);
        for w in &mut c.wides {
            if w.0 >= end {
                w.0 = (i64::from(w.0) + shift) as u32;
            }
        }
        let k = c.wides.partition_point(|w| (w.0 as usize) < o);
        c.wides
            .splice(k..k, fresh.wides.drain(..).map(|(i, w)| (i + o as u32, w)));
        c.recount(wrap);
        self.bytes += c.bytes;
        self.rows += c.rows;
        self.rebalance(ci);
    }

    /// Keep chunk `ci` between [`CHUNK_MIN`] and [`CHUNK_MAX`] lines; sums move with lines.
    fn rebalance(&mut self, mut ci: usize) {
        let wrap = self.wrap;
        if self.chunks[ci].lines.len() < CHUNK_MIN && self.chunks.len() > 1 {
            if ci + 1 == self.chunks.len() {
                ci -= 1;
            }
            let next = self.chunks.remove(ci + 1);
            self.chunks[ci].absorb(next);
        }
        while self.chunks[ci].lines.len() > CHUNK_MAX {
            let tail = self.chunks[ci].split_off(CHUNK, wrap);
            self.chunks.insert(ci + 1, tail);
            ci += 1;
        }
    }
}

/// Lines in order from one line on: (line, its start byte, its record).
pub struct Lines<'a> {
    index: &'a LineIndex,
    chunk: usize,
    offset: usize,
    line: usize,
    byte: usize,
}

impl<'a> Iterator for Lines<'a> {
    type Item = (usize, usize, LineInfo<'a>);

    fn next(&mut self) -> Option<Self::Item> {
        let mut c = self.index.chunks.get(self.chunk)?;
        while self.offset >= c.lines.len() {
            self.chunk += 1;
            self.offset = 0;
            c = self.index.chunks.get(self.chunk)?;
        }
        let l = c.lines[self.offset];
        let item = (
            self.line,
            self.byte,
            LineInfo {
                bytes: l.bytes as usize,
                width: l.width & !WIDE,
                wides: c.wides_of(self.offset),
            },
        );
        self.offset += 1;
        self.line += 1;
        self.byte += l.bytes as usize;
        Some(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_expand_tabs_and_count_wide_chars_twice() {
        let rope = Rope::from_str("a\tb\r\n日本\t😀e\u{301}\n\r\t\n");
        let ix = LineIndex::new(&rope);
        assert_eq!(ix.len_lines(), 4);
        let widths: Vec<(u32, Vec<u32>)> = (0..4)
            .map(|l| (ix.line(l).width, ix.line(l).wides.to_vec()))
            .collect();
        assert_eq!(
            widths,
            vec![(5, vec![]), (11, vec![0, 2, 8]), (4, vec![]), (0, vec![])],
            "CRLF's \\r has no width; a lone \\r is one column"
        );
        assert_eq!(ix.line(0).bytes, 5);
    }

    #[test]
    fn a_wide_char_never_straddles_a_row_end() {
        // At 4 columns: "abc" then 日 would straddle, so it starts row 1, leaving a gap.
        let mut p = Placer::new(Some(4));
        let placed: Vec<(u32, u32)> = "abc日d"
            .chars()
            .map(|c| p.place(c))
            .map(|p| (p.row, p.x))
            .collect();
        assert_eq!(placed, vec![(0, 0), (0, 1), (0, 2), (1, 0), (1, 2)]);
        assert_eq!(p.rows(), wrap_rows(6, &[3], 4));
        assert_eq!(p.rows(), 2);
    }

    #[test]
    fn a_wrap_change_recounts_rows_without_text() {
        let text = "x".repeat(10) + "\n" + "日".repeat(5).as_str() + "\n\n";
        let mut ix = LineIndex::new(&Rope::from_str(&text));
        assert_eq!(ix.rows(), 4);
        ix.set_wrap(Some(4));
        // 10 columns → 3 rows; five wide chars at 4 columns → two per row → 3 rows.
        assert_eq!(ix.rows(), 3 + 3 + 1 + 1);
        assert_eq!(ix.row_to_line(4), (1, 1));
        assert_eq!(ix.line_to_row(2), 6);
        ix.set_wrap(None);
        assert_eq!(ix.rows(), 4);
    }
}
