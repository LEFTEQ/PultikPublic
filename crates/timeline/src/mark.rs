//! What the engine draws, normalized by a lens: a mark (an item's time, row, flags and paint),
//! a density bin, a band across a group, a schedule whose repeats are computed, never loaded.
//! The engine never looks inside an item; a lens turns its items into these
//! ([`crate::lens`]).

use crate::time::Ms;
use canvas_draw::Rgba;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    Circle,
    Rect,
    Diamond,
}

/// A border inside the shape (a scheduled run, a cancelled job).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Inset {
    pub color: Rgba,
    pub width: f32,
}

/// An item with a duration: a thin lead line from its start to `run` (its wait), then the bar
/// from `run` to `end`.
#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    /// When it began running; `None`: still waiting, the lead reaches now.
    pub run: Option<Ms>,
    /// When it finished; `None`: running, the bar reaches now.
    pub end: Option<Ms>,
    pub lead: Rgba,
    /// The wait's length ("waited 41 s"), written in its band when there is room.
    pub wait: Option<Arc<str>>,
    /// The bar's measure filled to this fraction (a job's peak over its reservation).
    pub core: Option<f32>,
    /// Labels shortest first: the longest that fits is written inside the bar.
    pub text: Vec<Arc<str>>,
    pub ink: Rgba,
}

/// How one mark is drawn. Lengths are base points (times the size's `k`).
#[derive(Debug, Clone, PartialEq)]
pub struct Paint {
    pub shape: Shape,
    pub w: f32,
    pub h: f32,
    pub r: f32,
    /// The centre's offset from the row centre (a backup bar stands on its row).
    pub dy: f32,
    /// `None`: hollow.
    pub fill: Option<Rgba>,
    pub inset: Option<Inset>,
    /// A dashed ring outside the shape (a missed run).
    pub ring: Option<Rgba>,
    /// A glyph in the shape (✓ ✕ ↺).
    pub glyph: Option<(Arc<str>, Rgba)>,
    /// Text over the mark once the zoom has room (a large backup's size).
    pub above: Option<Arc<str>>,
    /// Running: its head breathes in this colour.
    pub live: Option<Rgba>,
    pub span: Option<Span>,
}

impl Paint {
    /// A filled rounded square `w` points wide.
    pub fn rect(w: f32, fill: Rgba) -> Paint {
        Paint {
            shape: Shape::Rect,
            w,
            h: w,
            r: w * 0.28,
            dy: 0.0,
            fill: Some(fill),
            inset: None,
            ring: None,
            glyph: None,
            above: None,
            live: None,
            span: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Mark {
    /// Unique across the timeline; stepping orders equal starts by it.
    pub id: Arc<str>,
    /// Its row's key (a lane, a box's "Backups"); a row the layout lacks is not drawn.
    pub row: Arc<str>,
    pub start: Ms,
    /// Where its outcome holds (a job's end, a rollout's end): what ← / → and replay land on.
    pub outcome: Ms,
    /// Frees its track (`None`: still running). A point's end is its start.
    pub end: Option<Ms>,
    pub scheduled: bool,
    /// Running or waiting: drawn to now.
    pub live: bool,
    /// Needs a look or runs: never folded.
    pub stands_out: bool,
    /// ← / → land on it.
    pub steppable: bool,
    /// A released playhead snaps to the nearest outcome, its distance times this.
    pub snap_weight: f32,
    /// What a folded cluster counts it by ("backup", a repository).
    pub sort: Arc<str>,
    /// The schedule a scheduled run is a repeat of.
    pub schedule: Option<Arc<str>>,
    pub paint: Paint,
}

/// How many items one row had in `[from, from + width)`, and how many failed.
#[derive(Debug, Clone, PartialEq)]
pub struct Bin {
    pub row: Arc<str>,
    pub from: Ms,
    pub width: Ms,
    pub count: u32,
    pub failures: u32,
    pub scheduled: bool,
    pub color: Rgba,
    /// Bar growth per item, base points (3 at least, 20 at most).
    pub grow: f32,
}

/// A band across a whole group over a time range (a rollback pin).
#[derive(Debug, Clone, PartialEq)]
pub struct Band {
    pub key: Arc<str>,
    pub group: Arc<str>,
    pub from: Ms,
    /// `None`: still in force, it reaches now.
    pub to: Option<Ms>,
    pub label: Arc<str>,
    pub color: Rgba,
}

/// A timer whose repeats the engine computes instead of loading.
#[derive(Debug, Clone, PartialEq)]
pub struct Schedule {
    pub key: Arc<str>,
    pub row: Arc<str>,
    /// The next run.
    pub next: Ms,
    pub period: Ms,
    /// Its name on a cadence rail.
    pub name: Arc<str>,
    pub color: Rgba,
    /// What one repeat looks like.
    pub paint: Paint,
}

impl Schedule {
    /// Repeat `k` (0 is the next run).
    pub fn at(&self, k: i64) -> Ms {
        self.next + k as f64 * self.period
    }

    /// Repeat `k` as a mark.
    pub fn repeat(&self, k: i64) -> Mark {
        let t = self.at(k);
        Mark {
            id: format!("{}@{k}", self.key).into(),
            row: self.row.clone(),
            start: t,
            outcome: t,
            end: Some(t),
            scheduled: true,
            live: false,
            stands_out: false,
            steppable: true,
            snap_weight: 1.0,
            sort: self.name.clone(),
            schedule: Some(self.key.clone()),
            paint: self.paint.clone(),
        }
    }

    /// The repeat number a mark id names, if it is one of this schedule's.
    pub fn repeat_k(&self, id: &str) -> Option<i64> {
        id.strip_prefix(&*self.key)?.strip_prefix('@')?.parse().ok()
    }

    pub fn is_periodic(&self) -> bool {
        self.period > 0.0 && self.next.is_finite()
    }
}
