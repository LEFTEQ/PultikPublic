//! The bundled faces behind [`crate::TextSystem`]'s UI text: with [`TextFaces`] set, a
//! [`FontSpec`] picks a bundled face instead of a system font, and its glyphs carry bundled font
//! keys the atlas rasterizes here. `canvas-gpu` draws `Op::Text` exactly as before.

use super::raster::Rasterizer;
use super::{BundledError, BundledFonts, FaceId, Features, ShapedRun, Weight};
use crate::atlas::{GlyphKey, RasterGlyph};
use crate::{FontSpec, Metrics, ShapedGlyph, ShapedLine};
use std::collections::HashMap;
use std::sync::Arc;

/// Which bundled families set a [`crate::TextSystem`]'s text.
#[derive(Debug, Clone)]
pub struct TextFaces {
    pub fonts: Arc<BundledFonts>,
    /// The family of text whose [`FontSpec::mono`] is false.
    pub ui: String,
    /// The family of [`FontSpec::mono`] text.
    pub mono: String,
    /// Tabular figures in the UI family (a monospaced family's digits already are).
    pub tabular: bool,
}

const WEIGHTS: [Weight; 4] = [
    Weight::Regular,
    Weight::Medium,
    Weight::Semibold,
    Weight::Bold,
];

fn weight_index(weight: Weight) -> usize {
    match weight {
        Weight::Regular => 0,
        Weight::Medium => 1,
        Weight::Semibold => 2,
        Weight::Bold => 3,
    }
}

/// [`TextFaces`] in use, with each spec's face resolved once.
pub(crate) struct Bundled {
    faces: TextFaces,
    /// The face by `[mono][weight]`: the family's nearest to each weight.
    resolved: [[FaceId; 4]; 2],
    /// The advance of `0` per face and tabular flag, in font units.
    zero: HashMap<(FaceId, bool), i32>,
    raster: Rasterizer,
}

impl Bundled {
    /// Fails when either family has no face in the set.
    pub(crate) fn new(faces: TextFaces) -> Result<Self, BundledError> {
        let resolve = |family: &str| -> Result<[FaceId; 4], BundledError> {
            let mut out = [FaceId(0); 4];
            for (slot, weight) in out.iter_mut().zip(WEIGHTS) {
                *slot = faces
                    .fonts
                    .nearest(family, weight)
                    .ok_or_else(|| BundledError::NoFamily(family.to_owned()))?;
            }
            Ok(out)
        };
        let resolved = [resolve(&faces.ui)?, resolve(&faces.mono)?];
        Ok(Self {
            faces,
            resolved,
            zero: HashMap::new(),
            raster: Rasterizer::default(),
        })
    }

    fn face(&self, spec: FontSpec) -> FaceId {
        self.resolved[usize::from(spec.mono)][weight_index(spec.weight)]
    }

    fn features(&self, spec: FontSpec) -> Features {
        Features {
            tabular: self.faces.tabular && !spec.mono,
        }
    }

    pub(crate) fn metrics(&mut self, spec: FontSpec) -> Metrics {
        let (face, features) = (self.face(spec), self.features(spec));
        let Some(m) = self.faces.fonts.metrics(face) else {
            tracing::error!(?face, "metrics: a resolved face left the set");
            return Metrics::default();
        };
        let fonts = &self.faces.fonts;
        let zero = *self
            .zero
            .entry((face, features.tabular))
            .or_insert_with(|| match fonts.shape("0", face, features) {
                Ok(run) => run.glyphs.first().map_or(0, |g| g.advance),
                Err(error) => {
                    tracing::error!(?face, %error, "metrics: shaping 0 failed");
                    0
                }
            });
        let k = m.scale(spec.size);
        Metrics {
            ascent: m.ascent as f32 * k,
            descent: m.descent as f32 * k,
            leading: m.line_gap as f32 * k,
            advance: zero as f32 * k,
        }
    }

    /// `text` as one line in `spec`'s bundled face.
    pub(crate) fn shape(&self, text: &str, spec: FontSpec) -> ShapedLine {
        match self
            .faces
            .fonts
            .shape(text, self.face(spec), self.features(spec))
        {
            Ok(run) => line(&run, spec.size),
            Err(error) => {
                tracing::error!(%error, "shape: bundled shaping failed");
                ShapedLine::default()
            }
        }
    }

    /// The raster of a bundled glyph key; `None` for a key of the platform's faces.
    pub(crate) fn rasterize(&mut self, key: &GlyphKey) -> Option<RasterGlyph> {
        let face = FaceId::from_font_key(key.font)?;
        Some(self.raster.rasterize(&self.faces.fonts, face, key))
    }
}

/// A run placed as one line at `size` points: glyph pens from the run's integer advances,
/// carets per char boundary (a cluster of several chars, a ligature, shares its advance evenly).
fn line(run: &ShapedRun, size: f32) -> ShapedLine {
    let k = run.scale(size);
    let font = run.face.font_key();
    let mut glyphs = Vec::with_capacity(run.glyphs.len());
    // Each cluster's byte offset, pen and advance, in text order.
    let mut clusters: Vec<(usize, i64, i64)> = Vec::new();
    let mut pen = 0i64;
    for g in &run.glyphs {
        glyphs.push(ShapedGlyph {
            font,
            glyph: g.id,
            x: (pen + i64::from(g.x_offset)) as f32 * k,
            y: -g.y_offset as f32 * k,
            color: false,
        });
        match clusters.last_mut() {
            Some(c) if c.0 == g.cluster as usize => c.2 += i64::from(g.advance),
            _ => clusters.push((g.cluster as usize, pen, i64::from(g.advance))),
        }
        pen += i64::from(g.advance);
    }
    let carets = carets(run.text.as_str(), &clusters)
        .into_iter()
        .map(|units| units as f32 * k)
        .collect();
    ShapedLine {
        glyphs,
        width: pen as f32 * k,
        ascent: run.metrics.ascent as f32 * k,
        descent: run.metrics.descent as f32 * k,
        carets,
    }
}

/// The caret of each char boundary of `text` (and its end) in font units, from its clusters'
/// byte offsets, pens and advances in text order: a cluster of several chars shares its advance
/// evenly. A cluster's chars are counted once, on its first caret, and each later caret in it is
/// one char further: a base with a long run of combining marks is one cluster, and counting it
/// again per caret would cost its length squared.
fn carets(text: &str, clusters: &[(usize, i64, i64)]) -> Vec<i64> {
    let mut carets = Vec::with_capacity(text.chars().count() + 1);
    let mut c = 0usize;
    // The cluster the last caret fell in: its index, its chars and the chars before that caret.
    let mut within: Option<(usize, i64, i64)> = None;
    for byte in text
        .char_indices()
        .map(|(i, _)| i)
        .chain(std::iter::once(text.len()))
    {
        while clusters.get(c + 1).is_some_and(|next| next.0 <= byte) {
            c += 1;
        }
        let units = match clusters.get(c) {
            Some(&(start, x, advance)) if start <= byte => {
                let (chars, before) = match &mut within {
                    Some((i, chars, before)) if *i == c => {
                        *before += 1;
                        (*chars, *before)
                    }
                    _ => {
                        let end = clusters.get(c + 1).map_or(text.len(), |next| next.0);
                        let chars = text[start..end].chars().count().max(1) as i64;
                        let before = text[start..byte].chars().count() as i64;
                        within = Some((c, chars, before));
                        (chars, before)
                    }
                };
                x + advance * before / chars
            }
            _ => 0,
        };
        carets.push(units);
    }
    carets
}

#[cfg(test)]
mod tests {
    use super::carets;
    use std::time::{Duration, Instant};

    /// A base and a long run of combining marks is one cluster, which a group's text can hold
    /// within its byte bound: its carets cost one pass over it. The bound is generous for that
    /// pass (a few milliseconds) and missed many times over by a walk that counts the cluster
    /// again for every caret.
    #[test]
    fn a_long_cluster_s_carets_cost_one_pass() {
        let marks = 400_000;
        let text = format!("a{}", "\u{301}".repeat(marks));
        let advance = 1_000;
        let started = Instant::now();
        let got = carets(&text, &[(0, 0, advance)]);
        let took = started.elapsed();
        assert_eq!(got.len(), marks + 2);
        assert_eq!((got[0], got[marks + 1]), (0, advance));
        assert!(got.windows(2).all(|w| w[0] <= w[1]), "carets in order");
        assert!(
            took < Duration::from_millis(500),
            "{took:?} for {} carets",
            marks + 2
        );
    }
}
