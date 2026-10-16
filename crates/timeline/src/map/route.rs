//! The edge routes of Semafor's layout (`routeEdges` in layout.ts), as geometry instead of SVG
//! path strings, unrounded (layout.ts rounds its strings to 0.1 pt; the goldens hold the port
//! within that).
//!
//! - Facing sides: a cubic from the source's side to the target's, its controls halfway across.
//!   Three or more edges on one side of a card share a straight trunk (at most
//!   [`LayoutOptions::trunk`], a third of the shortest span) and fan out from its end.
//! - A member linked to its own frame: a vertical stem from the card's top to the header.
//! - Two cards in the same column: a loop out on the right, 44 pt past the wider one.
//!
//! Arrowheads are 7 × 8 triangles with their tip on the end, pointing along the end's direction.

use super::layout::{Keyed, LayoutLink, LayoutOptions, Point64, Rect64};
use std::collections::HashMap;
use std::sync::Arc;

/// An edge's line, in absolute world points (an SVG `H`/`V` is a [`RouteVerb::Line`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RouteVerb {
    Move(Point64),
    Line(Point64),
    /// Two controls, end.
    Cubic(Point64, Point64, Point64),
}

/// layout.ts's `EdgeRoute`.
#[derive(Debug, Clone, PartialEq)]
pub struct EdgeRoute {
    pub path: Vec<RouteVerb>,
    /// The arrowhead at the target end: tip, then the two base corners.
    pub head: [Point64; 3],
    /// The one at the source end, for two-way links.
    pub tail: [Point64; 3],
    /// The curve's midpoint: where a label sits.
    pub mid: Point64,
    /// x where the edge leaves its source.
    pub x0: f64,
}

/// Arrowhead length along the edge and half its base width.
pub const ARROW_LEN: f64 = 7.0;
pub const ARROW_HALF: f64 = 4.0;
/// A target this far past the source's right side (or left) faces it.
const FACING: f64 = 6.0;
/// A same-column loop bulges this far past the wider card.
const BULGE: f64 = 44.0;

/// A triangle with its tip on (x, y), pointing along (dx, dy) (a unit axis).
pub fn arrow(x: f64, y: f64, dx: f64, dy: f64) -> [Point64; 3] {
    let bx = x - dx * ARROW_LEN;
    let by = y - dy * ARROW_LEN;
    [
        Point64::new(x, y),
        Point64::new(bx - dy * ARROW_HALF, by + dx * ARROW_HALF),
        Point64::new(bx + dy * ARROW_HALF, by - dx * ARROW_HALF),
    ]
}

#[derive(Debug, Clone, Copy)]
struct End<'a> {
    id: &'a str,
    right: bool,
    x: f64,
    y: f64,
}

/// Every link's route; a link to an unknown id or to itself has none. `frames` maps a grouped
/// item to its group and the y its stem reaches (the header's bottom, 6 pt up).
pub(super) fn route_edges(
    links: &[LayoutLink],
    nodes: &Keyed<Rect64>,
    groups: &Keyed<Rect64>,
    frames: &HashMap<&str, (&str, f64)>,
    o: &LayoutOptions,
) -> Keyed<EdgeRoute> {
    let rect_of = |id: &str| nodes.get(id).or_else(|| groups.get(id)).copied();
    let mut routes = Keyed::default();
    let mut facing: Vec<(&Arc<str>, End<'_>, End<'_>, f64)> = Vec::new();
    // Per card side: how many edges leave or enter it, and the shortest span among them.
    let mut bundle: HashMap<(&str, bool), (usize, f64)> = HashMap::new();
    fn note<'a>(bundle: &mut HashMap<(&'a str, bool), (usize, f64)>, e: &End<'a>, span: f64) {
        let b = bundle.entry((e.id, e.right)).or_insert((0, f64::INFINITY));
        b.0 += 1;
        b.1 = b.1.min(span);
    }

    for link in links {
        let (Some(a), Some(b)) = (rect_of(&link.from), rect_of(&link.to)) else {
            continue;
        };
        if link.from == link.to {
            continue;
        }
        let ay = a.y + a.h / 2.0;
        let by = b.y + b.h / 2.0;
        let in_from = frames.get(&*link.from);
        let in_to = frames.get(&*link.to);
        let up = in_from.is_some_and(|f| f.0 == &*link.to);
        if up || in_to.is_some_and(|f| f.0 == &*link.from) {
            // A member linked to its own frame: a short stem up to the frame's header.
            let member = if up { a } else { b };
            let line = if up { in_from } else { in_to }.map_or(member.y, |f| f.1);
            let x = member.x + member.w / 2.0;
            routes.insert(
                link.id.clone(),
                EdgeRoute {
                    path: vec![
                        RouteVerb::Move(Point64::new(x, member.y)),
                        RouteVerb::Line(Point64::new(x, line)),
                    ],
                    head: if up {
                        arrow(x, line, 0.0, -1.0)
                    } else {
                        arrow(x, member.y, 0.0, 1.0)
                    },
                    tail: if up {
                        arrow(x, member.y, 0.0, 1.0)
                    } else {
                        arrow(x, line, 0.0, -1.0)
                    },
                    mid: Point64::new(x, (member.y + line) / 2.0),
                    x0: x,
                },
            );
        } else if b.x >= a.x + a.w + FACING {
            let s = End {
                id: &link.from,
                right: true,
                x: a.x + a.w,
                y: ay,
            };
            let t = End {
                id: &link.to,
                right: false,
                x: b.x,
                y: by,
            };
            note(&mut bundle, &s, t.x - s.x);
            note(&mut bundle, &t, t.x - s.x);
            facing.push((&link.id, s, t, 1.0));
        } else if a.x >= b.x + b.w + FACING {
            let s = End {
                id: &link.from,
                right: false,
                x: a.x,
                y: ay,
            };
            let t = End {
                id: &link.to,
                right: true,
                x: b.x + b.w,
                y: by,
            };
            note(&mut bundle, &s, s.x - t.x);
            note(&mut bundle, &t, s.x - t.x);
            facing.push((&link.id, s, t, -1.0));
        } else {
            // The same column: loop out on the right.
            let sx = a.x + a.w;
            let tx = b.x + b.w;
            let bulge = sx.max(tx) + BULGE;
            routes.insert(
                link.id.clone(),
                EdgeRoute {
                    path: vec![
                        RouteVerb::Move(Point64::new(sx, ay)),
                        RouteVerb::Cubic(
                            Point64::new(bulge, ay),
                            Point64::new(bulge, by),
                            Point64::new(tx, by),
                        ),
                    ],
                    head: arrow(tx, by, -1.0, 0.0),
                    tail: arrow(sx, ay, -1.0, 0.0),
                    mid: Point64::new((sx + tx) / 2.0 + 33.0, (ay + by) / 2.0),
                    x0: sx,
                },
            );
        }
    }

    // Shared trunks: three or more edges on one side of a card leave (or arrive) together.
    let trunk = |e: &End<'_>| match bundle.get(&(e.id, e.right)) {
        Some(&(n, span)) if n >= o.bundle_min => o.trunk.min(span / 3.0),
        _ => 0.0,
    };
    for (id, s, t, dir) in facing {
        let sx = s.x + dir * trunk(&s);
        let ex = t.x - dir * trunk(&t);
        let c = (ex - sx).abs() / 2.0;
        let mut path = vec![RouteVerb::Move(Point64::new(s.x, s.y))];
        if sx != s.x {
            path.push(RouteVerb::Line(Point64::new(sx, s.y)));
        }
        path.push(RouteVerb::Cubic(
            Point64::new(sx + dir * c, s.y),
            Point64::new(ex - dir * c, t.y),
            Point64::new(ex, t.y),
        ));
        if ex != t.x {
            path.push(RouteVerb::Line(Point64::new(t.x, t.y)));
        }
        routes.insert(
            id.clone(),
            EdgeRoute {
                path,
                head: arrow(t.x, t.y, dir, 0.0),
                tail: arrow(s.x, s.y, -dir, 0.0),
                mid: Point64::new((sx + ex) / 2.0, (s.y + t.y) / 2.0),
                x0: s.x,
            },
        );
    }
    routes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_arrow_points_along_its_axis() {
        let [tip, a, b] = arrow(100.0, 50.0, 1.0, 0.0);
        assert_eq!(tip, Point64::new(100.0, 50.0));
        assert_eq!(a, Point64::new(93.0, 54.0));
        assert_eq!(b, Point64::new(93.0, 46.0));
    }
}
