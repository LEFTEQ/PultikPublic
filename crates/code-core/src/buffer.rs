//! The text: a rope, its line index and a revision, changed only through [`Buffer::edit`]
//! and [`Buffer::edits`].

use crate::lines::LineIndex;
use ropey::Rope;
use std::io;
use std::ops::Range;

/// A rope's text in a byte range, chunk by chunk. ropey's own `Chunks` keeps its node stack
/// on the heap; this finds each chunk with `chunk_at_byte` (O(log n)) and never allocates,
/// which keeps a steady frame allocation-free.
pub struct TextChunks<'a> {
    rope: &'a Rope,
    at: usize,
    end: usize,
}

impl<'a> TextChunks<'a> {
    /// `bytes` must lie on char boundaries within the rope.
    pub fn new(rope: &'a Rope, bytes: Range<usize>) -> Self {
        Self {
            rope,
            at: bytes.start,
            end: bytes.end.min(rope.len_bytes()),
        }
    }
}

impl<'a> Iterator for TextChunks<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        if self.at >= self.end {
            return None;
        }
        let (chunk, start, _, _) = self.rope.chunk_at_byte(self.at);
        let stop = (self.end - start).min(chunk.len());
        let piece = &chunk[self.at - start..stop];
        self.at = start + stop;
        Some(piece)
    }
}

/// A row and a byte column in it: tree-sitter's `Point` (rows split at `\n` only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Point {
    pub row: usize,
    pub column: usize,
}

/// One position in every unit a consumer needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pos {
    pub char: usize,
    pub byte: usize,
    pub point: Point,
}

/// What one edit changed: tree-sitter's `InputEdit` (start, old end, new end as bytes and
/// points), plus the char positions and the lines the edit removed and added (the `\n`s in
/// the replaced and the inserted text).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Edit {
    pub start: Pos,
    pub old_end: Pos,
    pub new_end: Pos,
    pub lines_removed: usize,
    pub lines_added: usize,
    /// The buffer's revision after the edit.
    pub revision: u64,
}

/// A text being edited: a rope, its [`LineIndex`] kept in step, and a revision that every
/// edit bumps.
#[derive(Debug)]
pub struct Buffer {
    rope: Rope,
    lines: LineIndex,
    revision: u64,
}

impl Buffer {
    pub fn from_text(text: &str) -> Self {
        Self::from_rope(Rope::from_str(text))
    }

    /// Read UTF-8 text (invalid UTF-8 is an `InvalidData` error), then index it in one pass.
    pub fn from_reader(reader: impl io::Read) -> io::Result<Self> {
        Ok(Self::from_rope(Rope::from_reader(reader)?))
    }

    fn from_rope(rope: Rope) -> Self {
        Self {
            lines: LineIndex::new(&rope),
            rope,
            revision: 0,
        }
    }

    pub fn rope(&self) -> &Rope {
        &self.rope
    }

    pub fn lines(&self) -> &LineIndex {
        &self.lines
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Wrap the index's rows at `cols`, or not at all ([`LineIndex::set_wrap`]).
    pub fn set_wrap(&mut self, cols: Option<u32>) {
        self.lines.set_wrap(cols);
    }

    /// Char `char` as a [`Pos`].
    pub fn pos(&self, char: usize) -> Pos {
        let byte = self.rope.char_to_byte(char);
        let (row, column) = self.lines.byte_to_point(byte);
        Pos {
            char,
            byte,
            point: Point { row, column },
        }
    }

    /// Replace the chars in `chars` with `text`. Panics when the range is out of bounds.
    pub fn edit(&mut self, chars: Range<usize>, text: &str) -> Edit {
        self.revision += 1;
        self.replace(chars, text)
    }

    /// Make `edits` in turn as one change with one revision: each range reads the text the
    /// edits before it left. The [`Edit`]s come back in the same order and carry the same
    /// revision; replayed in turn (as tree-sitter takes them) they reproduce the change. No
    /// edits leave the revision alone. Panics as [`Buffer::edit`] does.
    pub fn edits<'t>(
        &mut self,
        edits: impl IntoIterator<Item = (Range<usize>, &'t str)>,
    ) -> Vec<Edit> {
        let mut edits = edits.into_iter().peekable();
        if edits.peek().is_some() {
            self.revision += 1;
        }
        edits
            .map(|(chars, text)| self.replace(chars, text))
            .collect()
    }

    /// One replacement at the current revision.
    fn replace(&mut self, chars: Range<usize>, text: &str) -> Edit {
        assert!(
            chars.start <= chars.end && chars.end <= self.rope.len_chars(),
            "edit {chars:?} out of bounds ({} chars)",
            self.rope.len_chars()
        );
        let start = self.pos(chars.start);
        let old_end = self.pos(chars.end);
        if !chars.is_empty() {
            self.rope.remove(chars.clone());
        }
        if !text.is_empty() {
            self.rope.insert(chars.start, text);
        }
        let lines_added = text.bytes().filter(|&b| b == b'\n').count();
        let column = match text.rfind('\n') {
            Some(at) => text.len() - at - 1,
            None => start.point.column + text.len(),
        };
        let edit = Edit {
            start,
            old_end,
            new_end: Pos {
                char: start.char + text.chars().count(),
                byte: start.byte + text.len(),
                point: Point {
                    row: start.point.row + lines_added,
                    column,
                },
            },
            lines_removed: old_end.point.row - start.point.row,
            lines_added,
            revision: self.revision,
        };
        self.lines.apply(&edit, &self.rope);
        edit
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_reports_tree_sitter_points() {
        let mut b = Buffer::from_text("fn a() {\n    b();\n}\n");
        // Replace "b();\n}" (row 1 col 4 .. row 2 col 1) with "c(\nd);".
        let start = b.rope().byte_to_char(13);
        let end = b.rope().byte_to_char(19);
        let e = b.edit(start..end, "c(\nd);");
        assert_eq!(e.start.point, Point { row: 1, column: 4 });
        assert_eq!(e.old_end.point, Point { row: 2, column: 1 });
        assert_eq!(e.new_end.point, Point { row: 2, column: 3 });
        assert_eq!((e.lines_removed, e.lines_added, e.revision), (1, 1, 1));
        assert_eq!(b.rope().to_string(), "fn a() {\n    c(\nd);\n");
        assert_eq!(b.lines().len_lines(), 4);
        assert_eq!(b.lines().line(2).width, 3);
    }

    #[test]
    fn a_batch_of_edits_is_one_revision() {
        let mut b = Buffer::from_text("ab\ncd");
        let e = b.edits([(4..5, "D"), (0..1, "A\n")]);
        assert_eq!(b.rope().to_string(), "A\nb\ncD");
        assert_eq!((b.revision(), e[0].revision, e[1].revision), (1, 1, 1));
        assert_eq!(e[1].new_end.point, Point { row: 1, column: 0 });
        assert!(b.edits([]).is_empty());
        assert_eq!(b.revision(), 1, "no edits, no revision");
    }
}
