//! The drawn scene: everything a timeline paints and the pointer hits, built once per semantic
//! change (rendered window, zoom level, data, selection) and only read per frame. Items carry
//! their time and row; the camera maps world points to the view, so a pan or a pinch inside a
//! level touches neither the scene nor its display list.
//!
//! World coordinates are origin-relative: x = (t − origin) · the level's scale, with the origin
//! at the rendered window's start, so an `f32` keeps sub-point precision at any date.
//!
//! Hit testing is a per-row list sorted by start: a binary search to the pointer's time plus
//! the widest item, then back while an item can still reach the pointer (a running maximum of
//! ends, so a long job is found without scanning its row), keeping the nearest whose hit box
//! holds the pointer. Hits follow paint order: the selected mark, then items (the top ones on
//! a tie), then a rail's line, then a band.

use crate::density::{Cluster, Drawn, Folded, Rail, fold_window};
use crate::geometry::{AXIS_PT, Semantic, View, level_scale};
use crate::layout::{GroupSpec, Layout};
use crate::lens::{LensSpec, Palette};
use crate::mark::{Band, Bin, Mark, Schedule, Shape};
use crate::time::{Ms, span_label, ticks_between};
use crate::tracks::{self, Tracks, track_geometry, tracked_row_height};
use canvas_draw::{
    Align, Camera, Dash, DisplayList, Follow, Path, PathOp, Point, Rect, Rgba, RoundedRect, Stroke,
    TextRun, Weight,
};
use canvas_text::{FontSpec, TextSystem};
use std::sync::Arc;

/// The hit area reaches this far past a mark's shape.
pub const HIT_PT: f32 = 6.0;
const PILL_H: f32 = 13.0;
const BAND_INSET: f32 = 4.0;
/// A bar this thick (points) writes its label inside.
const LABEL_MIN_H: f32 = 12.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemRef {
    Mark(usize),
    Cluster(usize),
}

/// One hittable, drawable item in world terms.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Item {
    pub what: ItemRef,
    pub row: usize,
    pub t: Ms,
    /// A span's end (`None`: running, to now); a point's is its start.
    pub t1: Option<Ms>,
    /// Centre, content points (unscrolled).
    pub y: f32,
    pub hw: f32,
    pub hh: f32,
    /// Never folded (stands out, selected): drawn and hit on top.
    pub top: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Hit {
    Mark(Arc<str>),
    Cluster(Cluster),
    Rail(Rail),
    Band(Band),
}

/// Everything one scene is built from.
pub struct SceneInput<'a> {
    pub spec: LensSpec,
    /// Sorted by start.
    pub marks: &'a [Mark],
    pub bins: &'a [Bin],
    pub bands: &'a [Band],
    pub schedules: &'a [Schedule],
    pub groups: &'a [GroupSpec],
    pub k: f32,
    pub semantic: Semantic,
    pub now: Ms,
    /// The fold grid's anchor: fixed, so a pan never reshuffles clusters.
    pub grid_origin: Ms,
    pub selected: Option<&'a str>,
    pub playhead: Option<Ms>,
}

#[derive(Debug, Clone)]
pub struct Scene {
    pub semantic: Semantic,
    /// World x = (t − origin) · `scale`.
    pub origin: Ms,
    pub scale: f64,
    pub now: Ms,
    pub layout: Layout,
    pub marks: Vec<Mark>,
    pub clusters: Vec<Cluster>,
    pub rails: Vec<Rail>,
    pub schedules: Vec<Schedule>,
    pub bins: Vec<Bin>,
    pub bands: Vec<Band>,
    pub items: Vec<Item>,
    /// Per row, item indices sorted by start, and each list's running maximum end.
    rows: Vec<Vec<usize>>,
    ends: Vec<Vec<Ms>>,
    /// The widest item's half width plus [`HIT_PT`].
    reach: f32,
    pub selected: Option<usize>,
    pub playhead: Option<Ms>,
    pub tracks: Tracks,
    /// 0 marks only … 1 bins only, at the level's scale.
    pub aggregation: f32,
    pub until: Ms,
    pub live_in_window: bool,
}

impl Scene {
    pub fn build(i: SceneInput<'_>) -> Scene {
        let sem = i.semantic;
        let scale = level_scale(sem.level);
        let until = i.now + i.spec.future;
        let level_view = View {
            t0: sem.from,
            scale,
            width: (sem.to - sem.from) * scale / 3.0,
        };
        let aggregation = crate::geometry::aggregation(&level_view, &i.spec.zoom) as f32;
        let folded = if aggregation < 1.0 {
            fold_window(
                i.spec.fold,
                i.marks,
                i.schedules,
                sem.from,
                sem.to,
                until,
                sem.level,
                i.grid_origin,
                i.selected,
            )
        } else {
            Folded::default()
        };
        let marks: Vec<Mark> = folded
            .marks
            .iter()
            .map(|d| match d {
                Drawn::Loaded(ix) => i.marks[*ix].clone(),
                Drawn::Repeat(m) => (**m).clone(),
            })
            .collect();
        let tracks = if i.spec.tracks {
            tracks::assign(&marks, sem.from, sem.to, i.now)
        } else {
            Tracks::default()
        };
        let layout = Layout::of(i.groups, i.k, |row| {
            tracks
                .rows
                .get(row)
                .map(|&n| tracked_row_height(n, sem.level))
        });
        let mut s = Scene {
            semantic: sem,
            origin: sem.from,
            scale,
            now: i.now,
            rows: vec![Vec::new(); layout.rows.len()],
            ends: vec![Vec::new(); layout.rows.len()],
            layout,
            marks,
            clusters: folded.clusters,
            rails: folded.rails,
            schedules: i.schedules.to_vec(),
            bins: if aggregation > 0.0 {
                i.bins
                    .iter()
                    .filter(|b| b.from + b.width > sem.from && b.from < sem.to)
                    .cloned()
                    .collect()
            } else {
                Vec::new()
            },
            bands: i
                .bands
                .iter()
                .filter(|b| b.to.unwrap_or(i.now) > sem.from && b.from < sem.to)
                .cloned()
                .collect(),
            items: Vec::new(),
            reach: HIT_PT,
            selected: None,
            playhead: i.playhead,
            tracks,
            aggregation,
            until,
            live_in_window: false,
        };
        s.index(i.selected);
        s
    }

    fn index(&mut self, selected: Option<&str>) {
        let k = self.layout.k;
        for (mi, m) in self.marks.iter().enumerate() {
            let Some(&ri) = self.layout.by_key.get(&m.row) else {
                continue;
            };
            let row = &self.layout.rows[ri];
            let (y, hh) = match self.tracks.of.get(&mi) {
                Some(&track) => {
                    let n = self.tracks.rows.get(&m.row).copied().unwrap_or(1);
                    let (pitch, bar) = track_geometry(n, row.h / k, self.semantic.level);
                    (
                        row.top + (tracks::TRACK_PAD + pitch * (track as f32 + 0.5)) * k,
                        bar * k / 2.0,
                    )
                }
                None => (row.y + m.paint.dy * k, m.paint.h * k / 2.0),
            };
            let t1 = match &m.paint.span {
                Some(_) => m.end,
                None => Some(m.start),
            };
            self.live_in_window |= m.live;
            let top = m.stands_out || selected == Some(&*m.id);
            if selected == Some(&*m.id) {
                self.selected = Some(self.items.len());
            }
            self.items.push(Item {
                what: ItemRef::Mark(mi),
                row: ri,
                t: m.start,
                t1,
                y,
                hw: m.paint.w * k / 2.0,
                hh,
                top,
            });
        }
        for (ci, c) in self.clusters.iter().enumerate() {
            let Some(&ri) = self.layout.by_key.get(&c.row) else {
                continue;
            };
            let w = pill_width(c.count) * k;
            self.items.push(Item {
                what: ItemRef::Cluster(ci),
                row: ri,
                t: c.at,
                t1: Some(c.at),
                y: self.layout.rows[ri].y,
                hw: w / 2.0,
                hh: PILL_H * k / 2.0,
                top: false,
            });
        }
        for (ii, it) in self.items.iter().enumerate() {
            self.rows[it.row].push(ii);
            self.reach = self.reach.max(it.hw + HIT_PT);
        }
        let now = self.now;
        for (row, ends) in self.rows.iter_mut().zip(self.ends.iter_mut()) {
            row.sort_by(|&a, &b| self.items[a].t.total_cmp(&self.items[b].t));
            let mut run = f64::NEG_INFINITY;
            for &ii in row.iter() {
                let it = &self.items[ii];
                run = run.max(it.t1.unwrap_or(f64::INFINITY).max(it.t));
                ends.push(if it.t1.is_none() { now.max(run) } else { run });
            }
        }
    }

    /// The scene's world x of time `t`, points.
    pub fn x(&self, t: Ms) -> f32 {
        ((t - self.origin) * self.scale) as f32
    }

    /// The camera that draws this scene's world at `view` (lanes `label_w` points from the
    /// left) scrolled down by `scroll`.
    pub fn camera(&self, view: &View, label_w: f32, scroll: f32) -> Camera {
        Camera {
            scale: Point::new((view.scale / self.scale) as f32, 1.0),
            offset: Point::new(
                label_w + ((self.origin - view.t0) * view.scale) as f32,
                -scroll,
            ),
        }
    }

    /// An item's extent at `view`, points across the lanes: a point's centre, a span's whole run.
    fn extent(&self, it: &Item, v: &View) -> (f64, f64) {
        let x0 = v.x_of(it.t);
        match it.what {
            ItemRef::Mark(mi) if self.marks[mi].paint.span.is_some() => {
                let span = self.marks[mi].paint.span.as_ref().expect("checked");
                let end = it.t1.unwrap_or(self.now);
                let x1 = match span.run {
                    Some(run) => {
                        v.x_of(end).max(v.x_of(run) + f64::from(it.hw) * 2.0) - f64::from(it.hw)
                    }
                    None => v.x_of(end),
                };
                (x0, x1)
            }
            _ => (x0, x0),
        }
    }

    fn holds(&self, it: &Item, v: &View, px: f64, py: f32) -> Option<f64> {
        let (x0, x1) = self.extent(it, v);
        let dx = if px < x0 {
            x0 - px
        } else if px > x1 {
            px - x1
        } else {
            0.0
        };
        (dx <= f64::from(it.hw + HIT_PT) && (it.y - py).abs() <= it.hh + HIT_PT).then_some(dx)
    }

    /// What lanes point (`px` across the lanes, `py` content points down, scroll added) is on,
    /// in paint order from the top.
    pub fn hit(&self, v: &View, px: f64, py: f32) -> Option<Hit> {
        if let Some(si) = self.selected
            && self.holds(&self.items[si], v, px, py).is_some()
        {
            return self.hit_of(si);
        }
        let row = self.layout.row_at(py);
        let mut best: Option<(usize, f64)> = None;
        if let Some(row) = row {
            let t = v.t_of(px);
            let reach = f64::from(self.reach) / v.scale;
            let lo = row.index.saturating_sub(1);
            let hi = (row.index + 1).min(self.rows.len() - 1);
            for ri in lo..=hi {
                if self.layout.rows[ri].group != row.group {
                    continue;
                }
                let items = &self.rows[ri];
                let ends = &self.ends[ri];
                let upper = items.partition_point(|&ii| self.items[ii].t <= t + reach);
                for j in (0..upper).rev() {
                    if ends[j] < t - reach {
                        break;
                    }
                    let it = &self.items[items[j]];
                    let Some(dx) = self.holds(it, v, px, py) else {
                        continue;
                    };
                    let dy = f64::from(it.y - py);
                    let d = dx * dx + dy * dy;
                    let wins = best
                        .is_none_or(|(b, bd)| d < bd || (d == bd && it.top && !self.items[b].top));
                    if wins {
                        best = Some((items[j], d));
                    }
                }
            }
        }
        if let Some((ii, _)) = best {
            return self.hit_of(ii);
        }
        if let Some(row) = row {
            for r in &self.rails {
                if r.row == row.key
                    && (py - row.y).abs() <= 5.0
                    && px >= v.x_of(r.from)
                    && px <= v.x_of(self.until)
                {
                    return Some(Hit::Rail(r.clone()));
                }
            }
        }
        for b in &self.bands {
            let Some(g) = self.layout.groups.iter().find(|g| g.key == b.group) else {
                continue;
            };
            if py < g.top || py > g.top + g.h {
                continue;
            }
            if px >= v.x_of(b.from) && px <= v.x_of(b.to.unwrap_or(self.now)) {
                return Some(Hit::Band(b.clone()));
            }
        }
        None
    }

    fn hit_of(&self, ii: usize) -> Option<Hit> {
        Some(match self.items[ii].what {
            ItemRef::Mark(mi) => Hit::Mark(self.marks[mi].id.clone()),
            ItemRef::Cluster(ci) => Hit::Cluster(self.clusters[ci].clone()),
        })
    }

    /// The scene as a display list: lanes `size` points, the label column `label_w` wide. Its
    /// camera layers are placed by [`Scene::camera`].
    pub fn emit(
        &self,
        size: (f32, f32),
        label_w: f32,
        palette: &Palette,
        text: &mut TextSystem,
        view: &View,
    ) -> DisplayList {
        let (w, h) = size;
        let k = self.layout.k;
        let mut dl = DisplayList::new(palette.background);
        let lanes = Rect::new(
            label_w,
            AXIS_PT,
            (w - label_w).max(0.0),
            (h - AXIS_PT).max(0.0),
        );

        // Group bands and lane borders: they scroll, they never pan.
        dl.push_clip(Rect::new(0.0, AXIS_PT, w, (h - AXIS_PT).max(0.0)));
        dl.push_camera(Follow::Y);
        for (gi, g) in self.layout.groups.iter().enumerate() {
            if gi % 2 == 1 {
                dl.rect(RoundedRect::new(
                    Rect::new(0.0, g.top, w, g.h),
                    0.0,
                    palette.band,
                ));
            }
            dl.rect(RoundedRect::new(
                Rect::new(0.0, g.top + g.h - 1.0, w, 1.0),
                0.0,
                palette.grid,
            ));
        }
        dl.pop_camera();
        dl.pop_clip();

        let ticks = ticks_between(self.semantic.from, self.semantic.to, self.scale);
        dl.push_clip(lanes);
        // Tick lines: they pan, they never scroll.
        dl.push_camera(Follow::X);
        for t in &ticks {
            let color = if t.day {
                palette.grid.lerp(palette.muted, 0.35)
            } else {
                palette.grid
            };
            dl.rect(RoundedRect::new(
                Rect::new(self.x(t.t), AXIS_PT, 1.0, h),
                0.0,
                color,
            ));
        }
        dl.pop_camera();

        dl.push_camera(Follow::BOTH);
        self.emit_bands(&mut dl, palette);
        self.emit_bins(&mut dl, palette);
        self.emit_rails(&mut dl, palette, text);
        for (ii, it) in self.items.iter().enumerate() {
            if !it.top && Some(ii) != self.selected {
                self.emit_item(&mut dl, it, palette, text);
            }
        }
        for (ii, it) in self.items.iter().enumerate() {
            if it.top && Some(ii) != self.selected {
                self.emit_item(&mut dl, it, palette, text);
            }
        }
        if let Some(si) = self.selected {
            let it = self.items[si];
            self.emit_item(&mut dl, &it, palette, text);
            self.emit_selection(&mut dl, &it, palette);
        }
        dl.pop_camera();

        // Now and the playhead: they pan, they never scroll.
        dl.push_camera(Follow::X);
        dl.rect(RoundedRect::new(
            Rect::new(self.x(self.now) - 0.5, AXIS_PT, 1.0, h),
            0.0,
            palette.ok.with_alpha(0.7),
        ));
        if let Some(t) = self.playhead {
            dl.rect(RoundedRect::new(
                Rect::new(self.x(t) - 1.0, AXIS_PT, 2.0, h),
                0.0,
                palette.accent,
            ));
        }
        dl.pop_camera();
        dl.pop_clip();

        // The axis strip.
        dl.push_clip(Rect::new(label_w, 0.0, (w - label_w).max(0.0), AXIS_PT));
        dl.push_camera(Follow::X);
        for t in &ticks {
            let x = self.x(t.t);
            dl.rect(RoundedRect::new(
                Rect::new(x, AXIS_PT - 6.0, 1.0, 6.0),
                0.0,
                palette.muted,
            ));
            let run = TextRun::new(
                t.label.clone(),
                Point::new(x + 4.0, 8.0),
                10.5,
                palette.muted,
            );
            dl.text(if t.day {
                run.weight(Weight::Semibold)
            } else {
                run
            });
        }
        if let Some(t) = self.playhead {
            dl.rect(
                RoundedRect::new(
                    Rect::new(self.x(t) - 4.0, AXIS_PT - 8.0, 8.0, 8.0),
                    2.0,
                    palette.accent,
                )
                .pinned(),
            );
        }
        dl.pop_camera();
        dl.pop_clip();

        // The label column: it scrolls, it never pans.
        dl.push_clip(Rect::new(0.0, AXIS_PT, label_w, (h - AXIS_PT).max(0.0)));
        dl.push_camera(Follow::Y);
        for g in &self.layout.groups {
            dl.text(
                TextRun::new(
                    g.label.to_string(),
                    Point::new(10.0, g.top + 6.0 * k),
                    11.0 * k,
                    palette.foreground,
                )
                .weight(Weight::Semibold)
                .max_width(label_w - 16.0),
            );
            for r in &self.layout.rows[g.rows.clone()] {
                let (glyph, x) = match r.tint {
                    Some(tint) => (Some(tint), 22.0),
                    None => (None, 14.0),
                };
                if let Some(tint) = glyph {
                    dl.rect(RoundedRect::new(
                        Rect::new(12.0, r.label_y - 3.5 * k, 7.0 * k, 7.0 * k),
                        2.0 * k,
                        tint,
                    ));
                }
                dl.text(
                    TextRun::new(
                        r.label.to_string(),
                        Point::new(x, r.label_y - 7.0 * k),
                        11.0 * k,
                        palette.muted,
                    )
                    .max_width(label_w - x - 6.0),
                );
            }
        }
        dl.pop_camera();
        dl.pop_clip();

        // The zoom, in the corner.
        dl.text(
            TextRun::new(
                span_label(view.span()),
                Point::new(10.0, 8.0),
                10.5,
                palette.muted,
            )
            .max_width(label_w - 14.0),
        );
        dl
    }

    fn emit_bands(&self, dl: &mut DisplayList, p: &Palette) {
        for b in &self.bands {
            let Some(g) = self.layout.groups.iter().find(|g| g.key == b.group) else {
                continue;
            };
            let x0 = self.x(b.from);
            let x1 = self.x(b.to.unwrap_or(self.now));
            let r = Rect::new(
                x0,
                g.top + BAND_INSET,
                (x1 - x0).max(1.0),
                g.h - 2.0 * BAND_INSET,
            );
            dl.rect(
                RoundedRect::new(r, 3.0, b.color.with_alpha(0.14))
                    .border(1.0, b.color.with_alpha(0.45)),
            );
            dl.text(
                TextRun::new(
                    b.label.to_string(),
                    Point::new(x0 + 4.0, g.top + BAND_INSET + 2.0),
                    10.0,
                    p.foreground,
                )
                .max_width((x1 - x0 - 8.0).max(0.0)),
            );
        }
    }

    fn emit_bins(&self, dl: &mut DisplayList, p: &Palette) {
        let alpha = self.aggregation;
        if alpha <= 0.0 {
            return;
        }
        let k = self.layout.k;
        for b in &self.bins {
            let Some(&ri) = self.layout.by_key.get(&b.row) else {
                continue;
            };
            let row = &self.layout.rows[ri];
            let x0 = self.x(b.from);
            let x1 = self.x(b.from + b.width);
            let max = (row.h - 4.0 * k).max(3.0);
            let hgt = (b.count as f32 * b.grow * k).clamp(3.0 * k, max);
            let r = Rect::new(x0 + 0.5, row.y - hgt / 2.0, (x1 - x0 - 1.0).max(1.0), hgt);
            let fill = if b.scheduled { None } else { Some(b.color) };
            match fill {
                Some(c) => dl.rect(RoundedRect::new(r, 1.5, c.with_alpha(c.a * alpha))),
                None => dl.rect(
                    RoundedRect::new(r, 1.5, Rgba::TRANSPARENT)
                        .border(1.0, b.color.with_alpha(alpha)),
                ),
            }
            if b.failures > 0 && b.count > 0 {
                let fh = hgt * (b.failures as f32 / b.count as f32);
                dl.rect(RoundedRect::new(
                    Rect::new(r.x, r.max_y() - fh, r.w, fh),
                    1.5,
                    p.danger.with_alpha(alpha),
                ));
            }
        }
    }

    fn emit_rails(&self, dl: &mut DisplayList, p: &Palette, _text: &mut TextSystem) {
        for r in &self.rails {
            let Some(&ri) = self.layout.by_key.get(&r.row) else {
                continue;
            };
            let y = self.layout.rows[ri].y;
            let mut line = Path::new();
            line.move_to(Point::new(self.x(r.from), y))
                .line_to(Point::new(self.x(self.until), y));
            let color = self
                .schedules
                .get(r.members[0])
                .map_or(p.muted, |s| s.color);
            dl.path(PathOp::stroke(
                Arc::new(line),
                Stroke::new(2.0, color.with_alpha(0.8)).dash(Dash {
                    on: 4.0,
                    off: 3.0,
                    phase: 0.0,
                    speed: 0.0,
                }),
            ));
            let names: Vec<String> = r
                .members
                .iter()
                .filter_map(|&m| self.schedules.get(m))
                .map(|s| format!("{} · {}", s.name, crate::density::every_label(s.period)))
                .collect();
            dl.text(TextRun::new(
                names.join(", "),
                Point::new(self.x(r.from) + 6.0, y - 14.0),
                10.0,
                p.muted,
            ));
        }
    }

    fn emit_item(&self, dl: &mut DisplayList, it: &Item, p: &Palette, text: &mut TextSystem) {
        let k = self.layout.k;
        match it.what {
            ItemRef::Cluster(ci) => {
                let c = &self.clusters[ci];
                let w = it.hw * 2.0;
                let x = self.x(c.at);
                let tone = if c.scheduled {
                    p.muted.with_alpha(0.6)
                } else {
                    p.data.with_alpha(0.85)
                };
                let r = Rect::new(x - w / 2.0, it.y - it.hh, w, it.hh * 2.0);
                let pill =
                    RoundedRect::new(r, it.hh, if c.scheduled { Rgba::TRANSPARENT } else { tone });
                dl.rect(
                    if c.scheduled {
                        pill.border(1.0, tone)
                    } else {
                        pill
                    }
                    .pinned(),
                );
                dl.text(
                    TextRun::new(
                        c.count.to_string(),
                        Point::new(x - w / 2.0, it.y - 5.5 * k),
                        8.5 * k,
                        p.background,
                    )
                    .weight(Weight::Semibold)
                    .max_width(w)
                    .align(Align::Center),
                );
            }
            ItemRef::Mark(mi) => {
                let m = &self.marks[mi];
                match &m.paint.span {
                    Some(span) => self.emit_span(dl, it, m, span, p, text),
                    None => self.emit_point(dl, it, m, p),
                }
            }
        }
        let _ = k;
    }

    fn emit_point(&self, dl: &mut DisplayList, it: &Item, m: &Mark, p: &Palette) {
        let k = self.layout.k;
        let paint = &m.paint;
        let x = self.x(m.start);
        let (w, h) = (paint.w * k, paint.h * k);
        let r = Rect::new(x - w / 2.0, it.y - h / 2.0, w, h);
        let fill = paint.fill.unwrap_or(Rgba::TRANSPARENT);
        match paint.shape {
            Shape::Circle | Shape::Rect => {
                let radius = if paint.shape == Shape::Circle {
                    w.min(h) / 2.0
                } else {
                    paint.r * k
                };
                let mut rr = RoundedRect::new(r, radius, fill).pinned();
                if let Some(inset) = paint.inset {
                    rr = rr.border(inset.width * k, inset.color);
                } else if paint.fill.is_none() {
                    rr = rr.border(1.5 * k, p.foreground.with_alpha(0.6));
                }
                dl.rect(rr);
            }
            Shape::Diamond => {
                let mut d = Path::new();
                d.move_to(Point::new(x, it.y - h / 2.0))
                    .line_to(Point::new(x + w / 2.0, it.y))
                    .line_to(Point::new(x, it.y + h / 2.0))
                    .line_to(Point::new(x - w / 2.0, it.y))
                    .close();
                let mut op = PathOp::fill(Arc::new(d), fill);
                if let Some(inset) = paint.inset {
                    op.stroke = Some(Stroke::new(inset.width * k, inset.color).round());
                }
                dl.path(op);
            }
        }
        if let Some(ring) = paint.ring {
            let rr = Rect::new(r.x - 3.0 * k, r.y - 3.0 * k, r.w + 6.0 * k, r.h + 6.0 * k);
            dl.rect(
                RoundedRect::new(rr, rr.w / 2.0, Rgba::TRANSPARENT)
                    .border(1.0, ring)
                    .pinned(),
            );
        }
        if let Some((glyph, color)) = &paint.glyph {
            dl.text(
                TextRun::new(
                    glyph.to_string(),
                    Point::new(r.x, it.y - 5.0 * k),
                    9.0 * k,
                    *color,
                )
                .max_width(r.w)
                .align(Align::Center),
            );
        }
        if let Some(above) = &paint.above
            && crate::geometry::level_scale(self.semantic.level) * crate::time::HOUR_MS >= 36.0
        {
            dl.text(
                TextRun::new(
                    above.to_string(),
                    Point::new(x - 30.0, r.y - 13.0 * k),
                    9.5 * k,
                    p.muted,
                )
                .max_width(60.0)
                .align(Align::Center),
            );
        }
    }

    fn emit_span(
        &self,
        dl: &mut DisplayList,
        it: &Item,
        m: &Mark,
        span: &crate::mark::Span,
        p: &Palette,
        text: &mut TextSystem,
    ) {
        let k = self.layout.k;
        let paint = &m.paint;
        let thick = it.hh * 2.0;
        let x_start = self.x(m.start);
        let run_x = span.run.map(|run| self.x(run));
        let lead_end = run_x.unwrap_or_else(|| self.x(self.now));
        // The wait: a thin line, or a faint band once the bar is thick enough.
        if lead_end > x_start {
            if thick >= LABEL_MIN_H {
                let band = Rect::new(x_start, it.y - it.hh, lead_end - x_start, thick);
                dl.rect(RoundedRect::new(band, 2.0 * k, span.lead.with_alpha(0.16)));
                if let Some(wait) = &span.wait {
                    self.fit_label(dl, text, std::slice::from_ref(wait), band, p.muted, thick);
                }
            } else {
                dl.rect(RoundedRect::new(
                    Rect::new(x_start, it.y - 0.75, lead_end - x_start, 1.5),
                    0.0,
                    span.lead,
                ));
            }
        }
        let Some(x0) = run_x else {
            return;
        };
        let end = span.end.unwrap_or(self.now);
        let x1 = self.x(end).max(x0 + paint.w * k);
        let bar = Rect::new(x0, it.y - it.hh, x1 - x0, thick);
        let radius = (paint.r * k).min(it.hh);
        let mut rr = RoundedRect::new(bar, radius, paint.fill.unwrap_or(Rgba::TRANSPARENT));
        if let Some(inset) = paint.inset {
            rr = rr.border(inset.width * k, inset.color);
        }
        dl.rect(rr);
        if let (Some(core), Some(_)) = (span.core, paint.fill) {
            let ch = thick * core.clamp(0.0, 1.0);
            dl.rect(RoundedRect::new(
                Rect::new(x0, bar.max_y() - ch, x1 - x0, ch),
                radius,
                Rgba::BLACK.with_alpha(0.18),
            ));
        }
        if thick >= LABEL_MIN_H {
            self.fit_label(dl, text, &span.text, bar, span.ink, thick);
        }
        if let Some(live) = paint.live {
            let d = (thick + 4.0 * k).min(12.0 * k);
            dl.rect(
                RoundedRect::new(
                    Rect::new(x1 - d / 2.0, it.y - d / 2.0, d, d),
                    d / 2.0,
                    Rgba::TRANSPARENT,
                )
                .border(2.0 * k, live)
                .pinned(),
            );
        }
    }

    /// The longest of `labels` (shortest first) that fits inside `r`, in `ink`.
    fn fit_label(
        &self,
        dl: &mut DisplayList,
        text: &mut TextSystem,
        labels: &[Arc<str>],
        r: Rect,
        ink: Rgba,
        thick: f32,
    ) {
        let size = (thick - 6.0).clamp(8.0, 11.0);
        let room = r.w - 8.0;
        let spec = FontSpec::ui(size);
        let fit = labels
            .iter()
            .rev()
            .find(|l| text.shape(l, spec).width <= room);
        if let Some(label) = fit {
            dl.text(TextRun::new(
                label.to_string(),
                Point::new(r.x + 4.0, r.y + (r.h - size * 1.25) / 2.0),
                size,
                ink,
            ));
        }
    }

    fn emit_selection(&self, dl: &mut DisplayList, it: &Item, p: &Palette) {
        let pad = 3.0;
        match it.what {
            ItemRef::Mark(mi) if self.marks[mi].paint.span.is_some() => {
                let m = &self.marks[mi];
                let x0 = self.x(m.start);
                let x1 = self.x(it.t1.unwrap_or(self.now)).max(x0 + it.hw * 2.0);
                let r = Rect::new(
                    x0 - pad,
                    it.y - it.hh - pad,
                    x1 - x0 + 2.0 * pad,
                    it.hh * 2.0 + 2.0 * pad,
                );
                dl.rect(RoundedRect::new(r, 4.0, Rgba::TRANSPARENT).border(1.5, p.accent));
            }
            _ => {
                let x = self.x(it.t);
                let r = Rect::new(
                    x - it.hw - pad,
                    it.y - it.hh - pad,
                    2.0 * (it.hw + pad),
                    2.0 * (it.hh + pad),
                );
                dl.rect(
                    RoundedRect::new(r, it.hh + pad, Rgba::TRANSPARENT)
                        .border(1.5, p.accent)
                        .pinned(),
                );
            }
        }
    }
}

/// A cluster pill's width for its count, base points.
fn pill_width(count: u64) -> f32 {
    let digits = count.to_string().len() as f32;
    (digits * 5.2 + 8.0).max(PILL_H)
}
