//! Code rows: one row of code shaped from its text and every char's column, as code-core's
//! layout hands them over (`code_core::Layout::text` and `cols`), through the terminal's
//! run shaper ([`term::shape_slots`]): glyphs are pinned to columns exactly as terminal
//! cells are, in ems, and cached by the row's content.
//!
//! A char's width is the next column minus its own: wide chars span two columns and are
//! centred in them, tabs, spaces and controls hold their place without a glyph, and a
//! zero-width char joins the cluster before it. Colours never split a run (the renderer
//! tints glyphs by column); a bold or italic span does, since its face is another font.

use crate::term::{self, RunGlyph, ShapedRow, SlotIn};
use canvas_draw::ColorSpan;
use std::hash::{Hash, Hasher};

/// One cluster of a code row: its bytes in the row's text, its column, width and face.
#[derive(Debug, Clone, Copy)]
struct Cluster {
    start: u32,
    end: u32,
    col: u16,
    span: u8,
    style: u8,
    ink: bool,
}

/// Reused buffers for shaping misses.
#[derive(Default)]
pub(crate) struct Scratch {
    clusters: Vec<Cluster>,
}

/// What a shaped code row depends on: its text, its columns and its spans' faces (not their
/// colours: a row in regular faces keys as it did before spans had faces).
pub(crate) fn row_key(text: &str, cols: &[u16], spans: &[ColorSpan]) -> (u64, u32) {
    let mut h = std::hash::DefaultHasher::new();
    text.hash(&mut h);
    cols.hash(&mut h);
    for s in spans.iter().filter(|s| s.style != 0) {
        (s.start, s.end, s.style).hash(&mut h);
    }
    (h.finish(), text.len() as u32)
}

/// Shape a code row: `cols` holds each char's column, then the row's end column; `spans`
/// (ascending, not overlapping) give the clusters they cover their face.
pub(crate) fn shape_row(
    text: &str,
    cols: &[u16],
    spans: &[ColorSpan],
    advance: f32,
    scratch: &mut Scratch,
    runs: &mut term::Scratch,
    shape_run: impl FnMut(&str, usize, &mut Vec<RunGlyph>),
) -> ShapedRow {
    scratch.clusters.clear();
    let mut k = 0;
    for (i, (at, c)) in text.char_indices().enumerate() {
        let (Some(&col), Some(&next)) = (cols.get(i), cols.get(i + 1)) else {
            break;
        };
        let end = (at + c.len_utf8()) as u32;
        let span = next.saturating_sub(col);
        if span == 0
            && let Some(last) = scratch.clusters.last_mut()
        {
            last.end = end;
            continue;
        }
        while spans.get(k).is_some_and(|s| s.end <= col) {
            k += 1;
        }
        let style = spans
            .get(k)
            .filter(|s| s.start <= col)
            .map_or(0, |s| s.style);
        scratch.clusters.push(Cluster {
            start: at as u32,
            end,
            col,
            span: span.clamp(1, u16::from(u8::MAX)) as u8,
            style,
            ink: !c.is_whitespace() && !c.is_control(),
        });
    }
    let clusters = &scratch.clusters;
    let slot = |i: usize| {
        let c = clusters[i];
        Some(SlotIn {
            text: &text[c.start as usize..c.end as usize],
            col: c.col,
            span: c.span,
            style: usize::from(c.style),
            ink: c.ink,
        })
    };
    term::shape_slots(clusters.len(), slot, advance, runs, shape_run)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glyphs_land_on_their_columns() {
        // "a\tb日e\u{301} c" as code-core lays it out: the tab runs from 1 to 4.
        let text = "a\tb日e\u{301} c";
        let cols = [0, 1, 4, 5, 7, 8, 8, 9, 10];
        let mut runs = Vec::new();
        let row = shape_row(
            text,
            &cols,
            &[],
            0.6,
            &mut Scratch::default(),
            &mut term::Scratch::default(),
            |t, style, out| {
                runs.push(t.to_owned());
                let mut index = 0;
                for c in t.chars() {
                    out.push(RunGlyph {
                        index,
                        font: 0,
                        glyph: c as u32,
                        x: 0.0,
                        y: 0.0,
                        advance: 0.6,
                        color: false,
                    });
                    index += c.len_utf16();
                    assert_eq!(style, 0);
                }
            },
        );
        assert_eq!(
            runs,
            vec!["a b日e\u{301} c".to_owned()],
            "one run; the tab holds its place as a space"
        );
        let placed: Vec<(u16, u8, u32)> = row
            .glyphs
            .iter()
            .map(|g| (g.col, g.span, g.glyph))
            .collect();
        assert_eq!(
            placed,
            vec![
                (0, 1, 'a' as u32),
                (4, 1, 'b' as u32),
                (5, 2, '日' as u32),
                (7, 1, 'e' as u32),
                (7, 1, 0x301),
                (9, 1, 'c' as u32)
            ],
            "the mark joins its base's cluster"
        );
    }

    #[test]
    fn a_bold_or_italic_span_splits_the_run_and_keys_the_row() {
        use canvas_draw::Rgba;
        let text = "fn f() // note";
        let cols: Vec<u16> = (0..=text.len() as u16).collect();
        let span = |start, end, color, style| ColorSpan {
            start,
            end,
            color,
            style,
        };
        let italic = [span(0, 2, Rgba::WHITE, 0), span(7, 14, Rgba::WHITE, 2)];
        let mut runs = Vec::new();
        shape_row(
            text,
            &cols,
            &italic,
            0.6,
            &mut Scratch::default(),
            &mut term::Scratch::default(),
            |t, style, _| runs.push((t.to_owned(), style)),
        );
        assert_eq!(
            runs.iter().map(|(_, style)| *style).collect::<Vec<_>>(),
            [0, 2],
            "{runs:?}"
        );
        assert!(runs[1].0.starts_with("//"), "{runs:?}");
        let recoloured = [span(0, 2, Rgba::BLACK, 0), span(7, 14, Rgba::BLACK, 2)];
        assert_eq!(
            row_key(text, &cols, &italic),
            row_key(text, &cols, &recoloured)
        );
        assert_ne!(
            row_key(text, &cols, &italic),
            row_key(text, &cols, &italic[..1])
        );
        assert_eq!(
            row_key(text, &cols, &italic[..1]),
            row_key(text, &cols, &[])
        );
    }
}
