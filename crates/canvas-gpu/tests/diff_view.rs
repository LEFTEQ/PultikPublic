//! An agent's change drawn through the code op (workbench AC4, the strongest check before
//! the editor island lands in WP6): code-core's diff of the old and new text, highlighted
//! and coloured by the house theme, laid out inline and side by side by
//! `canvas_text::diff_view` (the one diff view both apps draw with, vt-7887), then rebuilt by
//! the renderer's CPU half. Every row of both layouts draws: every inked char becomes one
//! glyph, every wash, word and filler one cell.

use canvas_draw::{CodeBlock, CodeRows, DisplayList, Op, Rgba, Size};
use canvas_gpu::{Frame, Viewport};
use canvas_text::TextSystem;
use canvas_text::code_view::CodeColors;
use canvas_text::diff_view::{DiffDecor, DiffMetrics, DiffMode, DiffView, ViewRow, single_file};
use code_core::diff::{LineKind, Side, TextDiff};
use code_core::syntax::{self, Language};

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

/// Inked chars across rows: the glyphs the renderer must emit for them.
fn inked(rows: &[&CodeRows]) -> usize {
    rows.iter()
        .flat_map(|r| r.rows.iter().map(|row| r.row_text(row)))
        .flat_map(str::chars)
        .filter(|c| !c.is_whitespace() && !c.is_control())
        .count()
}

/// The view's rows painted, and its code blocks in order (gutter then code, per pane).
fn paint(view: &mut DiffView, colors: &CodeColors) -> (Vec<Op>, Vec<CodeBlock>) {
    let decor = DiffDecor {
        accent: Rgba::new(1.0, 0.6, 0.0, 1.0),
        focused: None,
        marks: &[],
        anchor: None,
        indicator: false,
    };
    let mut ops = Vec::new();
    view.paint(colors, &decor, &|_| String::new(), &mut ops);
    let blocks = ops
        .iter()
        .filter_map(|o| match o {
            Op::Code(c) => Some(c.clone()),
            _ => None,
        })
        .collect();
    (ops, blocks)
}

fn draw(ops: Vec<Op>) -> Frame {
    let mut dl = DisplayList::new(Rgba::BLACK);
    dl.ops = ops;
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

    let metrics = DiffMetrics::for_cell(Size::new(8.0, 17.0), 13.0);
    let mut view = DiffView::new(single_file("main.rs", diff.lines.clone()), metrics, false);
    view.set_tokens(0, Side::Old, old_tokens);
    view.set_tokens(0, Side::New, new_tokens);
    view.resize(Size::new(1440.0, 900.0));
    let (ops, inline) = paint(&mut view, &colors);
    let [gutter, code] = &inline[..] else {
        panic!("one gutter and one code block inline: {}", inline.len());
    };
    let (gutter, code) = (&*gutter.rows, &*code.rows);
    assert_eq!(code.rows.len(), diff.lines.len());
    assert_eq!(gutter.rows.len(), diff.lines.len());
    let washes = [rgba(p.added_line), rgba(p.removed_line), rgba(p.hunk)];
    for (i, line) in diff.lines.iter().enumerate() {
        assert_eq!(code.row_text(&code.rows[i]), line.text);
        let wash = code
            .backgrounds
            .iter()
            .find(|b| b.row == i as u32 && b.start == 0 && washes.contains(&b.color))
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
    let first = &code.rows[1];
    assert_eq!(code.row_text(first), "fn total(items: &[u32]) -> u32 {");
    let keyword = colors.role(theme::SyntaxRole::Keyword);
    assert!(
        code.row_spans(first)
            .iter()
            .any(|s| (s.start, s.end, s.color) == (0, 2, keyword))
    );
    // The renamed call's changed word sits on the word wash, on both of its lines.
    let words: Vec<(u32, u16, u16)> = code
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
    // Through the code op: every inked char of every row is one glyph.
    let frame = draw(ops);
    // The Linux fallback shapes but inks nothing, so only Core Text draws the glyphs.
    if cfg!(target_os = "macos") {
        assert_eq!(frame.glyphs.len(), inked(&[gutter, code]));
    }

    view.set_mode(DiffMode::Split);
    let (ops, split) = paint(&mut view, &colors);
    let [lg, lc, rg, rc] = &split[..] else {
        panic!("a gutter and a code block per side: {}", split.len());
    };
    let (left, right) = (&*lc.rows, &*rc.rows);
    let pairs: Vec<_> = view
        .rows()
        .iter()
        .map(|r| match *r {
            ViewRow::Pair { old, new, .. } => (old, new),
            other => panic!("only pairs side by side: {other:?}"),
        })
        .collect();
    assert_eq!(left.rows.len(), pairs.len());
    assert_eq!(right.rows.len(), pairs.len());
    for (i, &(old, new)) in pairs.iter().enumerate() {
        for (pane, line) in [(left, old), (right, new)] {
            let text = pane.row_text(&pane.rows[i]);
            match line {
                Some(l) => assert_eq!(text, diff.lines[l].text),
                None => {
                    assert_eq!(text, "", "a filler row is blank");
                    assert!(
                        pane.backgrounds
                            .iter()
                            .any(|b| b.row == i as u32 && b.color == rgba(p.gutter)),
                        "a filler row wears the gutter's fill"
                    );
                }
            }
        }
    }
    assert!(
        pairs.iter().any(|(_, new)| new.is_none()),
        "the five removed lines pair with one added line and four fillers"
    );
    let panes = [&*lg.rows, left, &*rg.rows, right];
    let frame = draw(ops);
    if cfg!(target_os = "macos") {
        assert_eq!(frame.glyphs.len(), inked(&panes));
    }
    assert_eq!(
        frame.cells.len(),
        panes.iter().map(|p| p.backgrounds.len()).sum::<usize>(),
        "every wash, word and filler drew as a cell"
    );
}
