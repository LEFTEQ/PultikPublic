//! Path tessellation for [`canvas_draw::Op::Path`] (D18): lyon turns a path into triangles in
//! device pixels, each vertex with its advancement along the path. The geometry is cached by
//! the path's content, its style and the scale, never by its colour or dash, so a frame that
//! draws the same paths again (a camera move, a flow tick, a recolour) tessellates nothing.

use canvas_draw::{LineCap, LineJoin, Path, Stroke, Verb};
use lyon_tessellation::math::point;
use lyon_tessellation::{
    BuffersBuilder, FillOptions, FillRule, FillTessellator, FillVertex, StrokeOptions,
    StrokeTessellator, StrokeVertex, VertexBuffers,
};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

/// Flattening tolerance in device pixels: a curve is never more than this off.
const TOLERANCE: f32 = 0.2;
/// Cached geometries kept beyond those the last frame drew.
const CACHE_MAX: usize = 2048;

/// One vertex in pixels: its position and its distance along the path (0 for a fill).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct GeomVertex {
    pub pos: [f32; 2],
    pub advance: f32,
}

#[derive(Debug, Default)]
pub(crate) struct Geometry {
    pub vertices: Vec<GeomVertex>,
    pub indices: Vec<u32>,
}

/// The tessellators (their buffers are reused) and the geometry cache.
#[derive(Default)]
pub(crate) struct Tessellator {
    fill: FillTessellator,
    stroke: StrokeTessellator,
    cache: HashMap<u64, (Arc<Geometry>, u64)>,
    /// Bumped per frame build; an entry remembers the last build that drew it.
    build: u64,
    /// Tessellations done (cache misses), for tests and diagnostics.
    pub misses: u64,
}

impl std::fmt::Debug for Tessellator {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tessellator")
            .field("cached", &self.cache.len())
            .field("misses", &self.misses)
            .finish_non_exhaustive()
    }
}
fn hash_path(path: &Path, h: &mut impl Hasher) {
    let tag = |t: u8, points: &[canvas_draw::Point], h: &mut _| {
        Hash::hash(&t, h);
        for p in points {
            p.x.to_bits().hash(h);
            p.y.to_bits().hash(h);
        }
    };
    for v in path.verbs() {
        match *v {
            Verb::Move(p) => tag(0, &[p], h),
            Verb::Line(p) => tag(1, &[p], h),
            Verb::Quad(c, p) => tag(2, &[c, p], h),
            Verb::Cubic(c1, c2, p) => tag(3, &[c1, c2, p], h),
            Verb::Close => tag(4, &[], h),
        }
    }
}

/// `path` scaled to pixels, as lyon's events.
fn lyon_path(path: &Path, s: f32) -> lyon_tessellation::path::Path {
    let px = |p: canvas_draw::Point| point(p.x * s, p.y * s);
    let mut b = lyon_tessellation::path::Path::builder();
    let mut open = false;
    for v in path.verbs() {
        match *v {
            Verb::Move(p) => {
                if open {
                    b.end(false);
                }
                b.begin(px(p));
                open = true;
            }
            Verb::Line(p) | Verb::Quad(_, p) | Verb::Cubic(_, _, p) if !open => {
                // A subpath with no move starts where its first segment ends.
                b.begin(px(p));
                open = true;
            }
            Verb::Line(p) => {
                b.line_to(px(p));
            }
            Verb::Quad(c, p) => {
                b.quadratic_bezier_to(px(c), px(p));
            }
            Verb::Cubic(c1, c2, p) => {
                b.cubic_bezier_to(px(c1), px(c2), px(p));
            }
            Verb::Close => {
                if open {
                    b.end(true);
                    open = false;
                }
            }
        }
    }
    if open {
        b.end(false);
    }
    b.build()
}

impl Tessellator {
    /// Start a frame build: entries the previous builds did not draw may be dropped.
    pub fn begin_build(&mut self) {
        self.build += 1;
        if self.cache.len() > CACHE_MAX {
            let keep = self.build - 1;
            self.cache.retain(|_, (_, used)| *used >= keep);
        }
    }

    /// `path` filled (non-zero winding) at scale `s`.
    pub fn fill(&mut self, path: &Path, s: f32) -> Arc<Geometry> {
        let mut h = std::hash::DefaultHasher::new();
        0u8.hash(&mut h);
        s.to_bits().hash(&mut h);
        hash_path(path, &mut h);
        let key = h.finish();
        self.cached(key, |t| {
            let mut out: VertexBuffers<GeomVertex, u32> = VertexBuffers::new();
            let options = FillOptions::tolerance(TOLERANCE).with_fill_rule(FillRule::NonZero);
            let result = t.fill.tessellate_path(
                &lyon_path(path, s),
                &options,
                &mut BuffersBuilder::new(&mut out, |v: FillVertex| GeomVertex {
                    pos: v.position().to_array(),
                    advance: 0.0,
                }),
            );
            if let Err(e) = result {
                tracing::warn!(error = ?e, "path fill tessellation failed; drawn empty");
            }
            out
        })
    }

    /// `path` stroked with `stroke`'s width, caps and joins at scale `s` (dashes are the
    /// shader's, from each vertex's advancement).
    pub fn stroke(&mut self, path: &Path, stroke: &Stroke, s: f32) -> Arc<Geometry> {
        let mut h = std::hash::DefaultHasher::new();
        1u8.hash(&mut h);
        s.to_bits().hash(&mut h);
        stroke.width.to_bits().hash(&mut h);
        stroke.cap.hash(&mut h);
        stroke.join.hash(&mut h);
        hash_path(path, &mut h);
        let key = h.finish();
        let cap = match stroke.cap {
            LineCap::Butt => lyon_tessellation::LineCap::Butt,
            LineCap::Round => lyon_tessellation::LineCap::Round,
            LineCap::Square => lyon_tessellation::LineCap::Square,
        };
        let join = match stroke.join {
            LineJoin::Miter => lyon_tessellation::LineJoin::Miter,
            LineJoin::Round => lyon_tessellation::LineJoin::Round,
            LineJoin::Bevel => lyon_tessellation::LineJoin::Bevel,
        };
        let width = stroke.width * s;
        self.cached(key, |t| {
            let mut out: VertexBuffers<GeomVertex, u32> = VertexBuffers::new();
            let options = StrokeOptions::tolerance(TOLERANCE)
                .with_line_width(width)
                .with_line_cap(cap)
                .with_line_join(join);
            let result = t.stroke.tessellate_path(
                &lyon_path(path, s),
                &options,
                &mut BuffersBuilder::new(&mut out, |v: StrokeVertex| GeomVertex {
                    pos: v.position().to_array(),
                    advance: v.advancement(),
                }),
            );
            if let Err(e) = result {
                tracing::warn!(error = ?e, "path stroke tessellation failed; drawn empty");
            }
            out
        })
    }

    fn cached(
        &mut self,
        key: u64,
        make: impl FnOnce(&mut Self) -> VertexBuffers<GeomVertex, u32>,
    ) -> Arc<Geometry> {
        let build = self.build;
        if let Some((g, used)) = self.cache.get_mut(&key) {
            *used = build;
            return g.clone();
        }
        self.misses += 1;
        let out = make(self);
        let g = Arc::new(Geometry {
            vertices: out.vertices,
            indices: out.indices,
        });
        self.cache.insert(key, (g.clone(), build));
        g
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use canvas_draw::{Point, Rgba};

    fn curve() -> Path {
        let mut p = Path::new();
        p.move_to(Point::new(0.0, 0.0)).cubic_to(
            Point::new(20.0, -10.0),
            Point::new(40.0, 30.0),
            Point::new(60.0, 0.0),
        );
        p
    }

    #[test]
    fn the_same_path_tessellates_once() {
        let mut t = Tessellator::default();
        let stroke = Stroke::new(2.0, Rgba::WHITE).round();
        t.begin_build();
        let a = t.stroke(&curve(), &stroke, 2.0);
        t.begin_build();
        let b = t.stroke(&curve(), &Stroke::new(2.0, Rgba::BLACK).round(), 2.0);
        assert!(Arc::ptr_eq(&a, &b), "a recolour reuses the geometry");
        assert_eq!(t.misses, 1);
        t.stroke(&curve(), &stroke, 3.0);
        assert_eq!(t.misses, 2, "another scale tessellates again");
    }

    #[test]
    fn a_stroke_advances_along_its_length() {
        let mut t = Tessellator::default();
        let mut line = Path::new();
        line.move_to(Point::new(0.0, 0.0))
            .line_to(Point::new(50.0, 0.0));
        let g = t.stroke(&line, &Stroke::new(2.0, Rgba::WHITE), 2.0);
        let max = g.vertices.iter().map(|v| v.advance).fold(0.0, f32::max);
        assert!((max - 100.0).abs() < 0.01, "advancement in pixels: {max}");
        assert!(!g.indices.is_empty() && g.indices.len() % 3 == 0);
    }
}
