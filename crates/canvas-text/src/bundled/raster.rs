//! Glyph rasterization from the bundled faces' outlines: skrifa draws a glyph's outline at the
//! glyph key's pixel size, unhinted, and zeno fills it into the coverage mask the atlas takes.
//! No system rasterizer is involved, so a glyph's pixels depend only on the font file.

use super::{BundledFonts, FaceId};
use crate::atlas::{GlyphKey, RasterGlyph};
use skrifa::{DrawMemory, GlyphId, PathSink, ScalerFont};
use std::collections::HashMap;
use zeno::{Command, Mask, Point};

/// Scalers kept, one per face and pixel size: every settled zoom level adds one per face in use,
/// and a scaler is cheap to remake.
const SCALERS_MAX: usize = 64;

#[derive(Default)]
pub(crate) struct Rasterizer {
    scalers: HashMap<(FaceId, u32), ScalerFont>,
    /// The outline being filled, reused across glyphs.
    path: Vec<Command>,
}

impl Rasterizer {
    /// `key`'s glyph of `face` as a coverage mask; empty for a glyph with no ink.
    pub(crate) fn rasterize(
        &mut self,
        fonts: &BundledFonts,
        face: FaceId,
        key: &GlyphKey,
    ) -> RasterGlyph {
        let font = match fonts.get(face) {
            Ok(f) => &f.font,
            Err(error) => {
                tracing::warn!(?key, %error, "rasterize: unknown bundled face");
                return RasterGlyph::empty();
            }
        };
        let size = (face, key.size_q);
        if !self.scalers.contains_key(&size) && self.scalers.len() >= SCALERS_MAX {
            self.scalers.clear();
        }
        let scaler = self
            .scalers
            .entry(size)
            .or_insert_with(|| ScalerFont::unhinted(font.clone(), Some(key.size_px())));
        let Some(outline) = scaler.outline(GlyphId::new(key.glyph)) else {
            return RasterGlyph::empty();
        };
        self.path.clear();
        let mut sink = Sink {
            path: &mut self.path,
            dx: f32::from(key.subpixel) * 0.25,
        };
        if let Err(error) = outline.draw(DrawMemory::Scratch, &mut sink) {
            tracing::warn!(?key, ?error, "rasterize: the outline did not draw");
            return RasterGlyph::empty();
        }
        if self.path.is_empty() {
            return RasterGlyph::empty();
        }
        let (data, placement) = Mask::new(&self.path).render();
        if placement.width == 0 || placement.height == 0 {
            return RasterGlyph::empty();
        }
        RasterGlyph {
            width: placement.width,
            height: placement.height,
            left: placement.left,
            // zeno's placement is y down; the atlas measures `top` up from the baseline.
            top: -placement.top,
            color: false,
            data,
        }
    }
}

/// An outline in pixels, y up, into zeno's path, y down, moved right by the subpixel offset.
struct Sink<'a> {
    path: &'a mut Vec<Command>,
    dx: f32,
}

impl Sink<'_> {
    fn point(&self, x: f32, y: f32) -> Point {
        Point::new(x + self.dx, -y)
    }
}

impl PathSink for Sink<'_> {
    fn move_to(&mut self, x: f32, y: f32) {
        let p = self.point(x, y);
        self.path.push(Command::MoveTo(p));
    }

    fn line_to(&mut self, x: f32, y: f32) {
        let p = self.point(x, y);
        self.path.push(Command::LineTo(p));
    }

    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        let (c, p) = (self.point(cx0, cy0), self.point(x, y));
        self.path.push(Command::QuadTo(c, p));
    }

    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        let (c0, c1, p) = (self.point(cx0, cy0), self.point(cx1, cy1), self.point(x, y));
        self.path.push(Command::CurveTo(c0, c1, p));
    }

    fn close(&mut self) {
        self.path.push(Command::Close);
    }
}
