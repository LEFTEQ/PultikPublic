//! Vector paths, what [`crate::Op::Path`] fills and strokes: curves, dependency arrows,
//! cadence rails. Points are in the op's space (view points, or world points inside a camera
//! layer). The renderer tessellates a path once per content and zoom and caches it, so a
//! colour change, a dash's flow or a camera move never tessellates again.

use crate::{Point, Rect, Rgba};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verb {
    Move(Point),
    Line(Point),
    /// A quadratic Bézier: control, end.
    Quad(Point, Point),
    /// A cubic Bézier: two controls, end.
    Cubic(Point, Point, Point),
    Close,
}

/// A sequence of subpaths, each starting at a [`Verb::Move`].
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Path {
    verbs: Vec<Verb>,
}

impl Path {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn move_to(&mut self, p: Point) -> &mut Self {
        self.verbs.push(Verb::Move(p));
        self
    }

    pub fn line_to(&mut self, p: Point) -> &mut Self {
        self.verbs.push(Verb::Line(p));
        self
    }

    pub fn quad_to(&mut self, c: Point, p: Point) -> &mut Self {
        self.verbs.push(Verb::Quad(c, p));
        self
    }

    pub fn cubic_to(&mut self, c1: Point, c2: Point, p: Point) -> &mut Self {
        self.verbs.push(Verb::Cubic(c1, c2, p));
        self
    }

    pub fn close(&mut self) -> &mut Self {
        self.verbs.push(Verb::Close);
        self
    }

    pub fn verbs(&self) -> &[Verb] {
        &self.verbs
    }

    pub fn is_empty(&self) -> bool {
        self.verbs.is_empty()
    }

    /// The bounds of every point and control point (a curve lies inside them).
    pub fn bounds(&self) -> Rect {
        let mut points = self.verbs.iter().flat_map(|v| {
            let (a, b, c) = match *v {
                Verb::Move(p) | Verb::Line(p) => (Some(p), None, None),
                Verb::Quad(c, p) => (Some(c), Some(p), None),
                Verb::Cubic(c1, c2, p) => (Some(c1), Some(c2), Some(p)),
                Verb::Close => (None, None, None),
            };
            [a, b, c].into_iter().flatten()
        });
        let Some(first) = points.next() else {
            return Rect::ZERO;
        };
        let (lo, hi) = points.fold((first, first), |(lo, hi), p| {
            (
                Point::new(lo.x.min(p.x), lo.y.min(p.y)),
                Point::new(hi.x.max(p.x), hi.y.max(p.y)),
            )
        });
        Rect::from_corners(lo, hi)
    }

    /// Every point mapped through `f`.
    pub fn map(&self, f: impl Fn(Point) -> Point) -> Path {
        let verbs = self
            .verbs
            .iter()
            .map(|v| match *v {
                Verb::Move(p) => Verb::Move(f(p)),
                Verb::Line(p) => Verb::Line(f(p)),
                Verb::Quad(c, p) => Verb::Quad(f(c), f(p)),
                Verb::Cubic(c1, c2, p) => Verb::Cubic(f(c1), f(c2), f(p)),
                Verb::Close => Verb::Close,
            })
            .collect();
        Path { verbs }
    }

    /// A filled arrowhead: its tip at `tip`, pointing along `dir` (any length), `len` long
    /// and `width` wide at its base.
    pub fn arrowhead(tip: Point, dir: Point, len: f32, width: f32) -> Path {
        let n = (dir.x * dir.x + dir.y * dir.y).sqrt().max(f32::EPSILON);
        let (ux, uy) = (dir.x / n, dir.y / n);
        let base = Point::new(tip.x - ux * len, tip.y - uy * len);
        let (hx, hy) = (-uy * width * 0.5, ux * width * 0.5);
        let mut p = Path::new();
        p.move_to(tip)
            .line_to(Point::new(base.x + hx, base.y + hy))
            .line_to(Point::new(base.x - hx, base.y - hy))
            .close();
        p
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum LineCap {
    #[default]
    Butt,
    Round,
    Square,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum LineJoin {
    #[default]
    Miter,
    Round,
    Bevel,
}

/// A dash pattern measured along the path, in points: `on` drawn, `off` skipped, starting
/// `phase` into the pattern. `speed` moves the pattern forward along the path in points per
/// second (a deploy's flow), animated by the renderer's clock without a rebuild.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Dash {
    pub on: f32,
    pub off: f32,
    pub phase: f32,
    pub speed: f32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stroke {
    pub width: f32,
    pub color: Rgba,
    pub cap: LineCap,
    pub join: LineJoin,
    pub dash: Option<Dash>,
}

impl Stroke {
    /// A solid stroke with butt caps and miter joins.
    pub fn new(width: f32, color: Rgba) -> Self {
        Self {
            width,
            color,
            cap: LineCap::Butt,
            join: LineJoin::Miter,
            dash: None,
        }
    }
    pub fn round(mut self) -> Self {
        self.cap = LineCap::Round;
        self.join = LineJoin::Round;
        self
    }
    pub fn cap(mut self, cap: LineCap) -> Self {
        self.cap = cap;
        self
    }
    pub fn join(mut self, join: LineJoin) -> Self {
        self.join = join;
        self
    }
    pub fn dash(mut self, dash: Dash) -> Self {
        self.dash = Some(dash);
        self
    }
}

/// A path filled (non-zero winding), stroked, or both (the fill under the stroke). The path
/// is shared, so a producer keeps its paths between frames for free.
#[derive(Debug, Clone, PartialEq)]
pub struct PathOp {
    pub path: Arc<Path>,
    pub fill: Option<Rgba>,
    pub stroke: Option<Stroke>,
}

impl PathOp {
    pub fn fill(path: Arc<Path>, color: Rgba) -> Self {
        Self {
            path,
            fill: Some(color),
            stroke: None,
        }
    }
    pub fn stroke(path: Arc<Path>, stroke: Stroke) -> Self {
        Self {
            path,
            fill: None,
            stroke: Some(stroke),
        }
    }
}

/// Where a camera layer's world points land in the view: `view = world * scale + offset`,
/// per axis, in points. The renderer applies it on the GPU, so moving it re-encodes nothing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Camera {
    pub scale: Point,
    pub offset: Point,
}

impl Camera {
    pub const IDENTITY: Camera = Camera {
        scale: Point::new(1.0, 1.0),
        offset: Point::ZERO,
    };

    pub fn apply(&self, p: Point) -> Point {
        Point::new(
            p.x * self.scale.x + self.offset.x,
            p.y * self.scale.y + self.offset.y,
        )
    }

    /// The world point drawn at view point `p`.
    pub fn unapply(&self, p: Point) -> Point {
        Point::new(
            (p.x - self.offset.x) / self.scale.x,
            (p.y - self.offset.y) / self.scale.y,
        )
    }
}

impl Default for Camera {
    fn default() -> Self {
        Self::IDENTITY
    }
}

/// The axes a camera layer follows: a timeline's marks follow both, its axis strip only x (a pan
/// moves it, a vertical scroll does not), its label column only y.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Follow {
    pub x: bool,
    pub y: bool,
}

impl Follow {
    pub const NONE: Follow = Follow { x: false, y: false };
    pub const X: Follow = Follow { x: true, y: false };
    pub const Y: Follow = Follow { x: false, y: true };
    pub const BOTH: Follow = Follow { x: true, y: true };

    /// 0 for none, 1 x, 2 y, 3 both: the renderer's uniform slot.
    pub fn index(self) -> usize {
        usize::from(self.x) | usize::from(self.y) << 1
    }

    /// `camera` restricted to these axes (identity on the others).
    pub fn of(self, camera: Camera) -> Camera {
        let pick = |on: bool, v: f32, id: f32| if on { v } else { id };
        Camera {
            scale: Point::new(
                pick(self.x, camera.scale.x, 1.0),
                pick(self.y, camera.scale.y, 1.0),
            ),
            offset: Point::new(
                pick(self.x, camera.offset.x, 0.0),
                pick(self.y, camera.offset.y, 0.0),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_cover_controls() {
        let mut p = Path::new();
        p.move_to(Point::new(0.0, 0.0)).cubic_to(
            Point::new(10.0, -5.0),
            Point::new(20.0, 15.0),
            Point::new(30.0, 0.0),
        );
        assert_eq!(p.bounds(), Rect::new(0.0, -5.0, 30.0, 20.0));
    }

    #[test]
    fn camera_round_trips() {
        let c = Camera {
            scale: Point::new(4.0, 1.0),
            offset: Point::new(-100.0, 8.0),
        };
        let p = Point::new(30.0, 2.0);
        assert_eq!(c.apply(p), Point::new(20.0, 10.0));
        assert_eq!(c.unapply(c.apply(p)), p);
    }

    #[test]
    fn arrowhead_points_along_its_direction() {
        let a = Path::arrowhead(Point::new(10.0, 0.0), Point::new(1.0, 0.0), 4.0, 6.0);
        assert_eq!(a.bounds(), Rect::new(6.0, -3.0, 4.0, 6.0));
    }
}
