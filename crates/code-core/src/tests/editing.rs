//! The editor against a naive model: the text as a `Vec<char>`, selections as plain
//! (anchor, head, goal) triples, changes made front to back with every later position
//! shifted by hand, and undo as whole snapshots. Find and replace's text is the regex
//! crate's own `replace_all`. Every command's [`Edit`]s are replayed on a copy of the text
//! before it, as tree-sitter would take them.

use super::{pos, text};
use crate::search::is_identifier_char;
use crate::search_replace::{replace_all, replace_next};
use crate::{Command, Edit, Editor, Motion, Selection, Selections, width_at};
use proptest::prelude::*;
use regex::Regex;

const PATTERNS: [&str; 10] = [
    "a",
    "b+",
    r"\n",
    "(a)(b)?",
    "(?m)^",
    "x*",
    "日",
    r"(?m)[ \t]+$",
    "(?P<w>[a-c]+)",
    "\r\n|\r",
];
const REPLACEMENTS: [&str; 7] = ["", "z", "$1$1", "${w}-", "\n", "[$0]", "日\t"];
const INSERTS: [&str; 13] = [
    "a", "b", "x", " ", "\t", "日", "😀", "\u{301}", "\r", "\n", "ab", "a\nb", "$",
];

#[derive(Debug, Clone)]
enum Cmd {
    Insert(usize),
    Newline,
    DeleteBackward,
    DeleteForward,
    Move(Motion, bool),
    AddCaret(bool),
    SelectNext,
    SelectOccurrences,
    SelectAll,
    Collapse,
    Undo,
    Redo,
    /// Selections as (anchor, head) modulo the text's chars + 1, and the primary's index
    /// modulo their count.
    Select(Vec<(usize, usize)>, usize),
    ReplaceAll(usize, usize),
    ReplaceNext(usize, usize),
}

fn cmd() -> impl Strategy<Value = Cmd> {
    let motion = prop_oneof![
        Just(Motion::Left),
        Just(Motion::Right),
        Just(Motion::Up),
        Just(Motion::Down),
        Just(Motion::LineStart),
        Just(Motion::LineEnd),
        Just(Motion::WordLeft),
        Just(Motion::WordRight),
    ];
    prop_oneof![
        6 => (0..INSERTS.len()).prop_map(Cmd::Insert),
        1 => Just(Cmd::Newline),
        3 => Just(Cmd::DeleteBackward),
        2 => Just(Cmd::DeleteForward),
        6 => (motion, any::<bool>()).prop_map(|(m, e)| Cmd::Move(m, e)),
        2 => any::<bool>().prop_map(Cmd::AddCaret),
        2 => Just(Cmd::SelectNext),
        1 => Just(Cmd::SelectOccurrences),
        1 => Just(Cmd::SelectAll),
        1 => Just(Cmd::Collapse),
        3 => Just(Cmd::Undo),
        2 => Just(Cmd::Redo),
        2 => (prop::collection::vec((0usize..64, 0usize..64), 1..5), 0usize..5)
            .prop_map(|(s, p)| Cmd::Select(s, p)),
        1 => (0..PATTERNS.len(), 0..REPLACEMENTS.len()).prop_map(|(p, r)| Cmd::ReplaceAll(p, r)),
        1 => (0..PATTERNS.len(), 0..REPLACEMENTS.len()).prop_map(|(p, r)| Cmd::ReplaceNext(p, r)),
    ]
}

fn simple(cmd: &Cmd) -> Option<Command<'static>> {
    Some(match *cmd {
        Cmd::Insert(i) => Command::Insert(INSERTS[i]),
        Cmd::Newline => Command::Newline,
        Cmd::DeleteBackward => Command::DeleteBackward,
        Cmd::DeleteForward => Command::DeleteForward,
        Cmd::Move(motion, extend) => Command::Move { motion, extend },
        Cmd::AddCaret(true) => Command::AddCaretAbove,
        Cmd::AddCaret(false) => Command::AddCaretBelow,
        Cmd::SelectNext => Command::SelectNextOccurrence,
        Cmd::SelectOccurrences => Command::SelectAllOccurrences,
        Cmd::SelectAll => Command::SelectAll,
        Cmd::Collapse => Command::CollapseToPrimary,
        Cmd::Undo => Command::Undo,
        Cmd::Redo => Command::Redo,
        Cmd::Select(..) | Cmd::ReplaceAll(..) | Cmd::ReplaceNext(..) => return None,
    })
}

/// The selections a [`Cmd::Select`] names in a text of `len` chars.
fn picked(sels: &[(usize, usize)], primary: usize, len: usize) -> (Vec<Sel>, usize) {
    let all = sels
        .iter()
        .map(|&(a, h)| Sel::new(a % (len + 1), h % (len + 1)))
        .collect();
    (all, primary % sels.len())
}

fn run(e: &mut Editor, cmd: &Cmd, regexes: &[Regex]) -> Vec<Edit> {
    if let Some(command) = simple(cmd) {
        return e.apply(command);
    }
    match cmd {
        Cmd::Select(sels, primary) => {
            let (all, primary) = picked(sels, *primary, e.buffer().rope().len_chars());
            let all = all
                .iter()
                .map(|s| Selection::new(s.anchor, s.head))
                .collect();
            e.set_selections(Selections::new(all, primary));
            Vec::new()
        }
        Cmd::ReplaceAll(p, r) => replace_all(e, &regexes[*p], REPLACEMENTS[*r]),
        Cmd::ReplaceNext(p, r) => replace_next(e, &regexes[*p], REPLACEMENTS[*r]),
        _ => unreachable!("simple commands ran above"),
    }
}

// ---- the model ------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Sel {
    anchor: usize,
    head: usize,
    goal: Option<u32>,
}

impl Sel {
    fn new(anchor: usize, head: usize) -> Self {
        Self {
            anchor,
            head,
            goal: None,
        }
    }

    fn caret(at: usize) -> Self {
        Self::new(at, at)
    }

    fn start(&self) -> usize {
        self.anchor.min(self.head)
    }

    fn end(&self) -> usize {
        self.anchor.max(self.head)
    }

    fn is_caret(&self) -> bool {
        self.anchor == self.head
    }
}

#[derive(Debug, Clone, PartialEq)]
struct State {
    text: Vec<char>,
    sels: Vec<Sel>,
    primary: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Run {
    Typing,
    Back,
    Forward,
}

struct Model {
    now: State,
    /// (before, after) of every transaction.
    undo: Vec<(State, State)>,
    redo: Vec<(State, State)>,
    open: Option<Run>,
    ending: &'static str,
}

fn is_mark(c: char) -> bool {
    width_at(c, 0) == 0
}

fn is_word(c: char) -> bool {
    is_identifier_char(c) || is_mark(c)
}

fn next_stop(t: &[char], at: usize) -> usize {
    if at == t.len() {
        return at;
    }
    if t[at] == '\r' && t.get(at + 1) == Some(&'\n') {
        return at + 2;
    }
    if t[at] == '\n' {
        return at + 1;
    }
    let mut to = at + 1;
    while to < t.len() && is_mark(t[to]) {
        to += 1;
    }
    to
}

fn prev_stop(t: &[char], at: usize) -> usize {
    if at == 0 {
        return 0;
    }
    let mut to = at - 1;
    if t[to] == '\n' {
        return if to > 0 && t[to - 1] == '\r' {
            to - 1
        } else {
            to
        };
    }
    while to > 0 && is_mark(t[to]) && t[to - 1] != '\n' {
        to -= 1;
    }
    to
}

fn line_of(t: &[char], at: usize) -> usize {
    t[..at].iter().filter(|&&c| c == '\n').count()
}

/// A line's first char and where its chars end (before `\n` or `\r\n`).
fn bounds(t: &[char], line: usize) -> (usize, usize) {
    let starts: Vec<usize> = std::iter::once(0)
        .chain((0..t.len()).filter(|&i| t[i] == '\n').map(|i| i + 1))
        .collect();
    let start = starts[line];
    match starts.get(line + 1) {
        Some(&next) if next - 1 > start && t[next - 2] == '\r' => (start, next - 2),
        Some(&next) => (start, next - 1),
        None => (start, t.len()),
    }
}

fn column(t: &[char], at: usize) -> u32 {
    let (start, end) = bounds(t, line_of(t, at));
    let mut col = 0;
    for &c in &t[start..at.min(end)] {
        col += width_at(c, col);
    }
    col
}

fn at_column(t: &[char], line: usize, goal: u32) -> usize {
    let (start, end) = bounds(t, line);
    let (mut col, mut at) = (0, start);
    while at < end && col + width_at(t[at], col) <= goal {
        col += width_at(t[at], col);
        at += 1;
    }
    at
}

fn word_around(t: &[char], at: usize) -> Option<(usize, usize)> {
    let (mut start, mut end) = (at, at);
    while start > 0 && is_word(t[start - 1]) {
        start -= 1;
    }
    while end < t.len() && is_word(t[end]) {
        end += 1;
    }
    (start < end).then_some((start, end))
}

fn occurs(t: &[char], needle: &[char], at: usize) -> bool {
    t.get(at..at + needle.len()) == Some(needle)
}

/// Sort (by start, then end, then given order), then merge overlapping selections and
/// touching ones where either is a caret.
fn normalize(text: Vec<char>, sels: Vec<Sel>, primary: usize) -> State {
    let mut order: Vec<usize> = (0..sels.len()).collect();
    order.sort_by_key(|&i| (sels[i].start(), sels[i].end()));
    let mut out: Vec<Sel> = Vec::new();
    let mut at = 0;
    for i in order {
        let s = sels[i];
        match out.last_mut() {
            Some(m)
                if s.start() < m.end()
                    || (s.start() == m.end() && (m.is_caret() || s.is_caret())) =>
            {
                let (start, end) = (m.start(), m.end().max(s.end()));
                let backward = if m.is_caret() {
                    s.head < s.anchor
                } else {
                    m.head < m.anchor
                };
                let (anchor, head) = if backward { (end, start) } else { (start, end) };
                *m = Sel {
                    anchor,
                    head,
                    goal: m.goal,
                };
            }
            _ => out.push(s),
        }
        if i == primary {
            at = out.len() - 1;
        }
    }
    State {
        text,
        sels: out,
        primary: at,
    }
}

impl Model {
    fn new(start: &str) -> Self {
        let text: Vec<char> = start.chars().collect();
        let crlf = text
            .iter()
            .position(|&c| c == '\n')
            .is_some_and(|i| i > 0 && text[i - 1] == '\r');
        Self {
            now: State {
                text,
                sels: vec![Sel::caret(0)],
                primary: 0,
            },
            undo: Vec::new(),
            redo: Vec::new(),
            open: None,
            ending: if crlf { "\r\n" } else { "\n" },
        }
    }

    fn string(&self) -> String {
        self.now.text.iter().collect()
    }

    fn select(&mut self, sels: Vec<Sel>, primary: usize) {
        self.open = None;
        self.now = normalize(self.now.text.clone(), sels, primary);
    }

    fn record(&mut self, before: State, run: Option<Run>) {
        self.redo.clear();
        match (self.open, run, self.undo.last_mut()) {
            (Some(open), Some(run), Some(top)) if open == run => top.1 = self.now.clone(),
            _ => self.undo.push((before, self.now.clone())),
        }
        self.open = run;
    }

    /// One (start, end, text) per selection, made front to back; each caret lands after its
    /// change's text.
    fn edit(&mut self, run: Option<Run>, targets: Vec<(usize, usize, String)>) {
        let mut order: Vec<usize> = (0..targets.len()).collect();
        order.sort_by_key(|&i| targets[i].0);
        let mut merged: Vec<(usize, usize, String)> = Vec::new();
        let mut owner = vec![0; targets.len()];
        for i in order {
            let (a, b, t) = &targets[i];
            match merged.last_mut() {
                Some(m) if *a < m.1 => {
                    m.1 = m.1.max(*b);
                    m.2.push_str(t);
                }
                _ => merged.push((*a, *b, t.clone())),
            }
            owner[i] = merged.len() - 1;
        }
        if merged.iter().all(|(a, b, t)| a == b && t.is_empty()) {
            return;
        }
        let before = self.now.clone();
        let mut text = self.now.text.clone();
        let mut ends = Vec::new();
        let mut shift = 0isize;
        for (a, b, t) in &merged {
            let at = a.wrapping_add_signed(shift);
            let new: Vec<char> = t.chars().collect();
            text.splice(at..b.wrapping_add_signed(shift), new.iter().copied());
            ends.push(at + new.len());
            shift += new.len() as isize - (b - a) as isize;
        }
        let sels = owner.iter().map(|&k| Sel::caret(ends[k])).collect();
        self.now = normalize(text, sels, self.now.primary);
        self.record(before, run);
    }

    fn moved(&self, s: Sel, motion: Motion, extend: bool) -> Sel {
        let t = &self.now.text;
        let line = line_of(t, s.head);
        let (head, goal) = match motion {
            Motion::Left if !extend && !s.is_caret() => return Sel::caret(s.start()),
            Motion::Right if !extend && !s.is_caret() => return Sel::caret(s.end()),
            Motion::Left => (prev_stop(t, s.head), None),
            Motion::Right => (next_stop(t, s.head), None),
            Motion::Up | Motion::Down => {
                let goal = s.goal.unwrap_or_else(|| column(t, s.head));
                let head = match motion {
                    Motion::Up if line == 0 => 0,
                    Motion::Up => at_column(t, line - 1, goal),
                    _ if line == line_of(t, t.len()) => t.len(),
                    _ => at_column(t, line + 1, goal),
                };
                (head, Some(goal))
            }
            Motion::LineStart => (bounds(t, line).0, None),
            Motion::LineEnd => (bounds(t, line).1, None),
            Motion::WordLeft => {
                let mut at = s.head;
                while at > 0 && !is_word(t[at - 1]) {
                    at -= 1;
                }
                while at > 0 && is_word(t[at - 1]) {
                    at -= 1;
                }
                (at, None)
            }
            Motion::WordRight => {
                let mut at = s.head;
                while at < t.len() && !is_word(t[at]) {
                    at += 1;
                }
                while at < t.len() && is_word(t[at]) {
                    at += 1;
                }
                (at, None)
            }
        };
        Sel {
            anchor: if extend { s.anchor } else { head },
            head,
            goal,
        }
    }

    fn run(&mut self, cmd: &Cmd, regexes: &[Regex]) {
        let t = self.now.text.clone();
        let sels = self.now.sels.clone();
        let p = sels[self.now.primary];
        let all_carets = sels.iter().all(Sel::is_caret);
        match cmd {
            Cmd::Insert(i) => {
                let s = INSERTS[*i];
                let typing = s.chars().count() == 1 && s != "\n";
                let targets = sels.iter().map(|x| (x.start(), x.end(), s.to_owned()));
                self.edit(typing.then_some(Run::Typing), targets.collect());
            }
            Cmd::Newline => {
                let targets = sels.iter().map(|x| {
                    let (start, _) = bounds(&t, line_of(&t, x.start()));
                    let indent: String = t[start..x.start()]
                        .iter()
                        .take_while(|&&c| c == ' ' || c == '\t')
                        .collect();
                    (x.start(), x.end(), format!("{}{indent}", self.ending))
                });
                self.edit(None, targets.collect());
            }
            Cmd::DeleteBackward | Cmd::DeleteForward => {
                let back = matches!(cmd, Cmd::DeleteBackward);
                let targets = sels.iter().map(|x| match (x.is_caret(), back) {
                    (true, true) => (prev_stop(&t, x.head), x.head, String::new()),
                    (true, false) => (x.head, next_stop(&t, x.head), String::new()),
                    (false, _) => (x.start(), x.end(), String::new()),
                });
                let run = if back { Run::Back } else { Run::Forward };
                self.edit(all_carets.then_some(run), targets.collect());
            }
            Cmd::Move(motion, extend) => {
                let moved = sels.iter().map(|&s| self.moved(s, *motion, *extend));
                self.select(moved.collect(), self.now.primary);
            }
            Cmd::AddCaret(up) => {
                let mut all = sels.clone();
                let mut primary = self.now.primary;
                let last = line_of(&t, t.len());
                for (i, s) in sels.iter().enumerate() {
                    let line = line_of(&t, s.head);
                    let target = match up {
                        true if line == 0 => continue,
                        false if line == last => continue,
                        true => line - 1,
                        false => line + 1,
                    };
                    let goal = s.goal.unwrap_or_else(|| column(&t, s.head));
                    if i == self.now.primary {
                        primary = all.len();
                    }
                    all.push(Sel {
                        goal: Some(goal),
                        ..Sel::caret(at_column(&t, target, goal))
                    });
                }
                self.select(all, primary);
            }
            Cmd::SelectNext if p.is_caret() => match word_around(&t, p.head) {
                Some((a, b)) => {
                    let mut all = sels.clone();
                    all[self.now.primary] = Sel::new(a, b);
                    self.select(all, self.now.primary);
                }
                None => self.open = None,
            },
            Cmd::SelectNext => {
                let needle = &t[p.start()..p.end()];
                let free = |i: usize| {
                    occurs(&t, needle, i)
                        && !sels
                            .iter()
                            .any(|s| i < s.end() && s.start() < i + needle.len())
                };
                match (p.end()..t.len()).chain(0..p.end()).find(|&i| free(i)) {
                    Some(i) => {
                        let mut all = sels.clone();
                        all.push(Sel::new(i, i + needle.len()));
                        self.select(all, sels.len());
                    }
                    None => self.open = None,
                }
            }
            Cmd::SelectOccurrences => {
                let word = match p.is_caret() {
                    true => word_around(&t, p.head),
                    false => Some((p.start(), p.end())),
                };
                let Some((a, b)) = word else {
                    self.open = None;
                    return;
                };
                let needle = &t[a..b];
                let (mut all, mut primary, mut i) = (Vec::new(), 0, 0);
                while i < t.len() {
                    if occurs(&t, needle, i) {
                        if i <= a {
                            primary = all.len();
                        }
                        all.push(Sel::new(i, i + needle.len()));
                        i += needle.len();
                    } else {
                        i += 1;
                    }
                }
                self.select(all, primary);
            }
            Cmd::SelectAll => self.select(vec![Sel::new(0, t.len())], 0),
            Cmd::Collapse => self.select(vec![p], 0),
            Cmd::Undo => {
                self.open = None;
                if let Some((before, after)) = self.undo.pop() {
                    self.now = before.clone();
                    self.redo.push((before, after));
                }
            }
            Cmd::Redo => {
                self.open = None;
                if let Some((before, after)) = self.redo.pop() {
                    self.now = after.clone();
                    self.undo.push((before, after));
                }
            }
            Cmd::Select(s, primary) => {
                let (all, primary) = picked(s, *primary, t.len());
                self.select(all, primary);
            }
            Cmd::ReplaceAll(re, rep) => self.replace_all(&regexes[*re], REPLACEMENTS[*rep]),
            Cmd::ReplaceNext(re, rep) => self.replace_next(&regexes[*re], REPLACEMENTS[*rep]),
        }
    }

    fn replace_all(&mut self, re: &Regex, rep: &str) {
        let s = self.string();
        let chars = |b: usize| s[..b].chars().count();
        let changes: Vec<(usize, usize, usize)> = re
            .captures_iter(&s)
            .map(|caps| {
                let m = caps.get(0).expect("the match");
                let mut out = String::new();
                caps.expand(rep, &mut out);
                (chars(m.start()), chars(m.end()), out.chars().count())
            })
            .collect();
        if changes.iter().all(|&(a, b, n)| a == b && n == 0) {
            return;
        }
        let map = |at: usize| {
            let mut shift = 0isize;
            for &(a, b, n) in &changes {
                if a >= at {
                    break;
                }
                if b > at {
                    return a.wrapping_add_signed(shift) + n;
                }
                shift += n as isize - (b - a) as isize;
            }
            at.wrapping_add_signed(shift)
        };
        let before = self.now.clone();
        let sels = before
            .sels
            .iter()
            .map(|x| Sel::new(map(x.anchor), map(x.head)))
            .collect();
        let text = re.replace_all(&s, rep).chars().collect();
        self.now = normalize(text, sels, before.primary);
        self.record(before, None);
    }

    fn replace_next(&mut self, re: &Regex, rep: &str) {
        let s = self.string();
        let p = self.now.sels[self.now.primary];
        let from = s.char_indices().nth(p.start()).map_or(s.len(), |(b, _)| b);
        let Some(caps) = re.captures_at(&s, from).or_else(|| re.captures_at(&s, 0)) else {
            return;
        };
        let m = caps.get(0).expect("the match");
        let mut out = String::new();
        caps.expand(rep, &mut out);
        if m.is_empty() && out.is_empty() {
            return;
        }
        let mut t = s.clone();
        t.replace_range(m.range(), &out);
        let (start, end) = (m.start(), m.start() + out.len());
        let mut next = re.find_at(&t, end);
        if next.is_some_and(|n| n.is_empty() && n.start() == end) {
            next = t[end..]
                .chars()
                .next()
                .and_then(|c| re.find_at(&t, end + c.len_utf8()));
        }
        let next = next
            .or_else(|| re.find_at(&t, 0).filter(|w| w.end() <= start))
            .map_or(end..end, |n| n.range());
        let chars = |b: usize| t[..b].chars().count();
        let before = self.now.clone();
        let sel = Sel::new(chars(next.start), chars(next.end));
        self.now = normalize(t.chars().collect(), vec![sel], 0);
        self.record(before, None);
    }
}

// ---- the checks -----------------------------------------------------------------------

fn check(e: &Editor, model: &Model, cmd: &Cmd) -> Result<(), TestCaseError> {
    prop_assert_eq!(
        e.buffer().rope().to_string(),
        model.string(),
        "after {:?}",
        cmd
    );
    let got: Vec<Sel> = e
        .selections()
        .all()
        .iter()
        .map(|s| Sel {
            anchor: s.anchor,
            head: s.head,
            goal: s.goal,
        })
        .collect();
    prop_assert_eq!(&got, &model.now.sels, "after {:?}", cmd);
    prop_assert_eq!(e.selections().primary_index(), model.now.primary);
    prop_assert!(got.iter().all(|s| s.end() <= model.now.text.len()));
    for w in got.windows(2) {
        let (a, b) = (w[0], w[1]);
        prop_assert!(
            a.end() < b.start() || (a.end() == b.start() && !a.is_caret() && !b.is_caret()),
            "sorted and apart: {:?}",
            got
        );
    }
    prop_assert_eq!(e.history().can_undo(), !model.undo.is_empty());
    prop_assert_eq!(e.history().can_redo(), !model.redo.is_empty());
    Ok(())
}

/// Replay `edits` on `old` in turn and arrive at `new`. Each edit's inserted bytes are read
/// off `new` (tagging every byte by the edit that inserted it), then every point is checked
/// against the text as the edits before it left it.
fn replay(old: &str, edits: &[Edit], new: &str) -> Result<(), TestCaseError> {
    #[derive(Clone, Copy)]
    enum Tag {
        Old(u8),
        New(usize, usize),
    }
    let mut tags: Vec<Tag> = old.bytes().map(Tag::Old).collect();
    for (i, e) in edits.iter().enumerate() {
        prop_assert!(e.start.byte <= e.old_end.byte && e.old_end.byte <= tags.len());
        prop_assert!(e.start.byte <= e.new_end.byte);
        let added = (0..e.new_end.byte - e.start.byte).map(|k| Tag::New(i, k));
        tags.splice(e.start.byte..e.old_end.byte, added);
    }
    prop_assert_eq!(tags.len(), new.len());
    let mut inserted: Vec<Vec<Option<u8>>> = edits
        .iter()
        .map(|e| vec![None; e.new_end.byte - e.start.byte])
        .collect();
    for (tag, &b) in tags.iter().zip(new.as_bytes()) {
        match *tag {
            Tag::Old(o) => prop_assert_eq!(o, b, "an untouched byte moved"),
            Tag::New(i, k) => inserted[i][k] = Some(b),
        }
    }
    let mut text = old.to_owned();
    for (e, bytes) in edits.iter().zip(inserted) {
        let bytes: Option<Vec<u8>> = bytes.into_iter().collect();
        let Some(bytes) = bytes else {
            return Err(TestCaseError::fail("a later edit rewrote an insertion"));
        };
        let Ok(added) = String::from_utf8(bytes) else {
            return Err(TestCaseError::fail("an insertion splits a char"));
        };
        prop_assert_eq!(e.start, pos(&text, e.start.char));
        prop_assert_eq!(e.old_end, pos(&text, e.old_end.char));
        let removed = text[e.start.byte..e.old_end.byte].matches('\n').count();
        text.replace_range(e.start.byte..e.old_end.byte, &added);
        prop_assert_eq!(e.new_end, pos(&text, e.new_end.char));
        prop_assert_eq!(
            (e.lines_removed, e.lines_added),
            (removed, added.matches('\n').count())
        );
    }
    prop_assert_eq!(text, new);
    Ok(())
}

/// Run one command on both, then check them equal and the command's edits exact, made in
/// one revision.
fn step(
    e: &mut Editor,
    model: &mut Model,
    cmd: &Cmd,
    regexes: &[Regex],
) -> Result<(), TestCaseError> {
    let (old, revision) = (e.buffer().rope().to_string(), e.buffer().revision());
    let edits = run(e, cmd, regexes);
    model.run(cmd, regexes);
    check(e, model, cmd)?;
    replay(&old, &edits, &e.buffer().rope().to_string())?;
    let bumped = u64::from(!edits.is_empty());
    prop_assert_eq!(
        e.buffer().revision(),
        revision + bumped,
        "one revision per command"
    );
    prop_assert!(edits.iter().all(|x| x.revision == e.buffer().revision()));
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn editing_matches_a_naive_model_and_undoes_and_redoes_whole(
        start in text(24),
        cmds in prop::collection::vec(cmd(), 1..40),
    ) {
        let regexes: Vec<Regex> = PATTERNS.iter().map(|p| Regex::new(p).unwrap()).collect();
        let mut e = Editor::from_text(&start);
        let mut model = Model::new(&start);
        for cmd in &cmds {
            step(&mut e, &mut model, cmd, &regexes)?;
        }
        let first = model.undo.first().map(|(before, _)| before.clone());
        while e.history().can_undo() {
            step(&mut e, &mut model, &Cmd::Undo, &regexes)?;
        }
        prop_assert_eq!(e.buffer().rope().to_string(), start.as_str(), "undo all");
        if let Some(first) = first {
            prop_assert_eq!(&model.now, &first, "undo all: the selections before the first edit");
        }
        // Everything is redoable now; the newest transaction sits at the bottom.
        let last = model.redo.first().map(|(_, after)| after.clone());
        while e.history().can_redo() {
            step(&mut e, &mut model, &Cmd::Redo, &regexes)?;
        }
        if let Some(last) = last {
            let text: String = last.text.iter().collect();
            prop_assert_eq!(e.buffer().rope().to_string(), text, "redo all");
            prop_assert_eq!(&model.now, &last, "redo all: the selections after the newest edit");
        }
    }
}
