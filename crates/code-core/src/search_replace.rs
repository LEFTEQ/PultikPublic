//! Find and replace in a [`Buffer`] (workbench AC3,
//! `docs/specs/2026-10-15-workbench-editing-decisions.md`): every match of a regex as char
//! ranges, and replacing matches through an [`Editor`] as one undoable transaction.
//!
//! A regex reads the whole text at once, so a pattern may span lines, and every match is
//! found in the text before any replacement: a replacement is never searched again.
//! Replacements expand `$1`, `${name}` and `$$` (`regex::Captures::expand`).

use crate::buffer::{Buffer, Edit, TextChunks};
use crate::cursor::{Selection, Selections};
use crate::editor::{Change, Editor};
use regex::Regex;
use ropey::Rope;
use std::ops::Range;

/// A regex that finds `query` as it is written (a find field with regex off).
pub fn literal(query: &str) -> Result<Regex, regex::Error> {
    Regex::new(&regex::escape(query))
}

/// `text` as a replacement that inserts itself, with no group expanded.
pub fn literal_replacement(text: &str) -> String {
    text.replace('$', "$$")
}

/// Every match of `regex`, leftmost first and never overlapping (`Regex::find_iter`), as
/// char ranges.
pub fn find_all(buffer: &Buffer, regex: &Regex) -> Vec<Range<usize>> {
    let text = whole(buffer);
    let rope = buffer.rope();
    regex
        .find_iter(&text)
        .map(|m| rope.byte_to_char(m.start())..rope.byte_to_char(m.end()))
        .collect()
}

/// Replace every match (as [`find_all`] finds them) with `replacement`, expanded per match:
/// one transaction. The selections stay where they were in the text around the matches; one
/// inside a match moves to the end of its replacement.
pub fn replace_all(editor: &mut Editor, regex: &Regex, replacement: &str) -> Vec<Edit> {
    let text = whole(editor.buffer());
    let rope = editor.buffer().rope();
    let changes: Vec<Change> = regex
        .captures_iter(&text)
        .map(|caps| {
            let m = caps.get_match();
            let mut out = String::new();
            caps.expand(replacement, &mut out);
            Change {
                range: rope.byte_to_char(m.start())..rope.byte_to_char(m.end()),
                text: out,
            }
        })
        .collect();
    let old: Vec<Range<usize>> = changes.iter().map(|c| c.range.clone()).collect();
    let before = editor.selections().clone();
    editor.transact(None, changes, |_, new| {
        let at = |p| map_through(p, &old, new);
        let all = before
            .all()
            .iter()
            .map(|s| Selection::new(at(s.anchor), at(s.head)));
        Selections::new(all.collect(), before.primary_index())
    })
}

/// Replace the first match at or after the primary selection's start (wrapping round to the
/// text's start) and select the next match after the replacement, or put a caret after it
/// when there is none. One transaction; the other selections go.
///
/// The next match is searched from the replacement's end, as `find_iter` would go on (an
/// empty match right there is skipped), wrapping only to matches before the replacement.
pub fn replace_next(editor: &mut Editor, regex: &Regex, replacement: &str) -> Vec<Edit> {
    let mut text = whole(editor.buffer());
    let rope = editor.buffer().rope();
    let from = rope.char_to_byte(editor.selections().primary().start());
    let Some(caps) = regex
        .captures_at(&text, from)
        .or_else(|| regex.captures_at(&text, 0))
    else {
        return Vec::new();
    };
    let m = caps.get_match();
    let mut out = String::new();
    caps.expand(replacement, &mut out);
    let change = Change {
        range: rope.byte_to_char(m.start())..rope.byte_to_char(m.end()),
        text: out,
    };
    let (start, end) = (m.start(), m.start() + change.text.len());
    text.replace_range(m.range(), &change.text);
    let mut next = regex.find_at(&text, end);
    if next.is_some_and(|n| n.is_empty() && n.start() == end) {
        next = text[end..]
            .chars()
            .next()
            .and_then(|c| regex.find_at(&text, end + c.len_utf8()));
    }
    let next = next
        .or_else(|| regex.find_at(&text, 0).filter(|w| w.end() <= start))
        .map_or(end..end, |n| n.range());
    editor.transact(None, vec![change], |buf, _| {
        let rope = buf.rope();
        let (a, b) = (rope.byte_to_char(next.start), rope.byte_to_char(next.end));
        Selections::single(Selection::new(a, b))
    })
}

/// Where position `at` of the text before `old` (sorted, never overlapping) were replaced
/// by `new` lands: shifted past the changes before it, at the end of the one it sat inside,
/// and in front of one that starts at it.
fn map_through(at: usize, old: &[Range<usize>], new: &[Range<usize>]) -> usize {
    let before = old.partition_point(|r| r.start < at && r.end <= at);
    match (old.get(before), before.checked_sub(1)) {
        (Some(r), _) if r.start < at => new[before].end,
        (_, Some(k)) => at - old[k].end + new[k].end,
        (_, None) => at,
    }
}

/// The whole text, for a regex (which reads one string).
fn whole(buffer: &Buffer) -> String {
    let rope = buffer.rope();
    let mut text = String::with_capacity(rope.len_bytes());
    text.extend(TextChunks::new(rope, 0..rope.len_bytes()));
    text
}

/// The first byte where `needle` (not empty) occurs wholly inside `bytes` (on char
/// boundaries), read chunk by chunk: the window holds one chunk plus the needle's length.
pub(crate) fn find_literal(rope: &Rope, needle: &str, bytes: Range<usize>) -> Option<usize> {
    let mut window = String::new();
    let mut base = bytes.start;
    for chunk in TextChunks::new(rope, bytes) {
        window.push_str(chunk);
        if let Some(at) = window.find(needle) {
            return Some(base + at);
        }
        let mut keep = window.len().saturating_sub(needle.len() - 1);
        while !window.is_char_boundary(keep) {
            keep -= 1;
        }
        window.drain(..keep);
        base += keep;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::editor::Command;

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

    fn re(p: &str) -> Regex {
        Regex::new(p).unwrap()
    }

    #[test]
    fn find_all_reads_across_lines_in_chars() {
        let b = Buffer::from_text("日a\nb日a\nb");
        assert_eq!(find_all(&b, &re(r"a\nb")), [1..4, 5..8]);
        assert_eq!(find_all(&b, &re("(?m)^")), [0..0, 3..3, 7..7]);
        assert_eq!(
            find_all(&b, &literal("a.").unwrap()),
            Vec::<Range<usize>>::new()
        );
    }

    #[test]
    fn replace_all_expands_groups_as_one_undo() {
        let mut e = Editor::from_text("let a = 1;\nlet bb = 22;\n");
        e.set_selections(Selections::single(Selection::caret(14)));
        let edits = replace_all(
            &mut e,
            &re(r"let (?P<name>\w+) = (\d+)"),
            "const ${name}: i32 = $2$$",
        );
        assert_eq!(edits.len(), 2);
        assert_eq!(text(&e), "const a: i32 = 1$;\nconst bb: i32 = 22$;\n");
        assert_eq!(
            sels(&e),
            [(38, 38)],
            "a caret inside a match goes to its end"
        );
        e.apply(Command::Undo);
        assert_eq!(text(&e), "let a = 1;\nlet bb = 22;\n");
        assert_eq!(sels(&e), [(14, 14)]);
    }

    #[test]
    fn a_replacement_is_never_matched_again() {
        let mut e = Editor::from_text("aXa");
        replace_all(&mut e, &re("a"), "aa");
        assert_eq!(text(&e), "aaXaa");
        let mut e = Editor::from_text("a a");
        replace_next(&mut e, &re("a"), "aa");
        assert_eq!((text(&e).as_str(), sels(&e)), ("aa a", vec![(3, 4)]));
        replace_next(&mut e, &re("a"), "aa");
        assert_eq!(text(&e), "aa aa");
        assert_eq!(
            sels(&e),
            [(0, 1)],
            "it wrapped to a match before the replacement"
        );
        let mut e = Editor::from_text("a");
        replace_next(&mut e, &re("a"), "aa");
        assert_eq!(
            sels(&e),
            [(2, 2)],
            "no other match: a caret after the replacement"
        );
    }

    #[test]
    fn replace_next_starts_at_the_primary_and_steps_over_empty_matches() {
        let mut e = Editor::from_text("x1 x2 x3");
        e.set_selections(Selections::single(Selection::caret(2)));
        replace_next(&mut e, &re(r"x(\d)"), "y$1");
        assert_eq!((text(&e).as_str(), sels(&e)), ("x1 y2 x3", vec![(6, 8)]));
        let mut e = Editor::from_text("ab");
        for _ in 0..3 {
            replace_next(&mut e, &re("x*"), "-");
        }
        assert_eq!(
            text(&e),
            "-a-b-",
            "every empty match once, as replace_all would"
        );
        let mut all = Editor::from_text("ab");
        replace_all(&mut all, &re("x*"), "-");
        assert_eq!(text(&all), text(&e));
    }

    #[test]
    fn a_literal_occurs_across_chunks() {
        let long = format!("{}needle{}", "x".repeat(5000), "日".repeat(3000));
        let rope = Rope::from_str(&format!("{long}{long}"));
        let at = find_literal(&rope, "needle", 0..rope.len_bytes()).unwrap();
        assert_eq!(at, 5000);
        let second = find_literal(&rope, "needle", at + 1..rope.len_bytes()).unwrap();
        assert_eq!(second, long.len() + 5000);
        assert_eq!(
            find_literal(&rope, "日x", 0..rope.len_bytes()),
            Some(long.len() - 3)
        );
    }
}
