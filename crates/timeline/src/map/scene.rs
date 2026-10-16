//! The drawn estate map: a laid-out [`Graph`] the host pans and pinches. Everything sits in one
//! [`Follow::BOTH`] camera layer in world points, so a pan or a pinch moves two uniforms; the
//! host re-emits only when the data, the selection or the settled zoom band changes (text is set
//! at the zoom it is emitted for: the renderer moves a run's anchor with the camera, never its
//! glyphs' size).
//!
//! - Paint order, as Semafor's DOM stacks it: frames, then links, then cards (the selected
//!   link and the selection rings last). Colour means status (D4): a backup link takes the worst
//!   freshness of the copies it carries, a deploy rolling now is `ok` and flows, a frame and a
//!   card are tinted by their sync; every other link is the neutral hairline, its kind told by
//!   its dash (Semafor's per-kind hues have no status meaning, so they stay neutral here).
//! - Hits follow paint order backwards: a card, then the nearest drawn link within
//!   [`LINK_HIT_PT`] (Semafor's 12-point hit stroke; never under 3 view points when zoomed
//!   out), then a frame.
//! - The arrows walk the cards spatially, Semafor's own rule: from the start's centre, every
//!   card whose centre lies more than 1 pt ahead in that direction is a candidate, scored
//!   `along + 2 × across` (being off-axis costs twice being far); the lowest wins, the earlier
//!   in the layout's order on a tie. Nothing ahead: no move.

use super::layout::{GraphLayout, LayoutOptions, Point64, Rect64};
use super::route::{EdgeRoute, RouteVerb};
use super::{
    AppSync, Arrow, BoxSync, Card, CardKind, Estate, Frame, Freshness, Graph, Health, LayoutInput,
    Link, LinkKind, MAP_LAYOUT, MapApp, NodeKind,
};
use crate::lens::Palette;
use canvas_draw::{
    Camera, Dash, DisplayList, Follow, Path, PathOp, Point, Rect, Rgba, RoundedRect, Size, Stroke,
    TextRun, Weight,
};
use canvas_text::{FontSpec, TextSystem};
use std::sync::Arc;

/// The zoom a pinch stays within (Semafor's camera).
pub const MIN_ZOOM: f32 = 0.12;
pub const MAX_ZOOM: f32 = 2.5;
/// Fitting never zooms out past this (taller drawings are top-aligned and pan) nor in past 1.1.
pub const MIN_FIT_ZOOM: f32 = 0.42;
pub const MAX_FIT_ZOOM: f32 = 1.1;
/// Room kept around the content when fitting, and around a card brought into view, view points.
pub const FIT_PAD: f32 = 28.0;
pub const REVEAL_PAD: f32 = 36.0;
/// Below this zoom the cards drop their detail lines.
pub const FAR_BELOW: f32 = 0.5;
/// A link is hit this far from its line, world points.
pub const LINK_HIT_PT: f32 = 6.0;
/// A running deploy's dash flows 14 pt per 0.9 s (Semafor's `graph-flow`).
pub const FLOW_SPEED: f32 = 14.0 / 0.9;

const CARD_R: f32 = 12.0;
const FRAME_R: f32 = 22.0;
/// Text below this many view points is not drawn.
const MIN_TEXT_PX: f32 = 2.5;
/// Cubic flattening for hit testing.
const FLAT_STEPS: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Dir {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MapHit {
    Card(Arc<str>),
    Link(Arc<str>),
    Frame(Arc<str>),
}

/// A set of [`LinkKind`]s (a legend's hidden kinds), one bit per kind index.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LinkKinds(pub u16);

impl LinkKinds {
    pub const NONE: LinkKinds = LinkKinds(0);

    pub fn contains(self, k: LinkKind) -> bool {
        self.0 & (1 << k as u16) != 0
    }

    pub fn with(self, k: LinkKind) -> LinkKinds {
        LinkKinds(self.0 | 1 << k as u16)
    }
}

/// A link's geometry in world points, made once per layout.
#[derive(Debug, Clone)]
struct Drawn {
    line: Arc<Path>,
    head: Arc<Path>,
    tail: Arc<Path>,
    /// The line flattened, for hit testing.
    flat: Vec<Point>,
    bounds: Rect,
}

#[derive(Debug, Clone, Copy)]
struct Font {
    size: f32,
    weight: Weight,
    mono: bool,
}

const NAME: Font = Font {
    size: 13.0,
    weight: Weight::Medium,
    mono: false,
};
const PLACE_NAME: Font = Font {
    weight: Weight::Semibold,
    ..NAME
};
const DETAIL: Font = Font {
    size: 11.0,
    weight: Weight::Regular,
    mono: false,
};
const FRAME_NAME: Font = Font {
    size: 16.0,
    weight: Weight::Semibold,
    mono: false,
};
const META: Font = Font {
    size: 12.0,
    weight: Weight::Regular,
    mono: false,
};
const ADDR: Font = Font { mono: true, ..META };

/// The laid-out map: built per structure, read per frame.
#[derive(Debug, Clone)]
pub struct MapScene {
    options: LayoutOptions,
    graph: Graph,
    input: LayoutInput,
    layout: GraphLayout,
    /// By `graph.links` index; `None`: the link has no route.
    drawn: Vec<Option<Drawn>>,
    hidden: LinkKinds,
}

impl MapScene {
    /// The Estate map of `estate`, laid out with [`MAP_LAYOUT`].
    pub fn new(estate: &Estate) -> MapScene {
        MapScene::from_graph(Graph::build(estate), MAP_LAYOUT)
    }

    pub fn from_graph(graph: Graph, options: LayoutOptions) -> MapScene {
        let input = graph.layout_input();
        let layout = input.layout(&options);
        let mut scene = MapScene {
            options,
            graph,
            input,
            layout,
            drawn: Vec::new(),
            hidden: LinkKinds::NONE,
        };
        scene.draw_links();
        scene
    }

    /// New data. The layout reruns only when the structure changed (sizes, membership, links),
    /// never for a state, so a card keeps its place; true when it reran.
    pub fn update(&mut self, estate: &Estate) -> bool {
        self.graph = Graph::build(estate);
        let input = self.graph.layout_input();
        let moved = input != self.input;
        if moved {
            self.layout = input.layout(&self.options);
            self.input = input;
        }
        self.draw_links();
        moved
    }

    fn draw_links(&mut self) {
        self.drawn = self
            .graph
            .links
            .iter()
            .map(|l| self.layout.edges.get(&l.id).map(drawn))
            .collect();
    }

    pub fn graph(&self) -> &Graph {
        &self.graph
    }

    pub fn layout(&self) -> &GraphLayout {
        &self.layout
    }

    /// Kinds kept in the layout but neither drawn nor hit (a legend toggle never moves a card).
    pub fn set_hidden(&mut self, kinds: LinkKinds) {
        self.hidden = kinds;
    }

    pub fn hidden(&self) -> LinkKinds {
        self.hidden
    }

    /// The whole drawing, margins included: what the camera fits.
    pub fn size(&self) -> Size {
        Size::new(self.layout.width as f32, self.layout.height as f32)
    }

    /// A card's or a frame's box, world points.
    pub fn rect_of(&self, id: &str) -> Option<Rect> {
        self.layout
            .nodes
            .get(id)
            .or_else(|| self.layout.groups.get(id))
            .map(rect32)
    }

    pub fn card(&self, id: &str) -> Option<&Card> {
        self.graph.cards.iter().find(|c| &*c.id == id)
    }

    pub fn frame(&self, id: &str) -> Option<&Frame> {
        self.graph.frames.iter().find(|f| &*f.id == id)
    }

    pub fn link(&self, id: &str) -> Option<&Link> {
        self.graph.links.iter().find(|l| &*l.id == id)
    }

    /// The box and app ↵ opens on this card: a live app's, never a declared one's.
    pub fn app_of(&self, id: &str) -> Option<(&str, &MapApp)> {
        match &self.card(id)?.what {
            CardKind::App {
                box_name,
                app: Some(a),
                ..
            } => Some((box_name, a)),
            _ => None,
        }
    }

    /// Cards in reading order: column by column, top to bottom, a frame's members in its place.
    pub fn order(&self) -> &[Arc<str>] {
        &self.layout.order
    }

    /// Where the arrows start before a card has focus.
    pub fn first(&self) -> Option<&Arc<str>> {
        self.layout.order.first()
    }

    /// What `p` (world points) lands on at zoom `k`.
    pub fn hit(&self, p: Point, k: f32) -> Option<MapHit> {
        for c in self.graph.cards.iter().rev() {
            if self
                .layout
                .nodes
                .get(&c.id)
                .is_some_and(|r| rect32(r).contains(p))
            {
                return Some(MapHit::Card(c.id.clone()));
            }
        }
        let tol = LINK_HIT_PT.max(3.0 / k.max(f32::EPSILON));
        let mut best: Option<(f32, &Link)> = None;
        for (l, d) in self.graph.links.iter().zip(&self.drawn) {
            let Some(d) = d else { continue };
            if self.hidden.contains(l.kind) || !d.bounds.inset(-tol).contains(p) {
                continue;
            }
            let dist = distance(&d.flat, p);
            if dist <= tol && best.is_none_or(|(b, _)| dist < b) {
                best = Some((dist, l));
            }
        }
        if let Some((_, l)) = best {
            return Some(MapHit::Link(l.id.clone()));
        }
        self.graph
            .frames
            .iter()
            .rev()
            .find(|f| {
                self.layout
                    .groups
                    .get(&f.id)
                    .is_some_and(|r| rect32(r).contains(p))
            })
            .map(|f| MapHit::Frame(f.id.clone()))
    }

    /// The card the arrow `dir` moves to from `from` (a card or a frame); the rule is the
    /// module's.
    pub fn walk(&self, from: &str, dir: Dir) -> Option<Arc<str>> {
        let start = self
            .layout
            .nodes
            .get(from)
            .or_else(|| self.layout.groups.get(from))?
            .center();
        let mut best = None;
        let mut score = f64::INFINITY;
        for (id, r) in self.layout.nodes.iter() {
            if &**id == from {
                continue;
            }
            let c = r.center();
            let (dx, dy) = (c.x - start.x, c.y - start.y);
            let (along, across) = match dir {
                Dir::Right => (dx, dy.abs()),
                Dir::Left => (-dx, dy.abs()),
                Dir::Down => (dy, dx.abs()),
                Dir::Up => (-dy, dx.abs()),
            };
            if along <= 1.0 {
                continue;
            }
            let s = along + 2.0 * across;
            if s < score {
                score = s;
                best = Some(id.clone());
            }
        }
        best
    }

    /// The camera that fits the drawing into a `view`-sized surface (Semafor's fit): centred
    /// when it fits, else from the top-left, zoom within [`MIN_FIT_ZOOM`]…[`MAX_FIT_ZOOM`].
    pub fn fit(&self, view: Size) -> Camera {
        let content = self.size();
        if content.w <= 0.0 || content.h <= 0.0 || view.w <= 0.0 || view.h <= 0.0 {
            return Camera::IDENTITY;
        }
        let (aw, ah) = (view.w - 2.0 * FIT_PAD, view.h - 2.0 * FIT_PAD);
        let k = (aw / content.w)
            .min(ah / content.h)
            .clamp(MIN_FIT_ZOOM, MAX_FIT_ZOOM);
        let place = |c: f32, v: f32, a: f32| {
            if c * k <= a {
                (v - c * k) / 2.0
            } else {
                FIT_PAD
            }
        };
        Camera {
            scale: Point::new(k, k),
            offset: Point::new(place(content.w, view.w, aw), place(content.h, view.h, ah)),
        }
    }

    /// `camera` moved just enough to show `id` [`REVEAL_PAD`] inside a `view`-sized surface
    /// (Semafor's `ensureVisible`; a card larger than the view shows its top-left).
    pub fn reveal(&self, camera: Camera, view: Size, id: &str) -> Camera {
        let Some(r) = self.rect_of(id) else {
            return camera;
        };
        let k = camera.scale;
        let s = Rect::new(
            r.x * k.x + camera.offset.x,
            r.y * k.y + camera.offset.y,
            r.w * k.x,
            r.h * k.y,
        );
        let nudge = |at: f32, len: f32, v: f32| {
            if at < REVEAL_PAD || len > v - 2.0 * REVEAL_PAD {
                REVEAL_PAD - at
            } else if at + len > v - REVEAL_PAD {
                v - REVEAL_PAD - (at + len)
            } else {
                0.0
            }
        };
        Camera {
            scale: k,
            offset: Point::new(
                camera.offset.x + nudge(s.x, s.w, view.w),
                camera.offset.y + nudge(s.y, s.h, view.h),
            ),
        }
    }

    /// The map as a display list for zoom `k` (the settled camera scale its text is set at),
    /// with `selected` (a card, link or frame id) ringed.
    pub fn emit(
        &self,
        palette: &Palette,
        text: &mut TextSystem,
        k: f32,
        selected: Option<&str>,
    ) -> DisplayList {
        let k = k.clamp(MIN_ZOOM, MAX_ZOOM);
        let far = k < FAR_BELOW;
        let mut dl = DisplayList::new(palette.background);
        dl.push_camera(Follow::BOTH);
        {
            let mut pen = Pen {
                dl: &mut dl,
                text,
                k,
            };
            for f in &self.graph.frames {
                if let Some(r) = self.layout.groups.get(&f.id) {
                    self.emit_frame(
                        &mut pen,
                        f,
                        rect32(r),
                        palette,
                        far,
                        selected == Some(&f.id),
                    );
                }
            }
            let mut last = None;
            for (l, d) in self.graph.links.iter().zip(&self.drawn) {
                let Some(d) = d else { continue };
                if self.hidden.contains(l.kind) {
                    continue;
                }
                if selected == Some(&l.id) {
                    last = Some((l, d));
                } else {
                    emit_link(pen.dl, l, d, palette, false);
                }
            }
            if let Some((l, d)) = last {
                emit_link(pen.dl, l, d, palette, true);
            }
            for c in &self.graph.cards {
                if let Some(r) = self.layout.nodes.get(&c.id) {
                    self.emit_card(
                        &mut pen,
                        c,
                        rect32(r),
                        palette,
                        far,
                        selected == Some(&c.id),
                    );
                }
            }
        }
        dl.pop_camera();
        dl
    }

    fn emit_frame(&self, pen: &mut Pen<'_>, f: &Frame, r: Rect, p: &Palette, far: bool, sel: bool) {
        let tone = f.live.as_ref().and_then(|b| box_tone(b.sync, p));
        let dashed = f
            .live
            .as_ref()
            .is_none_or(|b| b.sync == BoxSync::Unreachable);
        let border = tone.map_or(p.grid, |t| t.with_alpha(0.45));
        if dashed {
            dashed_outline(pen.dl, r, FRAME_R, border);
        } else {
            let fill = tone.map_or(p.foreground.with_alpha(0.022), |t| t.with_alpha(0.04));
            pen.dl
                .rect(RoundedRect::new(r, FRAME_R, fill).border(1.0, border));
        }
        if sel {
            pen.dl.rect(
                RoundedRect::new(r.inset(-1.5), FRAME_R + 1.5, Rgba::TRANSPARENT)
                    .border(1.5, p.accent.with_alpha(0.6)),
            );
        }

        // The header: its dot, name, address and counts, then the host's line.
        let (cy1, cy2) = (r.y + 27.0, r.y + 53.0);
        let x = r.x + 34.0;
        let right = r.max_x() - 16.0;
        let dot = f
            .live
            .as_ref()
            .map_or(p.foreground.with_alpha(0.25), |b| box_dot(b.sync, p));
        circle(pen.dl, Point::new(r.x + 21.0, cy1), 5.0, dot);
        let summary = f.live.as_ref().map_or(String::new(), |b| {
            let attention = b
                .apps
                .iter()
                .filter(|a| !matches!(a.sync, AppSync::Synced | AppSync::Elsewhere))
                .count();
            let need = if attention > 0 {
                format!(" · {attention} need a look")
            } else {
                String::new()
            };
            format!("{} · {} apps{need}", box_word(b.sync), b.apps.len())
        });
        let sw = pen.width(&summary, META).min(r.w * 0.45);
        pen.line(&summary, right - sw, cy1, META, p.muted, sw + 1.0);
        let room = right - sw - 12.0 - x;
        pen.line(&f.name, x, cy1, FRAME_NAME, p.foreground, room);
        let addr = f.live.as_ref().and_then(|b| b.addr.as_deref());
        if let Some(addr) = addr {
            let nw = pen.width(&f.name, FRAME_NAME).min(room) + 8.0;
            pen.line(addr, x + nw, cy1, ADDR, p.muted, room - nw);
        }
        if far {
            return;
        }
        let line = match &f.live {
            Some(b) => b.line.as_deref().map(str::to_owned),
            None => Some(format!(
                "{} — declared in the topology, not in the live map",
                f.topo.as_ref().map_or("", |t| &*t.detail)
            )),
        };
        if let Some(line) = line {
            pen.line(&line, r.x + 16.0, cy2, META, p.muted, r.w - 32.0);
        }
    }

    fn emit_card(&self, pen: &mut Pen<'_>, c: &Card, r: Rect, p: &Palette, far: bool, sel: bool) {
        let mut fill = p.band;
        let mut border = p.grid;
        let mut dashed = false;
        let mut ink = p.foreground;
        let mut fade = 1.0;
        match &c.what {
            CardKind::App {
                app: Some(a),
                reachable,
                ..
            } => {
                if let Some(t) = app_tone(a.sync, p) {
                    let (b, f) = match a.sync {
                        AppSync::Error => (0.5, 0.10),
                        AppSync::Live => (0.5, 0.15),
                        _ => (0.4, 0.10),
                    };
                    border = t.with_alpha(b);
                    fill = p.band.lerp(t, f);
                }
                if a.sync == AppSync::Elsewhere {
                    dashed = true;
                    ink = p.muted;
                }
                if !reachable {
                    fade = 0.6;
                }
            }
            CardKind::App { app: None, .. } => {
                fill = Rgba::TRANSPARENT;
                dashed = true;
                ink = p.muted;
            }
            CardKind::Place { node, .. } => match node.kind {
                NodeKind::ExternalBox => {
                    dashed = true;
                    fill = p.band.lerp(p.foreground, 0.03);
                }
                NodeKind::External => fill = p.band.lerp(p.foreground, 0.03),
                _ => {}
            },
        }
        if sel && fill.a > 0.0 {
            fill = fill.lerp(p.accent, 0.08);
        }
        let fade = |c: Rgba| c.with_alpha(c.a * fade);
        if dashed {
            if fill.a > 0.0 {
                pen.dl.rect(RoundedRect::new(r, CARD_R, fade(fill)));
            }
            dashed_outline(pen.dl, r, CARD_R, fade(border));
        } else {
            pen.dl
                .rect(RoundedRect::new(r, CARD_R, fade(fill)).border(1.0, fade(border)));
        }

        // Two rows (the name, the detail) centred as one block, or the name alone.
        let (name, detail, font) = match &c.what {
            CardKind::App {
                name, app: Some(a), ..
            } => (&**name, a.note.as_deref(), NAME),
            CardKind::App { name, .. } => (&**name, Some("declared · not in the live map"), NAME),
            CardKind::Place { node, .. } => (&*node.label, Some(&*node.detail), PLACE_NAME),
        };
        let detail = detail.filter(|d| !far && !d.is_empty());
        let top = (r.h - 38.0) / 2.0;
        let cy1 = if detail.is_some() {
            r.y + top + 9.75
        } else {
            r.y + r.h / 2.0
        };
        let x = r.x + 34.0;
        let glyph = Point::new(r.x + 18.0, cy1);
        let mut right = r.max_x() - 10.0;
        match &c.what {
            CardKind::App { app: Some(a), .. } => {
                circle(pen.dl, glyph, 4.0, fade(app_dot(a.sync, p)));
                if a.sync != AppSync::Elsewhere || a.health != Health::Unknown {
                    circle(
                        pen.dl,
                        Point::new(right - 4.0, cy1),
                        4.0,
                        fade(health_dot(a.health, p)),
                    );
                    right -= 16.0;
                }
            }
            CardKind::App { app: None, .. } => {}
            CardKind::Place { node, copies } => {
                let mark = p.muted;
                let at = Rect::new(glyph.x - 5.0, glyph.y - 5.0, 10.0, 10.0);
                let radius = if node.kind == NodeKind::Storage {
                    2.5
                } else {
                    5.0
                };
                pen.dl
                    .rect(RoundedRect::new(at, radius, Rgba::TRANSPARENT).border(1.25, mark));
                if let Some(state) = copies.and_then(|c| c.state) {
                    circle(pen.dl, Point::new(right - 4.0, cy1), 4.0, fresh(state, p));
                    right -= 16.0;
                }
            }
        }
        pen.line(name, x, cy1, font, fade(ink), right - x);
        if let Some(d) = detail {
            pen.line(
                d,
                x,
                r.y + top + 29.75,
                DETAIL,
                fade(p.muted),
                r.max_x() - 10.0 - x,
            );
        }
        if sel {
            pen.dl.rect(
                RoundedRect::new(r.inset(-2.0), CARD_R + 2.0, Rgba::TRANSPARENT)
                    .border(2.0, p.accent),
            );
        }
    }
}

/// The zoom band a camera scale falls in (√2 steps, as the timeline's levels): the host
/// re-emits when the settled band changes. Rounded down, so the band never exceeds the
/// camera: text set at the band (glyphs never scale) stays inside the world room laid out for
/// it, and a name never runs under the address beside it.
pub fn zoom_band(k: f32) -> f32 {
    let k = k.clamp(MIN_ZOOM, MAX_ZOOM);
    2f32.powf((k.log2() * 2.0 + 1e-4).floor() / 2.0)
}

fn emit_link(dl: &mut DisplayList, l: &Link, d: &Drawn, p: &Palette, selected: bool) {
    let color = if l.deploying {
        p.ok
    } else if let Some(state) = l.copies.and_then(|c| c.state) {
        fresh(state, p)
    } else {
        // Semafor's `--graph-edge`: the foreground 26 % over the card.
        p.band.lerp(p.foreground, 0.26)
    };
    let mut stroke = Stroke::new(if selected { 2.6 } else { 1.4 }, color).round();
    if l.deploying {
        stroke = stroke.dash(Dash {
            on: 6.0,
            off: 8.0,
            phase: 0.0,
            speed: FLOW_SPEED,
        });
    } else if l.dashed {
        stroke = stroke.dash(Dash {
            on: 5.0,
            off: 5.0,
            phase: 0.0,
            speed: 0.0,
        });
    }
    dl.path(PathOp::stroke(d.line.clone(), stroke));
    if l.arrow != Arrow::None {
        dl.path(PathOp::fill(d.head.clone(), color));
    }
    if l.arrow == Arrow::Both {
        dl.path(PathOp::fill(d.tail.clone(), color));
    }
}

/// Text placed by its line's vertical centre, at the emitted zoom.
struct Pen<'a> {
    dl: &'a mut DisplayList,
    text: &'a mut TextSystem,
    k: f32,
}

impl Pen<'_> {
    fn spec(&self, f: Font) -> FontSpec {
        let spec = if f.mono {
            FontSpec::mono(f.size * self.k)
        } else {
            FontSpec::ui(f.size * self.k)
        };
        spec.weight(f.weight)
    }

    /// One line from `x`, its box centred on `cy`, at most `max_w` wide (world points).
    fn line(&mut self, s: &str, x: f32, cy: f32, f: Font, color: Rgba, max_w: f32) {
        let px = f.size * self.k;
        if s.is_empty() || px < MIN_TEXT_PX || max_w <= 0.0 {
            return;
        }
        let spec = self.spec(f);
        let m = self.text.metrics(spec);
        // The renderer adds the ascent (view points) to the origin to find the baseline it
        // anchors in the world, so the origin takes it back off.
        let baseline = cy + (m.ascent - m.descent) / (2.0 * self.k);
        let mut run = TextRun::new(s, Point::new(x, baseline - m.ascent), px, color)
            .weight(f.weight)
            .max_width(max_w * self.k);
        if f.mono {
            run = run.mono();
        }
        self.dl.text(run);
    }

    /// How wide `s` draws, world points.
    fn width(&mut self, s: &str, f: Font) -> f32 {
        if s.is_empty() || f.size * self.k < MIN_TEXT_PX {
            return 0.0;
        }
        let spec = self.spec(f);
        self.text.shape(s, spec).width / self.k
    }
}

fn rect32(r: &Rect64) -> Rect {
    Rect::new(r.x as f32, r.y as f32, r.w as f32, r.h as f32)
}

fn pt32(p: Point64) -> Point {
    Point::new(p.x as f32, p.y as f32)
}

fn drawn(route: &EdgeRoute) -> Drawn {
    let mut line = Path::new();
    let mut flat = Vec::new();
    let mut at = Point::ZERO;
    for v in &route.path {
        match *v {
            RouteVerb::Move(p) => {
                at = pt32(p);
                line.move_to(at);
                flat.push(at);
            }
            RouteVerb::Line(p) => {
                at = pt32(p);
                line.line_to(at);
                flat.push(at);
            }
            RouteVerb::Cubic(c1, c2, p) => {
                let (c1, c2, p) = (pt32(c1), pt32(c2), pt32(p));
                line.cubic_to(c1, c2, p);
                for i in 1..=FLAT_STEPS {
                    flat.push(cubic(at, c1, c2, p, i as f32 / FLAT_STEPS as f32));
                }
                at = p;
            }
        }
    }
    let triangle = |t: &[Point64; 3]| {
        let mut p = Path::new();
        p.move_to(pt32(t[0]))
            .line_to(pt32(t[1]))
            .line_to(pt32(t[2]))
            .close();
        Arc::new(p)
    };
    let (head, tail) = (triangle(&route.head), triangle(&route.tail));
    let bounds = line.bounds().union(&head.bounds()).union(&tail.bounds());
    Drawn {
        line: Arc::new(line),
        head,
        tail,
        flat,
        bounds,
    }
}

fn cubic(p0: Point, c1: Point, c2: Point, p3: Point, t: f32) -> Point {
    let u = 1.0 - t;
    let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
    Point::new(
        a * p0.x + b * c1.x + c * c2.x + d * p3.x,
        a * p0.y + b * c1.y + c * c2.y + d * p3.y,
    )
}

/// The distance from `p` to a polyline.
fn distance(flat: &[Point], p: Point) -> f32 {
    let seg = |a: Point, b: Point| {
        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let len = dx * dx + dy * dy;
        let t = if len > 0.0 {
            (((p.x - a.x) * dx + (p.y - a.y) * dy) / len).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let (ex, ey) = (a.x + t * dx - p.x, a.y + t * dy - p.y);
        (ex * ex + ey * ey).sqrt()
    };
    match flat {
        [] => f32::INFINITY,
        [only] => seg(*only, *only),
        _ => flat
            .windows(2)
            .map(|w| seg(w[0], w[1]))
            .fold(f32::INFINITY, f32::min),
    }
}

fn circle(dl: &mut DisplayList, c: Point, radius: f32, color: Rgba) {
    dl.rect(RoundedRect::new(
        Rect::new(c.x - radius, c.y - radius, 2.0 * radius, 2.0 * radius),
        radius,
        color,
    ));
}

/// A dashed 1-point border along a rounded rect (CSS `border-dashed`).
fn dashed_outline(dl: &mut DisplayList, r: Rect, radius: f32, color: Rgba) {
    let rad = radius.min(r.w / 2.0).min(r.h / 2.0);
    let kappa = 0.552_284_8 * rad;
    let r = r.inset(0.5);
    let (x0, y0, x1, y1) = (r.x, r.y, r.max_x(), r.max_y());
    let mut p = Path::new();
    p.move_to(Point::new(x0 + rad, y0))
        .line_to(Point::new(x1 - rad, y0))
        .cubic_to(
            Point::new(x1 - rad + kappa, y0),
            Point::new(x1, y0 + rad - kappa),
            Point::new(x1, y0 + rad),
        )
        .line_to(Point::new(x1, y1 - rad))
        .cubic_to(
            Point::new(x1, y1 - rad + kappa),
            Point::new(x1 - rad + kappa, y1),
            Point::new(x1 - rad, y1),
        )
        .line_to(Point::new(x0 + rad, y1))
        .cubic_to(
            Point::new(x0 + rad - kappa, y1),
            Point::new(x0, y1 - rad + kappa),
            Point::new(x0, y1 - rad),
        )
        .line_to(Point::new(x0, y0 + rad))
        .cubic_to(
            Point::new(x0, y0 + rad - kappa),
            Point::new(x0 + rad - kappa, y0),
            Point::new(x0 + rad, y0),
        )
        .close();
    dl.path(PathOp::stroke(
        Arc::new(p),
        Stroke::new(1.0, color).round().dash(Dash {
            on: 4.0,
            off: 3.0,
            phase: 0.0,
            speed: 0.0,
        }),
    ));
}

/// A frame's tint by its box's sync: rolling out is running (`ok`), pending, held and pinned
/// wait (Semafor's violet pin has no status token: a pin holds the box as `held` does).
fn box_tone(s: BoxSync, p: &Palette) -> Option<Rgba> {
    match s {
        BoxSync::Rolling => Some(p.ok),
        BoxSync::Pending | BoxSync::Held | BoxSync::Pinned => Some(p.warning),
        BoxSync::Errors => Some(p.danger),
        BoxSync::Synced | BoxSync::Seeded | BoxSync::Unreachable => None,
    }
}

fn box_dot(s: BoxSync, p: &Palette) -> Rgba {
    box_tone(s, p).unwrap_or(match s {
        BoxSync::Synced => p.ok,
        BoxSync::Seeded => p.foreground.with_alpha(0.4),
        _ => p.foreground.with_alpha(0.25),
    })
}

fn box_word(s: BoxSync) -> &'static str {
    match s {
        BoxSync::Synced => "Synced",
        BoxSync::Seeded => "Seeded",
        BoxSync::Rolling => "Rolling out",
        BoxSync::Pending => "Pending",
        BoxSync::Held => "Held",
        BoxSync::Errors => "Errors",
        BoxSync::Pinned => "Pinned",
        BoxSync::Unreachable => "Unreachable",
    }
}

fn app_tone(s: AppSync, p: &Palette) -> Option<Rgba> {
    match s {
        AppSync::Pending | AppSync::Held | AppSync::CertHeld | AppSync::Roll => Some(p.warning),
        AppSync::Error => Some(p.danger),
        AppSync::Live => Some(p.ok),
        AppSync::Synced | AppSync::Elsewhere => None,
    }
}

fn app_dot(s: AppSync, p: &Palette) -> Rgba {
    app_tone(s, p).unwrap_or(if s == AppSync::Synced { p.ok } else { p.muted })
}

fn health_dot(h: Health, p: &Palette) -> Rgba {
    match h {
        Health::Healthy => p.ok,
        Health::Degraded => p.warning,
        Health::Down => p.danger,
        Health::Unknown => p.muted,
    }
}

fn fresh(f: Freshness, p: &Palette) -> Rgba {
    match f {
        Freshness::Fresh => p.ok,
        Freshness::Near => p.warning,
        Freshness::Stale => p.danger,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Cards placed by hand (centres), bypassing the layout.
    fn placed(cards: &[(&str, f64, f64)]) -> MapScene {
        let mut layout = GraphLayout::default();
        for &(id, x, y) in cards {
            layout.nodes.insert(
                id.into(),
                Rect64 {
                    x: x - 10.0,
                    y: y - 10.0,
                    w: 20.0,
                    h: 20.0,
                },
            );
        }
        MapScene {
            options: MAP_LAYOUT,
            graph: Graph::default(),
            input: LayoutInput::default(),
            layout,
            drawn: Vec::new(),
            hidden: LinkKinds::NONE,
        }
    }

    #[test]
    fn being_off_axis_costs_twice_being_far() {
        // From a: b is nearer (100 ahead, 60 off: 220) than c (200 ahead: 200), yet c wins.
        let s = placed(&[("a", 0.0, 0.0), ("b", 100.0, 60.0), ("c", 200.0, 0.0)]);
        assert_eq!(s.walk("a", Dir::Right).as_deref(), Some("c"));
        // Up from b: a and c tie (60 + 2 × 100); the earlier in the layout's order wins.
        assert_eq!(s.walk("b", Dir::Up).as_deref(), Some("a"));
        // Only what lies more than 1 pt ahead counts.
        let s = placed(&[("a", 0.0, 0.0), ("b", 1.0, 80.0), ("c", -300.0, 0.0)]);
        assert_eq!(s.walk("a", Dir::Right), None);
        assert_eq!(s.walk("a", Dir::Left).as_deref(), Some("c"));
    }

    #[test]
    fn zoom_bands_step_by_root_two() {
        assert_eq!(zoom_band(1.0), 1.0);
        assert_eq!(zoom_band(1.3), 1.0, "a band never exceeds the camera");
        assert!((zoom_band(1.42) - std::f32::consts::SQRT_2).abs() < 1e-5);
        for i in 0..200 {
            let k = 0.12 + i as f32 * 0.012;
            assert!(zoom_band(k) <= k * 1.0001, "{k}");
        }
        assert!((zoom_band(0.4) - 2f32.powf(-1.5)).abs() < 1e-5);
        assert_eq!(zoom_band(9.0), zoom_band(MAX_ZOOM));
    }
}
