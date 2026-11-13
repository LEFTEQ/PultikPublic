//! Shaping a string in one bundled face, and breaking the result into lines.
//!
//! Positions stay in font units, harfrust's integers: no float enters a run, so the same text
//! in the same file shapes to the same run on every architecture. Points come only from
//! [`ShapedRun::scale`], at the moment a caller places the run.

use super::{BundledError, BundledFonts, FaceId, FaceMetrics, Features};
use harfrust::{Buffer, Direction, Feature, Script, ShapeOptions, ShaperFont, Tag};
use std::ops::Range;
use unicode_linebreak::BreakOpportunity;

/// One shaped glyph, in font units.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Glyph {
    pub id: u32,
    /// How far the pen moves after this glyph, kerning included.
    pub advance: i32,
    /// Where the glyph is drawn from the pen, x right and y up as fonts measure.
    pub x_offset: i32,
    pub y_offset: i32,
    /// The byte offset in the run's text of the first char this glyph draws (its cluster).
    pub cluster: u32,
}

/// A place a line may (or must) end: UAX #14's opportunities in the run's text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Break {
    /// The first glyph of the line this break starts.
    pub glyph: u32,
    /// The byte offset in the text where that line starts. Two breaks share a glyph after an
    /// empty line, never a byte.
    pub byte: u32,
    /// A line must end here (after a newline), rather than may.
    pub mandatory: bool,
}

/// One line of a broken run.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Line {
    /// The line's glyphs, its trailing whitespace left out.
    pub glyphs: Range<usize>,
    /// The line's text in the run's text, its trailing whitespace and newline left out: what a
    /// caller hands `Op::Text` to draw the line.
    pub text: Range<usize>,
    /// The width of `glyphs` in font units.
    pub width: i64,
}

/// A string shaped in one face: left to right, one glyph per cluster or more, newlines
/// dropped (they become mandatory breaks).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShapedRun {
    pub text: String,
    pub face: FaceId,
    pub features: Features,
    pub metrics: FaceMetrics,
    pub glyphs: Vec<Glyph>,
    /// Line-break opportunities in text order, the text's end left out.
    pub breaks: Vec<Break>,
}

impl BundledFonts {
    /// Shape `text` in `face`. Deterministic: the same text, face and features give the same run
    /// on every platform.
    pub fn shape(
        &self,
        text: &str,
        face: FaceId,
        features: Features,
    ) -> Result<ShapedRun, BundledError> {
        let f = self.get(face)?;
        let shaper = ShaperFont::new(&f.font);
        let plan = &f.plans[usize::from(features.tabular)];
        let mut buffer = Buffer::new();
        let mut glyphs = Vec::with_capacity(text.len());
        let mut ranges = Vec::new();
        // Each line between newlines is shaped on its own: a newline is a break, not a glyph.
        let mut start = 0usize;
        for line in text.split('\n') {
            let shaped = line.strip_suffix('\r').unwrap_or(line);
            if !shaped.is_empty() {
                buffer.clear();
                buffer.push_str(shaped);
                buffer.set_direction(Direction::LeftToRight);
                buffer.set_script(Some(Script::LATIN));
                ranges.clear();
                if features.tabular {
                    figures(shaped, &mut ranges);
                }
                let options = ShapeOptions::new().plan(Some(plan)).features(&ranges);
                harfrust::shape(&shaper, &mut buffer, options).map_err(BundledError::Shape)?;
                let base = start as u32;
                glyphs.extend(
                    buffer
                        .glyph_infos()
                        .iter()
                        .zip(buffer.glyph_positions())
                        .map(|(info, pos)| Glyph {
                            id: info.glyph_id,
                            advance: pos.x_advance,
                            x_offset: pos.x_offset,
                            y_offset: pos.y_offset,
                            cluster: base + info.cluster,
                        }),
                );
            }
            start += line.len() + 1;
        }
        let breaks = breaks(text, &glyphs);
        Ok(ShapedRun {
            text: text.to_owned(),
            face,
            features,
            metrics: f.metrics,
            glyphs,
            breaks,
        })
    }
}

/// `tnum` over each run of figures in `line`, by byte offset (a run's clusters): digits, and a
/// `.`, `,` or `:` between two digits, so a time, a version or an amount keeps its column while
/// a hyphen or a full stop in words keeps its own width.
pub(super) fn figures(line: &str, out: &mut Vec<Feature>) {
    let b = line.as_bytes();
    let digit = |i: usize| b.get(i).is_some_and(u8::is_ascii_digit);
    let mut i = 0;
    while i < b.len() {
        if !digit(i) {
            i += 1;
            continue;
        }
        let start = i;
        while digit(i) || (matches!(b.get(i), Some(b'.' | b',' | b':')) && digit(i + 1)) {
            i += 1;
        }
        out.push(Feature {
            tag: Tag::new(b"tnum"),
            value: 1,
            start: start as u32,
            end: i as u32,
        });
    }
}

/// UAX #14's opportunities in `text`, each at the first glyph at or after it.
fn breaks(text: &str, glyphs: &[Glyph]) -> Vec<Break> {
    let mut out = Vec::new();
    let mut g = 0usize;
    for (pos, opportunity) in unicode_linebreak::linebreaks(text) {
        // The end of the text is always an opportunity; it starts no line.
        if pos >= text.len() {
            break;
        }
        while glyphs
            .get(g)
            .is_some_and(|glyph| (glyph.cluster as usize) < pos)
        {
            g += 1;
        }
        out.push(Break {
            glyph: g as u32,
            byte: pos as u32,
            mandatory: opportunity == BreakOpportunity::Mandatory,
        });
    }
    out
}

impl ShapedRun {
    /// Points per font unit at `size` points.
    pub fn scale(&self, size: f32) -> f32 {
        self.metrics.scale(size)
    }

    /// The sum of `glyphs`' advances, in font units.
    pub fn advance(&self, glyphs: Range<usize>) -> i64 {
        self.glyphs[glyphs]
            .iter()
            .map(|g| i64::from(g.advance))
            .sum()
    }

    /// The whole run's width in font units, as one line.
    pub fn width(&self) -> i64 {
        self.advance(0..self.glyphs.len())
    }

    /// The run broken into lines at most `max_width` points wide at `size` points: greedily
    /// at its opportunities, inside a word only when the word alone is wider. Only arithmetic
    /// over the cached run: nothing is shaped again.
    pub fn lines(&self, max_width: f32, size: f32) -> Vec<Line> {
        let limit = if size > 0.0 && max_width.is_finite() && size.is_finite() {
            // One rounding from f64, so a width maps to the same unit limit everywhere.
            (f64::from(max_width) * f64::from(self.metrics.units_per_em) / f64::from(size)).floor()
                as i64
        } else {
            i64::MAX
        };
        self.lines_within(limit)
    }

    /// [`lines`](Self::lines) with the limit in font units.
    pub fn lines_within(&self, limit: i64) -> Vec<Line> {
        let mut lines = Vec::new();
        let (mut start, mut start_byte) = (0usize, 0usize);
        let mut x = 0i64;
        let mut last: Option<Break> = None;
        let mut next = 0usize;
        for g in 0..=self.glyphs.len() {
            while let Some(&brk) = self.breaks.get(next).filter(|b| b.glyph as usize == g) {
                next += 1;
                if brk.mandatory {
                    lines.push(self.line(start..g, start_byte..brk.byte as usize));
                    (start, start_byte, x, last) = (g, brk.byte as usize, 0, None);
                } else if g > start {
                    last = Some(brk);
                }
            }
            let Some(glyph) = self.glyphs.get(g) else {
                break;
            };
            let advance = i64::from(glyph.advance);
            // Trailing whitespace hangs past the edge, so a space never starts a line.
            if x + advance > limit && g > start && !self.is_space(g) {
                if let Some(brk) = last.take() {
                    let at = brk.glyph as usize;
                    lines.push(self.line(start..at, start_byte..brk.byte as usize));
                    x -= self.advance(start..at);
                    (start, start_byte) = (at, brk.byte as usize);
                } else if glyph.cluster != self.glyphs[g - 1].cluster {
                    // A word wider than the line breaks between clusters, never inside one.
                    let byte = glyph.cluster as usize;
                    lines.push(self.line(start..g, start_byte..byte));
                    (start, start_byte, x) = (g, byte, 0);
                }
            }
            x += advance;
        }
        lines.push(self.line(start..self.glyphs.len(), start_byte..self.text.len()));
        lines
    }

    fn is_space(&self, g: usize) -> bool {
        self.text
            .get(self.glyphs[g].cluster as usize..)
            .and_then(|rest| rest.chars().next())
            .is_some_and(char::is_whitespace)
    }

    fn line(&self, glyphs: Range<usize>, text: Range<usize>) -> Line {
        let mut end = glyphs.end;
        while end > glyphs.start && self.is_space(end - 1) {
            end -= 1;
        }
        let trimmed = self.text[text.clone()].trim_end().len();
        Line {
            width: self.advance(glyphs.start..end),
            glyphs: glyphs.start..end,
            text: text.start..text.start + trimmed,
        }
    }
}
