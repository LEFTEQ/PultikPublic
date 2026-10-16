//! An agent's change drawn through the code op (workbench AC4, the strongest check before
//! the editor island lands in WP6): code-core's diff of the old and new text, highlighted
//! and coloured by the house theme, laid out inline and side by side by
//! `canvas_text::code_view`, then rebuilt by the renderer's CPU half. Every row of both
//! layouts draws: every inked char becomes one glyph, every wash, word and filler one cell.

use canvas_draw::{CodeBlock, CodeRows, DisplayList, Point, Rgba, Size};
use canvas_gpu::{Frame, Viewport};
use canvas_text::TextSystem;
use canvas_text::code_view::{CodeColors, DiffPane, push_inline, push_split};
use code_core::diff::{LineKind, SplitRow, TextDiff};
use code_core::syntax::{self, Language};
use std::sync::Arc;
use theme::SyntaxRole;

const OLD: &str = "fn total(items: &[u32]) -> u32 {\n    let mut sum = 0;\n    for i in items {\n        sum += i;\n    }\n    sum\n}\n\nfn main() {\n    println!(\"{}\", total(&[1, 2]));\n}\n";

/// The Edit tool's payload: `old_string` replaced by `new_string`, once.
fn agent_edit() -> String {
    OLD.replacen(
        "    let mut sum = 0;\n    for i in items {\n        sum += i;\n    }\n    sum\n",
        "    items.iter().sum()\n",
        1,
    )
    .replacen("total(&[1, 2])", "grand_total(&[1, 2])", 1)
}

fn block(x: f32, rows: &CodeRows) -> CodeBlock {
    CodeBlock {
        origin: Point::new(x, 0.0),
        cell: Size::new(8.0, 17.0),
        font_size: 13.0,
        rows: Arc::new(rows.clone()),
    }
}

/// Inked chars across rows: the glyphs the renderer must emit for them.
fn inked(rows: &[&CodeRows]) -> usize {
    rows.iter()
        .flat_map(|r| r.rows.iter().map(|row| r.row_text(row)))
        .flat_map(str::chars)
        .filter(|c| !c.is_whitespace() && !c.is_control())
        .count()
}

fn draw(blocks: &[CodeBlock]) -> Frame {
    let mut dl = DisplayList::new(Rgba::BLACK);
    for b in blocks {
        dl.code(b.clone());
    }
    let mut text = TextSystem::new();
    text.set_term_font(None, 13.0);
    let mut frame = Frame::default();
    let vp = Viewport {
        width_px: 2880,
        height_px: 1800,
        scale: 2.0,
    };
    frame.rebuild(&dl, &mut text, vp);
    frame
}

#[test]
fn an_agents_change_draws_inline_and_side_by_side() {
    let new = agent_edit();
    let diff = TextDiff::new(OLD, &new, 3);
    let old_tokens = syntax::highlight(OLD, Language::Rust).expect("highlights");
    let new_tokens = syntax::highlight(&new, Language::Rust).expect("highlights");
    let colors = CodeColors::new(theme::default_theme());
    let p = *colors.palette();
    let rgba = |c: theme::Rgba| Rgba::new(c.r, c.g, c.b, c.a);

    let mut inline = DiffPane::default();
    push_inline(&mut inline, &diff, (&old_tokens, &new_tokens), &colors, 80);
    assert_eq!(inline.code.rows.len(), diff.lines.len());
    assert_eq!(inline.gutter.rows.len(), diff.lines.len());
    for (i, line) in diff.lines.iter().enumerate() {
        assert_eq!(inline.code.row_text(&inline.code.rows[i]), line.text);
        let wash = inline
            .code
            .backgrounds
            .iter()
            .find(|b| b.row == i as u32 && b.start == 0 && b.end == 80)
            .map(|b| b.color);
        let expected = match line.kind {
            LineKind::Added => Some(rgba(p.added_line)),
            LineKind::Removed => Some(rgba(p.removed_line)),
            LineKind::Hunk => Some(rgba(p.hunk)),
            LineKind::Context | LineKind::Note => None,
        };
        assert_eq!(wash, expected, "row {i}: {:?}", line.kind);
    }
    // `fn` on the first context line wears the theme's keyword colour.
    let first = &inline.code.rows[1];
    assert_eq!(
        inline.code.row_text(first),
        "fn total(items: &[u32]) -> u32 {"
    );
    let keyword = colors.role(SyntaxRole::Keyword);
    assert!(
        inline
            .code
            .row_spans(first)
            .iter()
            .any(|s| (s.start, s.end, s.color) == (0, 2, keyword))
    );
    // The renamed call's changed word sits on the word wash, on both of its lines.
    let words: Vec<(u32, u16, u16)> = inline
        .code
        .backgrounds
        .iter()
        .filter(|b| b.color == rgba(p.added_word) || b.color == rgba(p.removed_word))
        .map(|b| (b.row, b.start, b.end))
        .collect();
    let renamed = |kind: LineKind| {
        diff.lines
            .iter()
            .position(|l| l.kind == kind && l.text.contains("total(&[1, 2])"))
            .expect("the renamed call") as u32
    };
    assert_eq!(
        words,
        [
            (renamed(LineKind::Removed), 19, 24),
            (renamed(LineKind::Added), 19, 30)
        ]
    );

    let (mut left, mut right) = (DiffPane::default(), DiffPane::default());
    push_split(
        (&mut left, &mut right),
        &diff,
        (&old_tokens, &new_tokens),
        &colors,
        60,
    );
    assert_eq!(left.code.rows.len(), diff.split.len());
    assert_eq!(right.code.rows.len(), diff.split.len());
    for (i, row) in diff.split.iter().enumerate() {
        let SplitRow::Pair { old, new } = *row else {
            continue;
        };
        for (pane, line) in [(&left, old), (&right, new)] {
            let text = pane.code.row_text(&pane.code.rows[i]);
            match line {
                Some(l) => assert_eq!(text, diff.lines[l].text),
                None => {
                    assert_eq!(text, "", "a filler row is blank");
                    assert!(
                        pane.code
                            .backgrounds
                            .iter()
                            .any(|b| b.row == i as u32 && b.color == rgba(p.gutter)),
                        "a filler row wears the gutter's fill"
                    );
                }
            }
        }
    }
    assert!(
        diff.split
            .iter()
            .any(|r| matches!(r, SplitRow::Pair { new: None, .. })),
        "the five removed lines pair with one added line and four fillers"
    );

    // Both layouts through the code op: every inked char of every row is one glyph.
    let inline_frame = draw(&[block(0.0, &inline.gutter), block(80.0, &inline.code)]);
    assert_eq!(
        inline_frame.glyphs.len(),
        inked(&[&inline.gutter, &inline.code])
    );
    let split_frame = draw(&[
        block(0.0, &left.gutter),
        block(48.0, &left.code),
        block(720.0, &right.gutter),
        block(768.0, &right.code),
    ]);
    assert_eq!(
        split_frame.glyphs.len(),
        inked(&[&left.gutter, &left.code, &right.gutter, &right.code])
    );
    let panes = [&left.gutter, &left.code, &right.gutter, &right.code];
    assert_eq!(
        split_frame.cells.len(),
        panes.iter().map(|p| p.backgrounds.len()).sum::<usize>(),
        "every wash, word and filler drew as a cell"
    );
}
