//! Selections and where a caret moves in a [`Buffer`] (workbench AC3,
//! `docs/specs/2026-10-15-workbench-editing-decisions.md`).
//!
//! Positions are char indices of the buffer. A caret stops between clusters: a `\r\n` is one
//! step, and zero-width marks stay with the char before them. Columns are the core's display
//! columns ([`width_at`]), which vertical moves keep as a goal. A word is identifier chars
//! ([`is_identifier_char`]) and the marks on them.

use crate::buffer::Buffer;
use crate::layout::content_end;
use crate::lines::width_at;
use crate::search::is_identifier_char;
use std::ops::Range;

/// One selection: `anchor` stays while `head` (the caret) moves. A caret when they are equal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    pub anchor: usize,
    pub head: usize,
    /// The column vertical moves aim for: set by the first up or down from the head's own
    /// column, kept by the ones after it, cleared by every other command.
    pub goal: Option<u32>,
}

impl Selection {
    pub fn caret(at: usize) -> Self {
        Self::new(at, at)
    }

    pub fn new(anchor: usize, head: usize) -> Self {
        Self {
            anchor,
            head,
            goal: None,
        }
    }

    pub fn start(&self) -> usize {
        self.anchor.min(self.head)
    }

    pub fn end(&self) -> usize {
        self.anchor.max(self.head)
    }

    pub fn range(&self) -> Range<usize> {
        self.start()..self.end()
    }

    pub fn is_caret(&self) -> bool {
        self.anchor == self.head
    }

    /// The head before the anchor: selected leftwards or upwards.
    pub fn is_backward(&self) -> bool {
        self.head < self.anchor
    }
}

/// The selections a command applies at: never empty, sorted by start, one of them primary
/// (the one the view follows and ⌘D searches from). Overlapping selections merge, and so do
/// touching ones when either is a caret (two carets at one place, a caret at a selection's
/// edge). Two selections that only touch stay apart, so each `ab` of `abab` stays selected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selections {
    all: Vec<Selection>,
    primary: usize,
}

impl Selections {
    /// `all` sorted (by start, then end, then given order) and merged; `primary` indexes
    /// `all`, and stays primary in whatever it merges into. A merge spans both and takes the
    /// direction of its first selection that is not a caret, and the first one's goal.
    /// Panics when `primary` is out of range.
    pub fn new(all: Vec<Selection>, primary: usize) -> Self {
        assert!(
            primary < all.len(),
            "primary {primary} of {} selections",
            all.len()
        );
        let mut order: Vec<usize> = (0..all.len()).collect();
        order.sort_by_key(|&i| (all[i].start(), all[i].end()));
        let mut merged: Vec<Selection> = Vec::with_capacity(all.len());
        let mut at = 0;
        for i in order {
            let s = all[i];
            match merged.last_mut() {
                Some(m) if touches(m, &s) => *m = merge(*m, s),
                _ => merged.push(s),
            }
            if i == primary {
                at = merged.len() - 1;
            }
        }
        Self {
            all: merged,
            primary: at,
        }
    }

    /// One selection.
    pub fn single(selection: Selection) -> Self {
        Self {
            all: vec![selection],
            primary: 0,
        }
    }

    pub fn all(&self) -> &[Selection] {
        &self.all
    }

    pub fn primary(&self) -> Selection {
        self.all[self.primary]
    }

    pub fn primary_index(&self) -> usize {
        self.primary
    }
}

/// `b` (sorted after `a`) merges into `a`.
fn touches(a: &Selection, b: &Selection) -> bool {
    b.start() < a.end() || (b.start() == a.end() && (a.is_caret() || b.is_caret()))
}

fn merge(a: Selection, b: Selection) -> Selection {
    let (start, end) = (a.start(), a.end().max(b.end()));
    let backward = match a.is_caret() {
        true => b.is_backward(),
        false => a.is_backward(),
    };
    let (anchor, head) = if backward { (end, start) } else { (start, end) };
    Selection {
        anchor,
        head,
        goal: a.goal,
    }
}

fn char_at(buf: &Buffer, at: usize) -> Option<char> {
    let rope = buf.rope();
    (at < rope.len_chars()).then(|| rope.char(at))
}

/// A char with no width of its own (a combining mark, a joiner): it stays with the char
/// before it.
fn is_mark(c: char) -> bool {
    width_at(c, 0) == 0
}

/// A char a word move or ⌘D's word is made of.
pub(crate) fn is_word(c: char) -> bool {
    is_identifier_char(c) || is_mark(c)
}

/// The next caret stop after `at`: past a `\r\n` whole, or one char and the marks on it.
pub(crate) fn next_stop(buf: &Buffer, at: usize) -> usize {
    match (char_at(buf, at), char_at(buf, at + 1)) {
        (None, _) => at,
        (Some('\r'), Some('\n')) => at + 2,
        (Some('\n'), _) => at + 1,
        _ => {
            let mut to = at + 1;
            while char_at(buf, to).is_some_and(is_mark) {
                to += 1;
            }
            to
        }
    }
}

/// The caret stop before `at`: before a `\r\n` whole, or back to the char that carries the
/// marks before `at` (a mark at a line's start stands alone).
pub(crate) fn prev_stop(buf: &Buffer, at: usize) -> usize {
    if at == 0 {
        return 0;
    }
    let mut to = at - 1;
    match char_at(buf, to) {
        Some('\n') => {
            if to > 0 && char_at(buf, to - 1) == Some('\r') {
                to -= 1;
            }
        }
        _ => {
            while to > 0
                && char_at(buf, to).is_some_and(is_mark)
                && char_at(buf, to - 1) != Some('\n')
            {
                to -= 1;
            }
        }
    }
    to
}

/// The line `at` sits on.
pub(crate) fn line_of(buf: &Buffer, at: usize) -> usize {
    buf.pos(at).point.row
}

/// The first char of `line`.
pub(crate) fn line_start(buf: &Buffer, line: usize) -> usize {
    buf.rope().byte_to_char(buf.lines().line_to_byte(line))
}

/// Where `line`'s chars end: before its `\n` or `\r\n`.
pub(crate) fn line_end(buf: &Buffer, line: usize) -> usize {
    let start = buf.lines().line_to_byte(line);
    let end = content_end(buf.rope(), start, buf.lines().line(line).bytes);
    buf.rope().byte_to_char(end)
}

/// The display column of `at` on its line (a caret past the line's chars, inside its
/// `\r\n`, counts as the line's end).
pub(crate) fn column(buf: &Buffer, at: usize) -> u32 {
    let line = line_of(buf, at);
    let start = line_start(buf, line);
    let end = at.min(line_end(buf, line));
    buf.rope()
        .slice(start..end)
        .chars()
        .fold(0, |col, c| col + width_at(c, col))
}

/// The last caret stop on `line` whose column is at most `goal`.
pub(crate) fn at_column(buf: &Buffer, line: usize, goal: u32) -> usize {
    let (start, end) = (line_start(buf, line), line_end(buf, line));
    let mut col = 0;
    let mut at = start;
    for c in buf.rope().slice(start..end).chars() {
        let w = width_at(c, col);
        if col + w > goal {
            break;
        }
        col += w;
        at += 1;
    }
    at
}

/// The start of the word before `at`: back over non-word chars, then over the word.
pub(crate) fn word_left(buf: &Buffer, mut at: usize) -> usize {
    while at > 0 && !char_at(buf, at - 1).is_some_and(is_word) {
        at -= 1;
    }
    while at > 0 && char_at(buf, at - 1).is_some_and(is_word) {
        at -= 1;
    }
    at
}

/// The end of the word after `at`: on over non-word chars, then over the word.
pub(crate) fn word_right(buf: &Buffer, mut at: usize) -> usize {
    let len = buf.rope().len_chars();
    while at < len && !char_at(buf, at).is_some_and(is_word) {
        at += 1;
    }
    while at < len && char_at(buf, at).is_some_and(is_word) {
        at += 1;
    }
    at
}

/// The word `at` sits in or ends: what ⌘D selects from a caret.
pub(crate) fn word_around(buf: &Buffer, at: usize) -> Option<Range<usize>> {
    let (mut start, mut end) = (at, at);
    while start > 0 && char_at(buf, start - 1).is_some_and(is_word) {
        start -= 1;
    }
    while char_at(buf, end).is_some_and(is_word) {
        end += 1;
    }
    (start < end).then_some(start..end)
}

/// The spaces and tabs `at`'s line starts with, up to `at`: what a newline repeats.
pub(crate) fn indent(buf: &Buffer, at: usize) -> String {
    let start = line_start(buf, line_of(buf, at));
    buf.rope()
        .slice(start..at)
        .chars()
        .take_while(|&c| c == ' ' || c == '\t')
        .collect()
}

/// A vertical move of `head` one line up or down to `goal`: off the first line to the
/// text's start, off the last to its end.
pub(crate) fn vertical(buf: &Buffer, head: usize, goal: u32, up: bool) -> usize {
    let line = line_of(buf, head);
    match up {
        true if line == 0 => 0,
        true => at_column(buf, line - 1, goal),
        false if line + 1 == buf.lines().len_lines() => buf.rope().len_chars(),
        false => at_column(buf, line + 1, goal),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sel(anchor: usize, head: usize) -> Selection {
        Selection::new(anchor, head)
    }

    fn ranges(s: &Selections) -> Vec<(usize, usize)> {
        s.all().iter().map(|s| (s.anchor, s.head)).collect()
    }

    #[test]
    fn overlapping_selections_and_carets_at_an_edge_merge_but_touching_ones_do_not() {
        let s = Selections::new(vec![sel(4, 6), sel(0, 2), sel(2, 4), sel(5, 9)], 3);
        assert_eq!(ranges(&s), [(0, 2), (2, 4), (4, 9)]);
        assert_eq!(
            s.primary_index(),
            2,
            "the primary stays primary in its merge"
        );
        let s = Selections::new(vec![sel(3, 3), sel(3, 3), sel(1, 3), sel(7, 7)], 0);
        assert_eq!(ranges(&s), [(1, 3), (7, 7)]);
        assert_eq!(s.primary_index(), 0);
        let s = Selections::new(vec![sel(5, 2), sel(4, 8)], 1);
        assert_eq!(
            ranges(&s),
            [(8, 2)],
            "a merge keeps its first selection's direction"
        );
    }

    #[test]
    fn caret_stops_skip_crlf_and_marks() {
        let b = Buffer::from_text("e\u{301}x\r\n\u{301}y");
        let stops: Vec<usize> = std::iter::successors(Some(0), |&at| {
            let next = next_stop(&b, at);
            (next != at).then_some(next)
        })
        .collect();
        assert_eq!(stops, [0, 2, 3, 5, 6, 7]);
        let back: Vec<usize> = stops.iter().map(|&at| prev_stop(&b, at)).collect();
        assert_eq!(back, [0, 0, 2, 3, 5, 6]);
    }

    #[test]
    fn columns_count_tabs_and_wide_chars() {
        let b = Buffer::from_text("a\tb\n日本x\n");
        assert_eq!([0, 1, 2, 3].map(|at| column(&b, at)), [0, 1, 4, 5]);
        assert_eq!([4, 5, 6, 7].map(|at| column(&b, at)), [0, 2, 4, 5]);
        assert_eq!(
            at_column(&b, 1, 3),
            5,
            "never past the goal: 本 would end at 4"
        );
        assert_eq!(
            at_column(&b, 0, 2),
            1,
            "a tab spanning the goal is not crossed"
        );
        assert_eq!(at_column(&b, 0, 99), 3);
    }

    #[test]
    fn words_are_identifiers() {
        let b = Buffer::from_text("let foo_1 = $bar;\n  café");
        assert_eq!(word_right(&b, 0), 3);
        assert_eq!(word_right(&b, 3), 9);
        assert_eq!(word_right(&b, 9), 16);
        assert_eq!(word_left(&b, 16), 12);
        assert_eq!(word_left(&b, 22), 20);
        assert_eq!(word_around(&b, 9), Some(4..9));
        assert_eq!(word_around(&b, 10), None);
        assert_eq!(indent(&b, 21), "  ");
    }
}
