//! The editing model (workbench AC3, `docs/specs/2026-10-15-workbench-editing-decisions.md`):
//! an [`Editor`] owns a [`Buffer`], its [`Selections`] and a [`History`]. A [`Command`] applies
//! at every selection at once, back to front so earlier offsets stay valid, and returns the
//! [`Edit`]s it made in the order it made them (one buffer revision per command), so syntax
//! reparses incrementally. Undo and redo restore the text and the selections exactly.

use crate::buffer::{Buffer, Edit};
use crate::cursor::{self, Selection, Selections};
use crate::search_replace::find_literal;
use std::collections::VecDeque;
use std::ops::Range;

/// What a key or menu item asks of the editor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command<'a> {
    /// Type `text` over every selection; each caret lands after its copy.
    Insert(&'a str),
    /// The buffer's line ending plus the indentation of the caret's line before it.
    Newline,
    /// The selection, or the caret stop before a caret.
    DeleteBackward,
    /// The selection, or the caret stop after a caret.
    DeleteForward,
    /// Move every head; `extend` (shift) keeps the anchors.
    Move {
        motion: Motion,
        extend: bool,
    },
    /// A caret on the line above (below) each head, at its goal column; the one added from
    /// the primary becomes primary.
    AddCaretAbove,
    AddCaretBelow,
    /// ⌘D: from a caret, select the word around it; from a selection, add the next
    /// occurrence of its text after it (wrapping) that overlaps no selection, as primary.
    SelectNextOccurrence,
    /// Every occurrence of the primary's text (or its word) becomes a selection.
    SelectAllOccurrences,
    SelectAll,
    /// Keep only the primary selection.
    CollapseToPrimary,
    Undo,
    Redo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Motion {
    /// Without `extend`, a selection collapses to its start (end) instead.
    Left,
    Right,
    /// Off the first (last) line to the text's start (end).
    Up,
    Down,
    LineStart,
    /// Before the line ending.
    LineEnd,
    /// Back over non-word chars, then to the word's start.
    WordLeft,
    /// On over non-word chars, then to the word's end.
    WordRight,
}

/// A text being edited at one or more selections, with its undo history.
#[derive(Debug)]
pub struct Editor {
    buffer: Buffer,
    selections: Selections,
    history: History,
    /// What a newline inserts: the first line's ending.
    line_ending: &'static str,
}

impl Editor {
    /// `buffer` with a caret at its start. A newline inserts `\r\n` when the first line ends
    /// in one, `\n` otherwise.
    pub fn new(buffer: Buffer) -> Self {
        let lines = buffer.lines();
        let first = lines.line(0).bytes;
        let crlf = lines.len_lines() > 1 && first >= 2 && buffer.rope().byte(first - 2) == b'\r';
        Self {
            buffer,
            selections: Selections::single(Selection::caret(0)),
            history: History::default(),
            line_ending: if crlf { "\r\n" } else { "\n" },
        }
    }

    pub fn from_text(text: &str) -> Self {
        Self::new(Buffer::from_text(text))
    }

    pub fn buffer(&self) -> &Buffer {
        &self.buffer
    }

    pub fn selections(&self) -> &Selections {
        &self.selections
    }

    pub fn history(&self) -> &History {
        &self.history
    }

    /// Replace the selections (a click, a drag, a find result). Panics when one lies past
    /// the text.
    pub fn set_selections(&mut self, selections: Selections) {
        let len = self.buffer.rope().len_chars();
        assert!(
            selections.all().iter().all(|s| s.end() <= len),
            "selections past the text ({len} chars)"
        );
        self.history.seal();
        self.selections = selections;
    }

    /// Wrap the buffer's rows at `cols`, or not at all.
    pub fn set_wrap(&mut self, cols: Option<u32>) {
        self.buffer.set_wrap(cols);
    }

    /// Run `command`: the edits it made, in order (none for a move).
    pub fn apply(&mut self, command: Command<'_>) -> Vec<Edit> {
        let all_carets = self.selections.all().iter().all(Selection::is_caret);
        match command {
            Command::Insert(text) => {
                let typing = text.chars().count() == 1 && text != "\n";
                self.replace_each(typing.then_some(Run::Typing), |_, s| {
                    (s.range(), text.to_owned())
                })
            }
            Command::Newline => {
                let ending = self.line_ending;
                self.replace_each(None, |buf, s| {
                    let indent = cursor::indent(buf, s.start());
                    (s.range(), format!("{ending}{indent}"))
                })
            }
            Command::DeleteBackward => {
                self.replace_each(all_carets.then_some(Run::DeleteBackward), |buf, s| match s
                    .is_caret()
                {
                    true => (cursor::prev_stop(buf, s.head)..s.head, String::new()),
                    false => (s.range(), String::new()),
                })
            }
            Command::DeleteForward => {
                self.replace_each(all_carets.then_some(Run::DeleteForward), |buf, s| {
                    match s.is_caret() {
                        true => (s.head..cursor::next_stop(buf, s.head), String::new()),
                        false => (s.range(), String::new()),
                    }
                })
            }
            Command::Move { motion, extend } => {
                let buf = &self.buffer;
                let moved = self
                    .selections
                    .all()
                    .iter()
                    .map(|s| moved(buf, s, motion, extend))
                    .collect();
                self.select(moved, self.selections.primary_index());
                Vec::new()
            }
            Command::AddCaretAbove => self.add_carets(true),
            Command::AddCaretBelow => self.add_carets(false),
            Command::SelectNextOccurrence => self.select_next(),
            Command::SelectAllOccurrences => self.select_occurrences(),
            Command::SelectAll => {
                let len = self.buffer.rope().len_chars();
                self.select(vec![Selection::new(0, len)], 0);
                Vec::new()
            }
            Command::CollapseToPrimary => {
                self.select(vec![self.selections.primary()], 0);
                Vec::new()
            }
            Command::Undo => self.undo(),
            Command::Redo => self.redo(),
        }
    }

    /// A command that changes no text: it seals the history's open run.
    fn select(&mut self, all: Vec<Selection>, primary: usize) {
        self.history.seal();
        self.selections = Selections::new(all, primary);
    }

    /// One change per selection (overlapping ones merge); each caret lands after its
    /// change's text.
    fn replace_each(
        &mut self,
        run: Option<Run>,
        target: impl Fn(&Buffer, &Selection) -> (Range<usize>, String),
    ) -> Vec<Edit> {
        let targets: Vec<(Range<usize>, String)> = self
            .selections
            .all()
            .iter()
            .map(|s| target(&self.buffer, s))
            .collect();
        let mut order: Vec<usize> = (0..targets.len()).collect();
        order.sort_by_key(|&i| targets[i].0.start);
        let mut changes: Vec<Change> = Vec::with_capacity(targets.len());
        let mut owner = vec![0; targets.len()];
        for i in order {
            let (range, text) = &targets[i];
            match changes.last_mut() {
                Some(c) if range.start < c.range.end => {
                    c.range.end = c.range.end.max(range.end);
                    c.text.push_str(text);
                }
                _ => changes.push(Change {
                    range: range.clone(),
                    text: text.clone(),
                }),
            }
            owner[i] = changes.len() - 1;
        }
        let primary = self.selections.primary_index();
        self.transact(run, changes, |_, spans| {
            let carets = owner.iter().map(|&k| Selection::caret(spans[k].end));
            Selections::new(carets.collect(), primary)
        })
    }

    /// Make `changes` (sorted by start, never overlapping; ranges in the text before them)
    /// back to front as one transaction, then place the selections from each change's span
    /// in the new text. Empty changes (an empty range, no text) are dropped; when none is
    /// left, nothing happens at all, and an open run stays open.
    pub(crate) fn transact(
        &mut self,
        run: Option<Run>,
        changes: Vec<Change>,
        place: impl FnOnce(&Buffer, &[Range<usize>]) -> Selections,
    ) -> Vec<Edit> {
        let rope = self.buffer.rope();
        let mut spans = Vec::with_capacity(changes.len());
        let mut steps = Vec::with_capacity(changes.len());
        let (mut added, mut removed) = (0, 0);
        for c in changes {
            let inserted = c.text.chars().count();
            let start = c.range.start - removed + added;
            spans.push(start..start + inserted);
            (added, removed) = (added + inserted, removed + c.range.len());
            if !c.range.is_empty() || inserted > 0 {
                steps.push(Step {
                    at: c.range.start,
                    removed: rope.slice(c.range.clone()).to_string(),
                    removed_chars: c.range.len(),
                    inserted: c.text,
                    inserted_chars: inserted,
                });
            }
        }
        if steps.is_empty() {
            return Vec::new();
        }
        steps.reverse();
        let before = self.selections.clone();
        let edits = self.buffer.edits(steps.iter().map(Step::redo));
        self.selections = place(&self.buffer, &spans);
        self.history.record(
            Transaction {
                steps,
                before,
                after: self.selections.clone(),
            },
            run,
        );
        edits
    }

    fn add_carets(&mut self, up: bool) -> Vec<Edit> {
        let buf = &self.buffer;
        let lines = buf.lines().len_lines();
        let mut all = self.selections.all().to_vec();
        let mut primary = self.selections.primary_index();
        for (i, s) in self.selections.all().iter().enumerate() {
            let line = cursor::line_of(buf, s.head);
            let target = match up {
                true => line.checked_sub(1),
                false => (line + 1 < lines).then_some(line + 1),
            };
            let Some(target) = target else { continue };
            let goal = s.goal.unwrap_or_else(|| cursor::column(buf, s.head));
            let at = cursor::at_column(buf, target, goal);
            if i == self.selections.primary_index() {
                primary = all.len();
            }
            all.push(Selection {
                goal: Some(goal),
                ..Selection::caret(at)
            });
        }
        self.select(all, primary);
        Vec::new()
    }

    fn select_next(&mut self) -> Vec<Edit> {
        let p = self.selections.primary();
        let mut all = self.selections.all().to_vec();
        let primary = match p.is_caret() {
            true => match cursor::word_around(&self.buffer, p.head) {
                Some(word) => {
                    let i = self.selections.primary_index();
                    all[i] = Selection::new(word.start, word.end);
                    i
                }
                None => return self.unchanged(),
            },
            false => match self.next_free_occurrence(p.range()) {
                Some(found) => {
                    all.push(Selection::new(found.start, found.end));
                    all.len() - 1
                }
                None => return self.unchanged(),
            },
        };
        self.select(all, primary);
        Vec::new()
    }

    /// The first occurrence of `range`'s text after it, wrapping round to the text's start,
    /// that overlaps no selection.
    fn next_free_occurrence(&self, range: Range<usize>) -> Option<Range<usize>> {
        let rope = self.buffer.rope();
        let needle = rope.slice(range.clone()).to_string();
        let first = needle.chars().next().map_or(1, char::len_utf8);
        let (from, total) = (rope.char_to_byte(range.end), rope.len_bytes());
        let taken = |r: &Range<usize>| {
            self.selections
                .all()
                .iter()
                .any(|s| r.start < s.end() && s.start() < r.end)
        };
        for (mut at, stop) in [(from, total), (0, from)] {
            while let Some(found) = find_literal(rope, &needle, at..total) {
                if found >= stop {
                    break;
                }
                let r = rope.byte_to_char(found)..rope.byte_to_char(found + needle.len());
                if !taken(&r) {
                    return Some(r);
                }
                at = found + first;
            }
        }
        None
    }

    fn select_occurrences(&mut self) -> Vec<Edit> {
        let p = self.selections.primary();
        let range = match p.is_caret() {
            true => match cursor::word_around(&self.buffer, p.head) {
                Some(word) => word,
                None => return self.unchanged(),
            },
            false => p.range(),
        };
        let rope = self.buffer.rope();
        let needle = rope.slice(range.clone()).to_string();
        let (mut all, mut primary, mut at) = (Vec::new(), 0, 0);
        while let Some(found) = find_literal(rope, &needle, at..rope.len_bytes()) {
            let r = rope.byte_to_char(found)..rope.byte_to_char(found + needle.len());
            if r.start <= range.start {
                primary = all.len();
            }
            all.push(Selection::new(r.start, r.end));
            at = found + needle.len();
        }
        self.select(all, primary);
        Vec::new()
    }

    /// A selection command with nothing to select still ends the open run.
    fn unchanged(&mut self) -> Vec<Edit> {
        self.history.seal();
        Vec::new()
    }

    fn undo(&mut self) -> Vec<Edit> {
        self.history.seal();
        let Some(t) = self.history.undo.pop_back() else {
            return Vec::new();
        };
        let edits = self.buffer.edits(t.steps.iter().rev().map(Step::undo));
        self.selections = t.before.clone();
        self.history.redo.push(t);
        edits
    }

    fn redo(&mut self) -> Vec<Edit> {
        self.history.seal();
        let Some(t) = self.history.redo.pop() else {
            return Vec::new();
        };
        let edits = self.buffer.edits(t.steps.iter().map(Step::redo));
        self.selections = t.after.clone();
        self.history.undo.push_back(t);
        edits
    }
}

/// Where a selection's head goes for `motion`.
fn moved(buf: &Buffer, s: &Selection, motion: Motion, extend: bool) -> Selection {
    let (head, goal) = match motion {
        Motion::Left if !extend && !s.is_caret() => return Selection::caret(s.start()),
        Motion::Right if !extend && !s.is_caret() => return Selection::caret(s.end()),
        Motion::Left => (cursor::prev_stop(buf, s.head), None),
        Motion::Right => (cursor::next_stop(buf, s.head), None),
        Motion::Up | Motion::Down => {
            let goal = s.goal.unwrap_or_else(|| cursor::column(buf, s.head));
            let up = motion == Motion::Up;
            (cursor::vertical(buf, s.head, goal, up), Some(goal))
        }
        Motion::LineStart => (cursor::line_start(buf, cursor::line_of(buf, s.head)), None),
        Motion::LineEnd => (cursor::line_end(buf, cursor::line_of(buf, s.head)), None),
        Motion::WordLeft => (cursor::word_left(buf, s.head), None),
        Motion::WordRight => (cursor::word_right(buf, s.head), None),
    };
    Selection {
        anchor: if extend { s.anchor } else { head },
        head,
        goal,
    }
}

/// One replacement a command makes: chars `range` of the text before it become `text`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Change {
    pub range: Range<usize>,
    pub text: String,
}

/// The runs of small commands that coalesce into one transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Run {
    /// One char typed at every selection.
    Typing,
    /// Backspace at carets only.
    DeleteBackward,
    /// Forward delete at carets only.
    DeleteForward,
}

/// One edit of a transaction, with what it removed, so it can be undone and redone.
#[derive(Debug)]
struct Step {
    /// The char it starts at, in the text the steps before it left.
    at: usize,
    removed: String,
    removed_chars: usize,
    inserted: String,
    inserted_chars: usize,
}

impl Step {
    fn redo(&self) -> (Range<usize>, &str) {
        (self.at..self.at + self.removed_chars, &self.inserted)
    }

    fn undo(&self) -> (Range<usize>, &str) {
        (self.at..self.at + self.inserted_chars, &self.removed)
    }
}

/// What one command (or one coalesced run) did: its steps in order, and the selections
/// before and after it.
#[derive(Debug)]
struct Transaction {
    steps: Vec<Step>,
    before: Selections,
    after: Selections,
}

/// The undo and redo stacks: one transaction per command, except that consecutive typing,
/// backspaces or forward deletes coalesce until any other command (a move included). A new
/// edit drops the redo stack; past [`History::LIMIT`] transactions the oldest goes.
#[derive(Debug, Default)]
pub struct History {
    undo: VecDeque<Transaction>,
    redo: Vec<Transaction>,
    /// The run the newest transaction still takes in.
    open: Option<Run>,
}

impl History {
    pub const LIMIT: usize = 1000;

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Transactions on the undo stack.
    pub fn undo_depth(&self) -> usize {
        self.undo.len()
    }

    fn record(&mut self, t: Transaction, run: Option<Run>) {
        self.redo.clear();
        match (self.open, run, self.undo.back_mut()) {
            (Some(open), Some(run), Some(last)) if open == run => {
                last.steps.extend(t.steps);
                last.after = t.after;
            }
            _ => {
                self.undo.push_back(t);
                if self.undo.len() > Self::LIMIT {
                    self.undo.pop_front();
                }
            }
        }
        self.open = run;
    }

    fn seal(&mut self) {
        self.open = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(e: &Editor) -> String {
        e.buffer().rope().to_string()
    }

    fn sels(e: &Editor) -> Vec<(usize, usize)> {
        e.selections()
            .all()
            .iter()
            .map(|s| (s.anchor, s.head))
            .collect()
    }

    fn carets(e: &mut Editor, at: &[usize]) {
        let all = at.iter().map(|&a| Selection::caret(a)).collect();
        e.set_selections(Selections::new(all, 0));
    }

    fn go(motion: Motion, extend: bool) -> Command<'static> {
        Command::Move { motion, extend }
    }

    #[test]
    fn typing_at_three_carets_is_one_revision_and_one_undo() {
        let mut e = Editor::from_text("a\nb\nc");
        carets(&mut e, &[1, 3, 5]);
        for c in ["x", "y"] {
            let edits = e.apply(Command::Insert(c));
            assert_eq!(edits.len(), 3);
            assert!(edits.iter().all(|x| x.revision == e.buffer().revision()));
        }
        assert_eq!(text(&e), "axy\nbxy\ncxy");
        assert_eq!(sels(&e), [(3, 3), (7, 7), (11, 11)]);
        assert_eq!(e.buffer().revision(), 2);
        e.apply(Command::Undo);
        assert_eq!(text(&e), "a\nb\nc", "the typing run coalesced");
        assert_eq!(sels(&e), [(1, 1), (3, 3), (5, 5)]);
        e.apply(Command::Redo);
        assert_eq!(
            (text(&e).as_str(), sels(&e)[2]),
            ("axy\nbxy\ncxy", (11, 11))
        );
    }

    #[test]
    fn a_move_ends_the_typing_run_and_a_new_edit_drops_redo() {
        let mut e = Editor::from_text("");
        e.apply(Command::Insert("a"));
        e.apply(Command::Insert("b"));
        e.apply(go(Motion::Left, false));
        e.apply(Command::Insert("c"));
        assert_eq!(text(&e), "acb");
        assert_eq!(e.history().undo_depth(), 2);
        e.apply(Command::Undo);
        assert_eq!((text(&e).as_str(), sels(&e)), ("ab", vec![(1, 1)]));
        e.apply(Command::Insert("z"));
        assert!(!e.history().can_redo());
        e.apply(Command::DeleteBackward);
        e.apply(Command::DeleteBackward);
        assert_eq!(e.history().undo_depth(), 3, "backspaces are their own run");
    }

    #[test]
    fn backspaces_at_neighbouring_carets_merge_their_carets() {
        let mut e = Editor::from_text("abcd\r\nef");
        carets(&mut e, &[1, 2, 6]);
        e.apply(Command::DeleteBackward);
        assert_eq!(text(&e), "cdef", "a \\r\\n goes whole");
        assert_eq!(sels(&e), [(0, 0), (2, 2)]);
        e.apply(Command::DeleteForward);
        assert_eq!((text(&e).as_str(), sels(&e)), ("df", vec![(0, 0), (1, 1)]));
    }

    #[test]
    fn deleting_a_selection_and_a_caret_together() {
        let mut e = Editor::from_text("hello world");
        e.set_selections(Selections::new(
            vec![Selection::new(0, 5), Selection::caret(11)],
            1,
        ));
        e.apply(Command::DeleteBackward);
        assert_eq!(text(&e), " worl");
        assert_eq!(sels(&e), [(0, 0), (5, 5)]);
        assert_eq!(e.selections().primary_index(), 1);
    }

    #[test]
    fn a_newline_repeats_the_indent_and_the_line_ending() {
        let mut e = Editor::from_text("\tfn a() {\r\n}");
        carets(&mut e, &[9]);
        e.apply(Command::Newline);
        assert_eq!(text(&e), "\tfn a() {\r\n\t\r\n}");
        assert_eq!(sels(&e), [(12, 12)]);
    }

    #[test]
    fn vertical_moves_keep_the_goal_column_over_tabs_and_wide_chars() {
        // Columns: "abcdef" 0..6; "\tx" tab to 4, x at 4; "日本語" 0, 2, 4.
        let mut e = Editor::from_text("abcdef\n\tx\n日本語");
        carets(&mut e, &[5]);
        e.apply(go(Motion::Down, false));
        assert_eq!(
            sels(&e),
            [(9, 9)],
            "column 5 lands after x at the line's end"
        );
        e.apply(go(Motion::Down, false));
        assert_eq!(sels(&e), [(12, 12)], "after 本: column 4, the last ≤ 5");
        e.apply(go(Motion::Up, false));
        e.apply(go(Motion::Up, false));
        assert_eq!(sels(&e), [(5, 5)], "the goal survived the short line");
        carets(&mut e, &[2]);
        e.apply(go(Motion::Down, true));
        assert_eq!(
            sels(&e),
            [(2, 7)],
            "column 2 sits inside the tab: before it"
        );
        e.apply(go(Motion::Up, false));
        assert_eq!(sels(&e), [(2, 2)], "the goal outlived the tab");
        e.apply(go(Motion::Up, false));
        assert_eq!(
            sels(&e),
            [(0, 0)],
            "up from the first line goes to the start"
        );
    }

    #[test]
    fn moves_by_char_word_and_line_with_and_without_shift() {
        let mut e = Editor::from_text("let foo = 1;\nbar");
        carets(&mut e, &[0]);
        e.apply(go(Motion::WordRight, false));
        e.apply(go(Motion::WordRight, true));
        assert_eq!(sels(&e), [(3, 7)]);
        e.apply(go(Motion::Left, false));
        assert_eq!(sels(&e), [(3, 3)], "a selection collapses to its start");
        e.apply(go(Motion::LineEnd, true));
        e.apply(go(Motion::Right, false));
        assert_eq!(sels(&e), [(12, 12)]);
        e.apply(go(Motion::Right, false));
        e.apply(go(Motion::LineStart, false));
        assert_eq!(sels(&e), [(13, 13)]);
        e.apply(go(Motion::WordLeft, false));
        assert_eq!(sels(&e), [(10, 10)]);
    }

    #[test]
    fn carets_added_above_and_below_merge_into_one_column() {
        let mut e = Editor::from_text("abcd\nab\nabcd");
        carets(&mut e, &[8 + 3]);
        e.apply(Command::AddCaretAbove);
        e.apply(Command::AddCaretAbove);
        assert_eq!(sels(&e), [(3, 3), (7, 7), (11, 11)]);
        assert_eq!(
            e.selections().primary_index(),
            0,
            "the newest caret is primary"
        );
        e.apply(Command::AddCaretBelow);
        assert_eq!(sels(&e).len(), 3, "a caret already there merges");
        assert_eq!(
            e.selections().primary_index(),
            1,
            "into the one added below"
        );
        e.apply(Command::Insert("!"));
        assert_eq!(text(&e), "abc!d\nab!\nabc!d");
        e.apply(Command::CollapseToPrimary);
        assert_eq!(sels(&e), [(9, 9)]);
    }

    #[test]
    fn select_next_occurrence_walks_and_wraps_then_types_over_all() {
        let mut e = Editor::from_text("foo bar foo foobar foo");
        carets(&mut e, &[9]);
        e.apply(Command::SelectNextOccurrence);
        assert_eq!(sels(&e), [(8, 11)], "a caret selects its word");
        e.apply(Command::SelectNextOccurrence);
        e.apply(Command::SelectNextOccurrence);
        e.apply(Command::SelectNextOccurrence);
        assert_eq!(sels(&e), [(0, 3), (8, 11), (12, 15), (19, 22)]);
        assert_eq!(e.selections().primary_index(), 0, "it wrapped to the start");
        e.apply(Command::SelectNextOccurrence);
        assert_eq!(sels(&e).len(), 4, "nothing left to add");
        e.apply(Command::Insert("x"));
        assert_eq!(text(&e), "x bar x xbar x");
        e.apply(Command::Undo);
        assert_eq!(sels(&e), [(0, 3), (8, 11), (12, 15), (19, 22)]);
    }

    #[test]
    fn every_touching_occurrence_stays_its_own_selection() {
        let mut e = Editor::from_text("abab ab");
        e.set_selections(Selections::single(Selection::new(2, 4)));
        e.apply(Command::SelectAllOccurrences);
        assert_eq!(sels(&e), [(0, 2), (2, 4), (5, 7)]);
        assert_eq!(e.selections().primary_index(), 1);
        e.apply(Command::Insert("Z"));
        assert_eq!(text(&e), "ZZ Z");
    }

    #[test]
    fn the_history_keeps_the_newest_thousand_transactions() {
        let mut e = Editor::from_text("");
        for _ in 0..History::LIMIT + 5 {
            e.apply(Command::Newline);
        }
        assert_eq!(e.history().undo_depth(), History::LIMIT);
        while e.history().can_undo() {
            e.apply(Command::Undo);
        }
        assert_eq!(e.buffer().rope().len_chars(), 5);
    }
}
