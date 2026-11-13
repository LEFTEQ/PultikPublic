//! Text in font files the caller hands in, shaped and rasterized the same on every platform.
//!
//! The platform backends shape with the system's fonts and shaper (Core Text on Apple
//! platforms), so two devices can draw different letters. This path shapes with harfrust, reads
//! metrics and outlines with skrifa and fills them with zeno, from the bytes in
//! [`BundledFonts`], so every platform draws the same glyphs at the same advances. The crate
//! embeds no font file: the caller owns them and hands their bytes in.
//!
//! - [`BundledFonts::shape`]: a string in one face into a [`ShapedRun`] whose positions are
//!   integers in font units, so a run is equal on every architecture, with its UAX #14 line-break
//!   opportunities. [`ShapedRun::lines`] re-breaks it at any width without shaping again.
//! - [`TextFaces`] and [`crate::TextSystem::set_bundled`]: `Op::Text` (and
//!   [`crate::TextSystem::shape`]) shaped and rasterized in these faces, so `canvas-gpu` draws
//!   them through its own text path and atlas.
//!
//! Scope: left-to-right Latin text with no font fallback (a char a face lacks draws as its
//! `.notdef`), no emoji and no bidi.

mod raster;
mod shape;
mod text;

pub use shape::{Break, Glyph, Line, ShapedRun};
pub(crate) use text::Bundled;
pub use text::TextFaces;

pub use canvas_draw::Weight;
use harfrust::{Direction, Feature, Font, Script, ShapePlan, Tag};
use skrifa::ScalerFont;
use std::fmt;

/// `GlyphKey::font` of a bundled face is `FONT_BASE` plus its [`FaceId`]: the platform
/// backends number their faces from 0, so the two never share an atlas key.
pub const FONT_BASE: u16 = 0xF000;
/// The most faces one [`BundledFonts`] holds, so every face's key fits a `u16`.
pub const MAX_FACES: usize = (u16::MAX - FONT_BASE) as usize + 1;

/// One face of a [`BundledFonts`], in the order they were added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FaceId(pub u16);

impl FaceId {
    /// This face's `GlyphKey::font`.
    pub fn font_key(self) -> u16 {
        FONT_BASE + self.0
    }

    /// The face a `GlyphKey::font` names, if it is a bundled one.
    pub fn from_font_key(font: u16) -> Option<FaceId> {
        font.checked_sub(FONT_BASE).map(FaceId)
    }
}

/// OpenType features a run is shaped with, beyond the face's defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Features {
    /// Tabular figures (`tnum`): every digit one width, so numbers line up in columns and a
    /// counting number does not jitter.
    pub tabular: bool,
}

impl Features {
    pub const TABULAR: Features = Features { tabular: true };

    /// The features a plan is compiled with. `tnum` is a ranged feature: a run sets it on its
    /// figures alone ([`shape::figures`]), because a face's `tnum` may widen punctuation too
    /// (Inter's `hyphen.tf`, `period.tf`), and "To-do" set in it reads "To - do".
    fn list(self) -> &'static [Feature] {
        static TNUM: [Feature; 1] = [Feature {
            tag: Tag::new(b"tnum"),
            value: 1,
            start: 0,
            end: 1,
        }];
        if self.tabular { &TNUM } else { &[] }
    }
}

/// A face's vertical metrics in font units (`hhea`, or `OS/2` when the font asks for it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FaceMetrics {
    pub units_per_em: u16,
    /// Above the baseline, positive.
    pub ascent: i32,
    /// Below the baseline, positive.
    pub descent: i32,
    pub line_gap: i32,
}

impl FaceMetrics {
    /// Points per font unit at `size` points.
    pub fn scale(&self, size: f32) -> f32 {
        size / f32::from(self.units_per_em)
    }

    /// One line's height in font units: ascent, descent and gap.
    pub fn line_height(&self) -> i32 {
        self.ascent + self.descent + self.line_gap
    }
}

#[derive(Debug, thiserror::Error)]
pub enum BundledError {
    #[error("{family} {weight:?}: not a font harfrust and skrifa can read")]
    NotAFont { family: String, weight: Weight },
    #[error("{family} {weight:?}: the font has no horizontal line metrics")]
    NoLineMetrics { family: String, weight: Weight },
    #[error("{family} {weight:?} is already in the set")]
    Duplicate { family: String, weight: Weight },
    #[error("a bundled font set holds at most {MAX_FACES} faces")]
    TooManyFaces,
    #[error("no face of the family {0:?}")]
    NoFamily(String),
    #[error("no bundled face {0:?}")]
    NoFace(FaceId),
    #[error("shaping failed: {0}")]
    Shape(harfrust::ShapeError),
}

/// The CSS weight of a [`Weight`], for picking the nearest face.
fn weight_value(weight: Weight) -> u16 {
    match weight {
        Weight::Regular => 400,
        Weight::Medium => 500,
        Weight::Semibold => 600,
        Weight::Bold => 700,
    }
}

struct Face {
    family: String,
    weight: Weight,
    font: Font,
    metrics: FaceMetrics,
    /// Shaping plans by `Features::tabular`: a plan compiles the face's lookups for one feature
    /// set, so each is built once.
    plans: [ShapePlan; 2],
}

/// The faces bundled text is set in, each a family at a weight, from font file bytes the caller
/// owns (a static TTF or OTF; a collection's first font).
#[derive(Default)]
pub struct BundledFonts {
    faces: Vec<Face>,
}

impl fmt::Debug for BundledFonts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list()
            .entries(self.faces.iter().map(|face| (&face.family, face.weight)))
            .finish()
    }
}

impl BundledFonts {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add `family` at `weight` from a font file's bytes.
    pub fn add(
        &mut self,
        family: &str,
        weight: Weight,
        data: &'static [u8],
    ) -> Result<FaceId, BundledError> {
        if self.face(family, weight).is_some() {
            return Err(BundledError::Duplicate {
                family: family.to_owned(),
                weight,
            });
        }
        if self.faces.len() >= MAX_FACES {
            return Err(BundledError::TooManyFaces);
        }
        let font = Font::new(data, 0).ok_or_else(|| BundledError::NotAFont {
            family: family.to_owned(),
            weight,
        })?;
        // Without a size the scaler measures in font units.
        let line = ScalerFont::unhinted(font.clone(), None)
            .metrics()
            .h_line()
            .ok_or_else(|| BundledError::NoLineMetrics {
                family: family.to_owned(),
                weight,
            })?;
        let metrics = FaceMetrics {
            units_per_em: font.units_per_em(),
            ascent: line.ascender.round() as i32,
            descent: -line.descender.round() as i32,
            line_gap: line.line_gap.round() as i32,
        };
        let plan = |features: Features| {
            ShapePlan::new(
                &font,
                Direction::LeftToRight,
                Some(Script::LATIN),
                None,
                features.list(),
            )
        };
        let plans = [plan(Features::default()), plan(Features::TABULAR)];
        let id = FaceId(self.faces.len() as u16);
        self.faces.push(Face {
            family: family.to_owned(),
            weight,
            font,
            metrics,
            plans,
        });
        Ok(id)
    }

    /// The face of `family` at exactly `weight`.
    pub fn face(&self, family: &str, weight: Weight) -> Option<FaceId> {
        self.faces
            .iter()
            .position(|f| f.family == family && f.weight == weight)
            .map(|i| FaceId(i as u16))
    }

    /// The face of `family` nearest to `weight` (the lighter one of two as near).
    pub fn nearest(&self, family: &str, weight: Weight) -> Option<FaceId> {
        let want = weight_value(weight);
        self.faces
            .iter()
            .enumerate()
            .filter(|(_, f)| f.family == family)
            .min_by_key(|(_, f)| {
                let have = weight_value(f.weight);
                (have.abs_diff(want), have)
            })
            .map(|(i, _)| FaceId(i as u16))
    }

    /// A face's family and weight.
    pub fn family(&self, face: FaceId) -> Option<(&str, Weight)> {
        self.faces
            .get(usize::from(face.0))
            .map(|f| (f.family.as_str(), f.weight))
    }

    pub fn metrics(&self, face: FaceId) -> Option<FaceMetrics> {
        self.faces.get(usize::from(face.0)).map(|f| f.metrics)
    }

    fn get(&self, face: FaceId) -> Result<&Face, BundledError> {
        self.faces
            .get(usize::from(face.0))
            .ok_or(BundledError::NoFace(face))
    }
}
