//! The data-fed lens: a host builds a whole timeline from plain data at runtime ([`Plan`]):
//! lanes top to bottom, items on them (bars of coloured stretches, chips, diamonds), bands and
//! lines, and the range the view may show. Nothing is compiled in and nothing need live for
//! `'static`; the CI and Estate lenses keep their own types on the same engine.
//!
//! A lane is a group of one row that opens into a track per item running at once, at one
//! pitch at every zoom ([`Tracking::Fixed`]): a chip holds the room its text takes, and a chip
//! with no time yet is parked just after now on a track of its own. Colours arrive resolved
//! (`Rgba`): a browser host resolves its CSS colours before it hands a plan over, and hands it
//! again after a theme change.

use super::LensSpec;
use crate::density::FoldRules;
use crate::geometry::ZoomPolicy;
use crate::layout::{GroupSpec, ROW_PITCH, RowSpec};
use crate::mark::{Band, Cap, Line, Mark, Paint, Shape, Span, Stretch};
use crate::time::{DAY_MS, Ms};
use crate::timeline::Timeline;
use crate::tracks::Tracking;
use canvas_draw::Rgba;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// A lane's track pitch and its bars' thickness, base points: a bar label's room at any zoom.
pub const TRACK_PITCH: f32 = 24.0;
pub const BAR_H: f32 = 16.0;
/// A lane's room above its first and below its last track, base points.
const LANE_PAD: f32 = 3.0;
/// A chip's dot and a diamond, base points.
pub const CHIP_D: f32 = 8.0;
pub const DIAMOND_D: f32 = 12.0;
/// A bar's least drawn length, its corner radius, base points.
const BAR_MIN_W: f32 = 4.0;
const BAR_R: f32 = 3.0;

/// A plan never trades its items for density bins.
pub const ZOOM: ZoomPolicy = ZoomPolicy {
    from_days: f64::MAX,
    full_days: f64::MAX,
    bucket: |_| DAY_MS,
};

/// The lens's spec; `reach` is the longest an item spans (the fold reaches back that far).
pub fn spec(reach: Ms) -> LensSpec {
    LensSpec {
        key: "plan",
        zoom: ZOOM,
        fold: FoldRules {
            folds: false,
            reach,
        },
        tracks: Tracking::Fixed {
            pitch: TRACK_PITCH,
            bar: BAR_H,
        },
        future: 0.0,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    /// The time the view may show, `[from, to]`.
    pub range: (Ms, Ms),
    /// Top to bottom.
    pub lanes: Vec<Lane>,
    pub items: Vec<Item>,
    pub bands: Vec<PlanBand>,
    /// Vertical lines across every lane; now is the engine's own.
    pub lines: Vec<Line>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Lane {
    pub id: Arc<str>,
    /// Its accessible name (and its head in the label column, when one is drawn).
    pub label: Arc<str>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Item {
    pub id: Arc<str>,
    pub lane: Arc<str>,
    /// Its accessible name.
    pub label: Arc<str>,
    pub kind: ItemKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ItemKind {
    Bar(Bar),
    Chip(Chip),
    Diamond { at: Ms, color: Rgba },
}

/// A span of consecutive coloured stretches with an optional end cap.
#[derive(Debug, Clone, PartialEq)]
pub struct Bar {
    /// In time order, never overlapping; a gap between two is drawn as a thin lead line.
    pub stretches: Vec<Stretch>,
    /// The last stretch runs to now and moves with it.
    pub open: bool,
    /// A solid cap at the bar's end (done).
    pub cap: Option<Cap>,
    /// Written inside the bar where it fits, else left out.
    pub text: Option<Arc<str>>,
}

/// A point with its text beside it; with no `at` it is parked just after now.
#[derive(Debug, Clone, PartialEq)]
pub struct Chip {
    pub at: Option<Ms>,
    pub color: Rgba,
    pub text: Arc<str>,
}

/// A background range: across one lane, or every lane when `lane` is `None`.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanBand {
    pub id: Arc<str>,
    pub from: Ms,
    pub to: Ms,
    pub lane: Option<Arc<str>>,
    pub color: Rgba,
    pub label: Option<Arc<str>>,
}

/// Why a plan was refused: what is wrong, where, and what a valid plan says instead.
#[derive(Debug, Clone, PartialEq)]
pub enum PlanError {
    /// The range is not two finite instants with `from` before `to`.
    Range {
        from: Ms,
        to: Ms,
    },
    DuplicateLane {
        lane: Arc<str>,
    },
    DuplicateItem {
        item: Arc<str>,
    },
    /// An item or a band names a lane the plan does not list.
    UnknownLane {
        of: Arc<str>,
        lane: Arc<str>,
    },
    /// An item's, a band's or a line's instant is not finite.
    Time {
        of: Arc<str>,
    },
    EmptyBar {
        item: Arc<str>,
    },
    /// Stretch `index` of a bar ends before it starts, or starts before the one before it ends.
    StretchOrder {
        item: Arc<str>,
        index: usize,
    },
    /// A band ends before it starts.
    BandRange {
        band: Arc<str>,
    },
}

impl std::fmt::Display for PlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlanError::Range { from, to } => write!(
                f,
                "the range [{from}, {to}] is not two finite instants with from before to; pass epoch milliseconds, from < to"
            ),
            PlanError::DuplicateLane { lane } => {
                write!(
                    f,
                    "lane {lane:?} is listed twice; give every lane its own id"
                )
            }
            PlanError::DuplicateItem { item } => {
                write!(
                    f,
                    "item id {item:?} is used twice; give every item its own id"
                )
            }
            PlanError::UnknownLane { of, lane } => write!(
                f,
                "{of:?} names lane {lane:?}, which the plan does not list; add the lane or use a listed one"
            ),
            PlanError::Time { of } => write!(
                f,
                "{of:?} has an instant that is not finite; pass epoch milliseconds"
            ),
            PlanError::EmptyBar { item } => write!(
                f,
                "bar {item:?} has no stretches; give it at least one, or send a chip"
            ),
            PlanError::StretchOrder { item, index } => write!(
                f,
                "bar {item:?}'s stretch {index} ends before it starts or overlaps the one before; list stretches in time order, never overlapping"
            ),
            PlanError::BandRange { band } => {
                write!(f, "band {band:?} ends before it starts; pass from <= to")
            }
        }
    }
}

impl std::error::Error for PlanError {}

/// A lane as the engine lays it out: a group of one row that opens into tracks.
pub fn lane_group(lane: &Lane) -> GroupSpec {
    GroupSpec {
        key: lane.id.clone(),
        label: lane.label.clone(),
        h: 2.0 * LANE_PAD + ROW_PITCH,
        rows: vec![RowSpec {
            key: lane.id.clone(),
            label: "".into(),
            y: LANE_PAD + ROW_PITCH / 2.0,
            tint: None,
        }],
        stack: Some((LANE_PAD, LANE_PAD)),
    }
}

impl Plan {
    /// Every refusal [`Plan::apply`] would make, first one first.
    pub fn validate(&self) -> Result<(), PlanError> {
        let (from, to) = self.range;
        if !(from.is_finite() && to.is_finite() && from < to) {
            return Err(PlanError::Range { from, to });
        }
        let mut lanes = HashSet::new();
        for l in &self.lanes {
            if !lanes.insert(&*l.id) {
                return Err(PlanError::DuplicateLane { lane: l.id.clone() });
            }
        }
        let lane_known = |of: &Arc<str>, lane: &Arc<str>| {
            if lanes.contains(&**lane) {
                Ok(())
            } else {
                Err(PlanError::UnknownLane {
                    of: of.clone(),
                    lane: lane.clone(),
                })
            }
        };
        let finite = |of: &Arc<str>, t: Ms| {
            if t.is_finite() {
                Ok(())
            } else {
                Err(PlanError::Time { of: of.clone() })
            }
        };
        let mut items = HashSet::new();
        for it in &self.items {
            if !items.insert(&*it.id) {
                return Err(PlanError::DuplicateItem {
                    item: it.id.clone(),
                });
            }
            lane_known(&it.id, &it.lane)?;
            match &it.kind {
                ItemKind::Bar(b) => {
                    if b.stretches.is_empty() {
                        return Err(PlanError::EmptyBar {
                            item: it.id.clone(),
                        });
                    }
                    let mut end = f64::NEG_INFINITY;
                    for (index, s) in b.stretches.iter().enumerate() {
                        finite(&it.id, s.from)?;
                        finite(&it.id, s.to)?;
                        // An open bar's last stretch runs to now: its own end is not read.
                        let last_open = b.open && index + 1 == b.stretches.len();
                        if s.from < end || (!last_open && s.to < s.from) {
                            return Err(PlanError::StretchOrder {
                                item: it.id.clone(),
                                index,
                            });
                        }
                        end = s.to;
                    }
                    if let Some(c) = b.cap {
                        finite(&it.id, c.at)?;
                    }
                }
                ItemKind::Chip(c) => {
                    if let Some(at) = c.at {
                        finite(&it.id, at)?;
                    }
                }
                ItemKind::Diamond { at, .. } => finite(&it.id, *at)?,
            }
        }
        for b in &self.bands {
            finite(&b.id, b.from)?;
            finite(&b.id, b.to)?;
            if b.to < b.from {
                return Err(PlanError::BandRange { band: b.id.clone() });
            }
            if let Some(lane) = &b.lane {
                lane_known(&b.id, lane)?;
            }
        }
        for l in &self.lines {
            finite(&l.key, l.at)?;
        }
        Ok(())
    }

    /// Hand the whole plan to `t`: its lanes, marks, parked chips, bands, lines, names, range
    /// and the lens's spec. A refused plan changes nothing. The view, the selection (by id)
    /// and the scroll stay.
    pub fn apply(&self, t: &mut Timeline) -> Result<(), PlanError> {
        self.validate()?;
        t.set_range(Some(self.range))?;
        let p = t.palette;
        let mut marks = Vec::with_capacity(self.items.len());
        let mut parked = Vec::new();
        let mut names = HashMap::with_capacity(self.items.len());
        let mut reach: Ms = 0.0;
        for it in &self.items {
            names.insert(it.id.clone(), it.label.clone());
            let mark = |start: Ms, end: Option<Ms>, live: bool, paint: Paint| Mark {
                id: it.id.clone(),
                row: it.lane.clone(),
                start,
                outcome: end.unwrap_or(start),
                end,
                scheduled: false,
                live,
                stands_out: false,
                steppable: !live,
                snap_weight: 1.0,
                sort: it.lane.clone(),
                schedule: None,
                paint,
            };
            match &it.kind {
                ItemKind::Bar(b) => {
                    let start = b.stretches[0].from;
                    let last = b.stretches[b.stretches.len() - 1].to;
                    let end = (!b.open).then(|| b.cap.map_or(last, |c| last.max(c.at)));
                    reach = reach.max(end.unwrap_or(self.range.1).max(start) - start);
                    let paint = Paint {
                        shape: Shape::Rect,
                        w: BAR_MIN_W,
                        h: BAR_H,
                        r: BAR_R,
                        dy: 0.0,
                        fill: Some(b.stretches[0].color),
                        inset: None,
                        ring: None,
                        glyph: None,
                        above: None,
                        beside: None,
                        live: None,
                        span: Some(Span {
                            run: Some(start),
                            end,
                            lead: p.muted,
                            wait: None,
                            core: None,
                            text: b.text.iter().cloned().collect(),
                            ink: p.foreground,
                            stretches: b.stretches.clone(),
                            cap: b.cap,
                        }),
                    };
                    marks.push(mark(start, end, b.open, paint));
                }
                ItemKind::Chip(c) => {
                    let mut paint = Paint::rect(CHIP_D, c.color);
                    paint.shape = Shape::Circle;
                    paint.beside = Some(c.text.clone());
                    match c.at {
                        Some(at) => marks.push(mark(at, Some(at), false, paint)),
                        None => {
                            let mut m = mark(0.0, Some(0.0), false, paint);
                            m.steppable = false;
                            parked.push(m);
                        }
                    }
                }
                ItemKind::Diamond { at, color } => {
                    let mut paint = Paint::rect(DIAMOND_D, *color);
                    paint.shape = Shape::Diamond;
                    marks.push(mark(*at, Some(*at), false, paint));
                }
            }
        }
        t.spec = spec(reach);
        t.set_groups(self.lanes.iter().map(lane_group).collect());
        t.set_marks(marks);
        t.set_parked(parked);
        t.set_names(names);
        t.set_bins(Vec::new());
        t.set_schedules(Vec::new());
        t.set_bands(
            self.bands
                .iter()
                .map(|b| Band {
                    key: b.id.clone(),
                    group: b.lane.clone(),
                    from: b.from,
                    to: Some(b.to),
                    label: b.label.clone().unwrap_or_else(|| "".into()),
                    color: b.color,
                })
                .collect(),
        );
        t.set_lines(self.lines.clone());
        Ok(())
    }
}
