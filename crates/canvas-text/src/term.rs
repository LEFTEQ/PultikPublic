//! Terminal text: the terminal font's metrics, the cell geometry derived from them, and
//! per-row run shaping.
//!
//! A row is shaped as runs of same-style cells (bold and italic pick the face; colours do
//! not split runs), then every glyph is pinned to the cell its cluster starts in. The result
//! is in ems, so one shaped row serves every zoom level, and it is cached by the row's
//! content ([`row_key`]): unchanged rows never reshape.

use crate::sprite;
use canvas_draw::cells::{Cell, flags};
use std::hash::{Hash, Hasher};

/// The terminal font's metrics in ems: multiply by a pixel size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TermMetrics {
    pub ascent: f32,
    pub descent: f32,
    pub leading: f32,
    /// The cell advance: the widest printable ASCII glyph.
    pub advance: f32,
    /// Top of the underline, below the baseline.
    pub underline_position: f32,
    pub underline_thickness: f32,
    /// Top of the strikethrough, above the baseline.
    pub strike_position: f32,
    pub strike_thickness: f32,
}

/// Where a cell's baseline and decorations sit, in whole device pixels from the cell top.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellLayout {
    pub baseline: f32,
    pub underline_top: f32,
    pub underline_thickness: f32,
    pub strike_top: f32,
    pub strike_thickness: f32,
    /// Light box-drawing line and cursor bar thickness.
    pub line: f32,
}

impl TermMetrics {
    pub fn line_height(&self) -> f32 {
        self.ascent + self.descent + self.leading
    }

    /// The cell in whole device pixels at pixel size `px`, rounded the way a native terminal
    /// rounds it: width from the advance, height from ascent + descent + leading.
    pub fn cell_px(&self, px: f32) -> (u32, u32) {
        let w = (self.advance * px).round().max(1.0);
        let h = (self.line_height() * px).round().max(1.0);
        (w as u32, h as u32)
    }

    /// Baseline and decorations at pixel size `px` in a row `row_h` pixels tall: the glyph
    /// box (ascent + descent) is centred in the row, so the leading splits above and below.
    pub fn layout(&self, px: f32, row_h: f32) -> CellLayout {
        let baseline = ((row_h - (self.ascent + self.descent) * px) * 0.5 + self.ascent * px)
            .round()
            .clamp(1.0, row_h.max(1.0));
        let line = (self.underline_thickness * px).round().max(1.0);
        let underline_thickness = line.min(row_h.max(1.0));
        let underline_top = (baseline + (self.underline_position * px).round())
            .min(row_h - underline_thickness)
            .max(0.0);
        let strike_thickness = (self.strike_thickness * px).round().max(1.0);
        let strike_top = (baseline - (self.strike_position * px).round()).max(0.0);
        CellLayout {
            baseline,
            underline_top,
            underline_thickness,
            strike_top,
            strike_thickness,
            line,
        }
    }
}

/// One glyph of a shaped terminal row, pinned to its cell.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellGlyph {
    /// Column of the cell the glyph's cluster starts in.
    pub col: u16,
    /// Cells the cluster covers: 2 for a wide char.
    pub span: u8,
    pub font: u16,
    pub glyph: u32,
    /// Pen offset in ems from the left of `span` font advances; the renderer centres that box
    /// in the span's (pixel-rounded) cells.
    pub x: f32,
    /// Offset from the baseline in ems, y down.
    pub y: f32,
    /// Raster size relative to the font size: below 1 for a colour glyph fitted to its span.
    pub scale: f32,
    /// From a colour font (emoji): drawn from the RGBA page, untinted.
    pub color: bool,
}

/// A terminal row's glyphs, in ems. Blank cells and sprite cells have none.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ShapedRow {
    pub glyphs: Vec<CellGlyph>,
}

/// One glyph out of the platform shaper, in ems at the shaping size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct RunGlyph {
    /// UTF-16 offset of the glyph's cluster in the run string.
    pub index: usize,
    pub font: u16,
    pub glyph: u32,
    pub x: f32,
    pub y: f32,
    pub advance: f32,
    pub color: bool,
}

/// The flags that change shaping (the face, or which cells hold text).
const SHAPING_FLAGS: u16 = flags::BOLD | flags::ITALIC | flags::WIDE | flags::WIDE_SPACER;

/// The font slot of a cell: 0 regular, 1 bold, 2 italic, 3 bold italic.
pub(crate) fn style_of(cell: &Cell) -> usize {
    usize::from(cell.flags & flags::BOLD != 0) | (usize::from(cell.flags & flags::ITALIC != 0) << 1)
}

/// What a shaped row depends on: each cell's text and shaping flags (not its colours).
pub(crate) fn row_key(cells: &[Cell]) -> (u64, u32) {
    let mut h = std::hash::DefaultHasher::new();
    for c in cells {
        c.text.hash(&mut h);
        (c.flags & SHAPING_FLAGS).hash(&mut h);
    }
    (h.finish(), cells.len() as u32)
}

/// Whether a cell has a font glyph to shape (not blank, not a spacer, not one of our sprites).
pub(crate) fn has_text(cell: &Cell) -> bool {
    cell.flags & flags::WIDE_SPACER == 0
        && !cell.text.is_empty()
        && cell.text != " "
        && sprite::cell_sprite(&cell.text).is_none()
}

/// One cell's place in a run string.
#[derive(Clone, Copy)]
struct Slot {
    utf16: usize,
    col: u16,
    span: u8,
    text: bool,
    /// Pen x of the cluster's first glyph and the cluster's total advance (ems).
    x0: Option<f32>,
    advance: f32,
    color: bool,
}

/// Reused buffers for shaping misses.
#[derive(Default)]
pub(crate) struct Scratch {
    text: String,
    slots: Vec<Slot>,
    glyphs: Vec<RunGlyph>,
}

/// One slot of a row to shape: its text, the column it starts at, the columns it spans, its
/// font slot ([`style_of`]), and whether it has a font glyph (`ink`; a blank or a sprite
/// holds its place as a space).
#[derive(Debug, Clone, Copy)]
pub(crate) struct SlotIn<'a> {
    pub text: &'a str,
    pub col: u16,
    pub span: u8,
    pub style: usize,
    pub ink: bool,
}

/// Shape `cells` with `shape_run(text, style, out)`, the platform's run shaper, splitting runs
/// only where the style changes. `advance` is the cell advance in ems.
pub(crate) fn shape_row(
    cells: &[Cell],
    advance: f32,
    scratch: &mut Scratch,
    shape_run: impl FnMut(&str, usize, &mut Vec<RunGlyph>),
) -> ShapedRow {
    let slot = |i: usize| {
        let cell = &cells[i];
        (cell.flags & flags::WIDE_SPACER == 0).then(|| SlotIn {
            text: &cell.text,
            col: i as u16,
            span: if cell.flags & flags::WIDE != 0 { 2 } else { 1 },
            style: style_of(cell),
            ink: has_text(cell),
        })
    };
    shape_slots(cells.len(), slot, advance, scratch, shape_run)
}

/// Shape a row of `n` slots, `slot(i)` each (`None`: a slot with no place of its own, a wide
/// char's spacer), in runs split only where the style changes, then pin every glyph to the
/// slot its cluster starts in. Terminal rows and code rows ([`crate::code`]) both shape here.
pub(crate) fn shape_slots<'a>(
    n: usize,
    slot: impl Fn(usize) -> Option<SlotIn<'a>>,
    advance: f32,
    scratch: &mut Scratch,
    mut shape_run: impl FnMut(&str, usize, &mut Vec<RunGlyph>),
) -> ShapedRow {
    let ink = |i: usize| slot(i).filter(|s| s.ink);
    let mut out = ShapedRow::default();
    let mut i = 0;
    while i < n {
        let Some(first) = ink(i) else {
            i += 1;
            continue;
        };
        // A run starts at an inked slot and takes every following slot of its style; blanks
        // and sprites in between never split it, and trailing ones are left out.
        let style = first.style;
        let start = i;
        let mut end = i + 1;
        while i < n {
            match ink(i) {
                Some(s) if s.style != style => break,
                Some(_) => end = i + 1,
                None => {}
            }
            i += 1;
        }
        scratch.text.clear();
        scratch.slots.clear();
        let mut utf16 = 0;
        for s in (start..end).filter_map(&slot) {
            // Blanks and sprites keep their place as a space, so the run stays one line.
            let text = if s.ink { s.text } else { " " };
            scratch.slots.push(Slot {
                utf16,
                col: s.col,
                span: s.span,
                text: s.ink,
                x0: None,
                advance: 0.0,
                color: false,
            });
            scratch.text.push_str(text);
            utf16 += text.encode_utf16().count();
        }
        scratch.glyphs.clear();
        shape_run(&scratch.text, style, &mut scratch.glyphs);
        let slot_of = |slots: &[Slot], index: usize| {
            slots
                .partition_point(|s| s.utf16 <= index)
                .saturating_sub(1)
        };
        for g in &scratch.glyphs {
            let at = slot_of(&scratch.slots, g.index);
            let s = &mut scratch.slots[at];
            s.x0.get_or_insert(g.x);
            s.advance += g.advance;
            s.color |= g.color;
        }
        for g in &scratch.glyphs {
            let s = scratch.slots[slot_of(&scratch.slots, g.index)];
            if !s.text {
                continue;
            }
            let room = s.span as f32 * advance;
            // A colour glyph (emoji) is scaled down to fit its cells; text is centred as is.
            let scale = if s.color && s.advance > room {
                room / s.advance
            } else {
                1.0
            };
            let dx = g.x - s.x0.unwrap_or(g.x);
            out.glyphs.push(CellGlyph {
                col: s.col,
                span: s.span,
                font: g.font,
                glyph: g.glyph,
                x: (room - s.advance * scale) * 0.5 + dx * scale,
                y: g.y * scale,
                scale,
                color: g.color,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(text: &str, flags: u16) -> Cell {
        Cell {
            text: text.into(),
            flags,
            ..Cell::default()
        }
    }

    /// A shaper that gives every char one glyph of the char's code, `adv` ems wide, and
    /// records the runs it was asked for.
    fn fake(
        adv: f32,
        runs: &mut Vec<(String, usize)>,
    ) -> impl FnMut(&str, usize, &mut Vec<RunGlyph>) + '_ {
        move |text, style, out| {
            runs.push((text.to_owned(), style));
            let mut x = 0.0;
            let mut index = 0;
            for c in text.chars() {
                out.push(RunGlyph {
                    index,
                    font: 0,
                    glyph: c as u32,
                    x,
                    y: 0.0,
                    advance: if c.is_ascii() { adv } else { 2.0 * adv },
                    color: c == '😀',
                });
                x += if c.is_ascii() { adv } else { 2.0 * adv };
                index += c.len_utf16();
            }
        }
    }

    #[test]
    fn runs_split_by_style_and_glyphs_land_on_their_cells() {
        let mut red = cell("d", 0);
        red.fg = canvas_draw::cells::Rgb(255, 0, 0);
        let cells = vec![
            cell(" ", flags::BOLD),
            cell("a", 0),
            cell("", 0),
            cell("─", 0),
            red,
            cell("b", flags::BOLD),
            cell("日", flags::BOLD | flags::WIDE),
            cell("", flags::WIDE_SPACER),
            cell("c", flags::BOLD),
            cell(" ", 0),
        ];
        let mut runs = Vec::new();
        let row = shape_row(&cells, 0.6, &mut Scratch::default(), fake(0.6, &mut runs));
        assert_eq!(
            runs,
            vec![("a  d".to_owned(), 0), ("b日c".to_owned(), 1)],
            "colours never split a run; blanks and sprites hold their place"
        );
        let placed: Vec<(u16, u8, u32)> = row
            .glyphs
            .iter()
            .map(|g| (g.col, g.span, g.glyph))
            .collect();
        assert_eq!(
            placed,
            vec![
                (1, 1, 'a' as u32),
                (4, 1, 'd' as u32),
                (5, 1, 'b' as u32),
                (6, 2, '日' as u32),
                (8, 1, 'c' as u32)
            ]
        );
        assert!(
            row.glyphs.iter().all(|g| g.x.abs() < 1e-6),
            "pinned to the cell origin"
        );
    }

    #[test]
    fn colour_glyphs_shrink_to_their_cells() {
        let cells = vec![cell("😀", flags::WIDE), cell("", flags::WIDE_SPACER)];
        let mut runs = Vec::new();
        // The emoji is 1.6 ems wide; two cells hold 1.2.
        let row = shape_row(&cells, 0.6, &mut Scratch::default(), |t, s, out| {
            runs.push((t.to_owned(), s));
            out.push(RunGlyph {
                index: 0,
                font: 1,
                glyph: 7,
                x: 0.0,
                y: 0.0,
                advance: 1.6,
                color: true,
            });
        });
        let g = row.glyphs[0];
        assert!((g.scale - 0.75).abs() < 1e-6, "{g:?}");
        assert!(g.x.abs() < 1e-6, "scaled to exactly the span: {g:?}");
    }

    #[test]
    fn the_row_key_ignores_colours_but_not_text_or_style() {
        let base = vec![cell("a", 0), cell("b", 0)];
        let mut recoloured = base.clone();
        recoloured[0].fg = canvas_draw::cells::Rgb(1, 2, 3);
        let mut bold = base.clone();
        bold[1].flags = flags::BOLD;
        let mut edited = base.clone();
        edited[1].text = "c".into();
        assert_eq!(row_key(&base), row_key(&recoloured));
        assert_ne!(row_key(&base), row_key(&bold));
        assert_ne!(row_key(&base), row_key(&edited));
    }

    #[test]
    fn monaco_13_at_2x_is_a_16_by_35_cell() {
        // Monaco's Core Text metrics in ems (13 pt: ascent 13, descent 3.25, leading 1.085,
        // advance 7.801, underline −0.489 / 0.984).
        let m = TermMetrics {
            ascent: 1.0,
            descent: 0.25,
            leading: 1.085_449_2 / 13.0,
            advance: 7.801_27 / 13.0,
            underline_position: 0.488_77 / 13.0,
            underline_thickness: 0.983_89 / 13.0,
            strike_position: 0.31,
            strike_thickness: 0.983_89 / 13.0,
        };
        assert_eq!(m.cell_px(26.0), (16, 35));
        assert_eq!(m.cell_px(13.0), (8, 17));
        let l = m.layout(26.0, 35.0);
        assert_eq!(
            (l.baseline, l.underline_top, l.underline_thickness),
            (27.0, 28.0, 2.0)
        );
        assert_eq!((l.strike_top, l.line), (19.0, 2.0));
    }
}
