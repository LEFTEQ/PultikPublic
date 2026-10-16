//! Non-macOS fallback: fixed advances and no ink. It keeps the crate (and the bar layout
//! built on it) compiling and testable on Linux until the parley backend lands (M8).

use crate::atlas::{GlyphKey, RasterGlyph};
use crate::term::{RunGlyph, TermMetrics};
use crate::{FontSpec, Metrics, ShapedGlyph, ShapedLine};

pub(crate) struct Platform;

fn advance(spec: FontSpec) -> f32 {
    spec.size * if spec.mono { 0.6 } else { 0.55 }
}

impl Platform {
    pub(crate) fn new() -> Self {
        Platform
    }

    /// Fixed proportions in ems: a 0.6 em cell over a 1.2 em line.
    pub(crate) fn set_term_font(&mut self, _family: Option<&str>, _size: f32) -> TermMetrics {
        TermMetrics {
            ascent: 0.9,
            descent: 0.3,
            leading: 0.0,
            advance: 0.6,
            underline_position: 0.1,
            underline_thickness: 0.06,
            strike_position: 0.3,
            strike_thickness: 0.06,
        }
    }

    /// One glyph per char (its code point), 0.6 em apart, no colour.
    pub(crate) fn shape_term_run(&mut self, text: &str, _style: usize, out: &mut Vec<RunGlyph>) {
        let mut index = 0;
        for (i, c) in text.chars().enumerate() {
            out.push(RunGlyph {
                index,
                font: 0,
                glyph: c as u32,
                x: i as f32 * 0.6,
                y: 0.0,
                advance: 0.6,
                color: false,
            });
            index += c.len_utf16();
        }
    }

    pub(crate) fn metrics(&mut self, spec: FontSpec) -> Metrics {
        Metrics {
            ascent: spec.size * 0.8,
            descent: spec.size * 0.2,
            leading: 0.0,
            advance: advance(spec),
        }
    }

    pub(crate) fn shape(&mut self, text: &str, spec: FontSpec) -> ShapedLine {
        let adv = advance(spec);
        let n = text.chars().count();
        ShapedLine {
            glyphs: text
                .chars()
                .enumerate()
                .map(|(i, c)| ShapedGlyph {
                    font: 0,
                    glyph: c as u32,
                    x: i as f32 * adv,
                    y: 0.0,
                    color: false,
                })
                .collect(),
            width: n as f32 * adv,
            ascent: spec.size * 0.8,
            descent: spec.size * 0.2,
            carets: (0..=n).map(|i| i as f32 * adv).collect(),
        }
    }

    pub(crate) fn rasterize(&mut self, _key: &GlyphKey) -> RasterGlyph {
        RasterGlyph::empty()
    }
}
