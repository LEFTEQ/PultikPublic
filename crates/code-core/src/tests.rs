//! Properties over random text and edits, each against a naive model written the plain way.
//! Unit tests build with tiny chunks (`lines::CHUNK`), so small documents cross chunk
//! boundaries and edits split, merge and absorb chunks.

use crate::{Buffer, Layout, MIN_WRAP, Point, Pos, Viewport, width_at};
use proptest::prelude::*;

mod editing;

/// Text from the pieces that stress columns and lines: tabs, wide chars, emoji, combining
/// marks with and without a base, CRLF, lone CRs and long runs.
fn text(max: usize) -> impl Strategy<Value = String> {
    let piece = prop_oneof![
        Just("a"),
        Just("bc"),
        Just("\t"),
        Just("日"),
        Just("😀"),
        Just("e\u{301}"),
        Just("\u{301}"),
        Just(" "),
        Just("\n"),
        Just("\n\n"),
        Just("\r\n"),
        Just("\r"),
        Just("xxxxxxxxxxxxx"),
    ];
    prop::collection::vec(piece, 0..max).prop_map(|p| p.concat())
}

/// An edit as (start, end, text); positions are taken modulo the text's chars + 1.
fn edits() -> impl Strategy<Value = Vec<(usize, usize, String, Option<u32>)>> {
    let wrap = prop_oneof![Just(None), (1u32..14).prop_map(Some)];
    prop::collection::vec((0usize..400, 0usize..400, text(6), wrap), 1..24)
}

/// Lines as tree-sitter rows: (chars without the line ending, bytes with it).
fn naive_lines(text: &str) -> Vec<(&str, usize)> {
    let parts: Vec<&str> = text.split('\n').collect();
    let last = parts.len() - 1;
    parts
        .iter()
        .enumerate()
        .map(|(i, p)| match i < last {
            true => (p.strip_suffix('\r').unwrap_or(p), p.len() + 1),
            false => (*p, p.len()),
        })
        .collect()
}

fn naive_width(line: &str) -> (u32, Vec<u32>) {
    let (mut col, mut wides) = (0, Vec::new());
    for c in line.chars() {
        let w = width_at(c, col);
        if w == 2 && c != '\t' {
            wides.push(col);
        }
        col += w;
    }
    (col, wides)
}

/// One line's rows, the plain way: walk with the column in the current row; a char that
/// starts at or past the row's end opens the next row (a tab's overflow carries over), a
/// wide char that would straddle the end moves whole, a zero-width char stays put. Each
/// row is its chars and their columns, then its end column.
fn naive_rows(line: &str, wrap: Option<u32>) -> Vec<(String, Vec<u16>)> {
    fn end(rows: &mut Vec<(String, Vec<u16>)>, x: u32) {
        let row = rows.last_mut().expect("a row is open");
        row.1.push(if row.0.is_empty() { 0 } else { x as u16 });
        rows.push(Default::default());
    }
    let cols = wrap.map_or(u32::MAX, |c| c.max(MIN_WRAP));
    let mut rows = vec![(String::new(), Vec::new())];
    let (mut x, mut col) = (0u32, 0u32);
    for c in line.chars() {
        let w = width_at(c, col);
        if w > 0 {
            while x >= cols {
                end(&mut rows, x);
                x -= cols;
            }
            if w == 2 && c != '\t' && x > 0 && x + 2 > cols {
                end(&mut rows, x);
                x = 0;
            }
        }
        let row = rows.last_mut().expect("a row is open");
        row.0.push(c);
        row.1.push(x as u16);
        x += w;
        col += w;
    }
    while x > cols {
        end(&mut rows, x);
        x -= cols;
    }
    end(&mut rows, x);
    rows.pop();
    rows
}

/// An unwrapped row clipped to `cols` visible columns, as layout clips it.
fn clip((text, xs): (String, Vec<u16>), cols: u32) -> (String, Vec<u16>) {
    let chars: Vec<char> = text.chars().collect();
    let keep = (0..chars.len())
        .find(|&i| xs[i + 1] > xs[i] && u32::from(xs[i]) >= cols)
        .unwrap_or(chars.len());
    (chars[..keep].iter().collect(), xs[..=keep].to_vec())
}

fn char_to_byte(s: &str, c: usize) -> usize {
    s.char_indices().nth(c).map_or(s.len(), |(b, _)| b)
}

fn point(s: &str, byte: usize) -> Point {
    let before = &s[..byte];
    Point {
        row: before.matches('\n').count(),
        column: byte - before.rfind('\n').map_or(0, |i| i + 1),
    }
}

fn pos(s: &str, char: usize) -> Pos {
    let byte = char_to_byte(s, char);
    Pos {
        char,
        byte,
        point: point(s, byte),
    }
}

/// Every answer the index gives about `model`, against the naive scan.
fn check_index(buf: &Buffer, model: &str) {
    let ix = buf.lines();
    let wrap = ix.wrap();
    let lines = naive_lines(model);
    assert_eq!(ix.len_lines(), lines.len());
    assert_eq!(ix.len_bytes(), model.len());
    let (mut row, mut byte) = (0u64, 0usize);
    let mut starts = Vec::new();
    for (l, (chars, bytes)) in lines.iter().enumerate() {
        let info = ix.line(l);
        let (width, wides) = naive_width(chars);
        assert_eq!(
            (info.bytes, info.width, info.wides),
            (*bytes, width, wides.as_slice()),
            "line {l} {chars:?}"
        );
        let rows = naive_rows(chars, wrap).len() as u32;
        assert_eq!(ix.line_rows(l), rows, "line {l} {chars:?} at {wrap:?}");
        assert_eq!(ix.line_to_row(l), row);
        assert_eq!(ix.line_to_byte(l), byte);
        for seg in 0..rows {
            assert_eq!(ix.row_to_line(row + u64::from(seg)), (l, seg));
        }
        starts.push(byte);
        row += u64::from(rows);
        byte += bytes;
    }
    assert_eq!(ix.rows(), row);
    let from: Vec<(usize, usize)> = ix.lines_from(0).map(|(l, b, _)| (l, b)).collect();
    assert_eq!(from, starts.into_iter().enumerate().collect::<Vec<_>>());
    for (b, _) in model.char_indices().chain([(model.len(), ' ')]) {
        let p = point(model, b);
        assert_eq!(ix.byte_to_point(b), (p.row, p.column), "byte {b}");
    }
}

proptest! {
    #[test]
    fn edits_report_their_points_and_the_rope_matches_a_string(
        start in text(40),
        edits in edits(),
    ) {
        let mut buf = Buffer::from_text(&start);
        let mut model = start;
        for (a, b, text, _) in edits {
            let n = model.chars().count() + 1;
            let (a, b) = ((a % n).min(b % n), (a % n).max(b % n));
            let removed = &model[char_to_byte(&model, a)..char_to_byte(&model, b)];
            let (lines_removed, lines_added) = (removed.matches('\n').count(), text.matches('\n').count());
            let (start, old_end) = (pos(&model, a), pos(&model, b));
            model.replace_range(start.byte..old_end.byte, &text);
            let new_end = pos(&model, a + text.chars().count());
            let edit = buf.edit(a..b, &text);
            prop_assert_eq!((edit.start, edit.old_end, edit.new_end), (start, old_end, new_end));
            prop_assert_eq!((edit.lines_removed, edit.lines_added), (lines_removed, lines_added));
            prop_assert_eq!(edit.revision, buf.revision());
            prop_assert_eq!(buf.rope().to_string(), model.as_str());
        }
    }

    #[test]
    fn the_index_agrees_with_a_naive_scan_after_edits_and_wrap_changes(
        start in text(80),
        edits in edits(),
    ) {
        let mut buf = Buffer::from_text(&start);
        let mut model = start;
        check_index(&buf, &model);
        for (a, b, text, wrap) in edits {
            let n = model.chars().count() + 1;
            let (a, b) = ((a % n).min(b % n), (a % n).max(b % n));
            model.replace_range(char_to_byte(&model, a)..char_to_byte(&model, b), &text);
            buf.edit(a..b, &text);
            check_index(&buf, &model);
            buf.set_wrap(wrap);
            check_index(&buf, &model);
        }
    }

    #[test]
    fn layout_rows_equal_a_naive_wrap_of_the_same_text(
        text in text(60),
        wrap in prop::option::of(1u32..14),
        cols in 1u32..14,
        top in 0u64..40,
        rows in 1u32..12,
    ) {
        let vp = Viewport { top, offset: 0.0, rows, cols: wrap.unwrap_or(cols), wrap: wrap.is_some() };
        let mut buf = Buffer::from_text(&text);
        buf.set_wrap(vp.wrap_cols());
        let mut layout = Layout::default();
        layout.build(&buf, &vp);
        let got: Vec<(usize, u32, String, Vec<u16>)> = layout
            .rows()
            .iter()
            .map(|r| (r.line, r.segment, layout.text(r).to_owned(), layout.cols(r).to_vec()))
            .collect();
        let want: Vec<(usize, u32, String, Vec<u16>)> = naive_lines(&text)
            .iter()
            .enumerate()
            .flat_map(|(l, (chars, _))| {
                naive_rows(chars, vp.wrap_cols())
                    .into_iter()
                    .enumerate()
                    .map(move |(s, row)| {
                        let (t, xs) = if wrap.is_some() { row } else { clip(row, cols) };
                        (l, s as u32, t, xs)
                    })
            })
            .skip(top as usize)
            .take(rows as usize)
            .collect();
        prop_assert_eq!(got, want);
        for r in layout.rows() {
            let chars = &text[r.bytes.clone()];
            prop_assert_eq!(chars, layout.text(r), "a row's bytes are its text");
        }
    }
}
