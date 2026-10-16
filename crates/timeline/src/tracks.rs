//! Tracks: a row whose lens has them opens into one track per item running at the same time,
//! as many as its busiest moment in the rendered window, and the zoom sets how thick a track
//! is (slivers far out, bars tall enough for a label close in). Tracks change only with the
//! rendered window or the zoom level, never per frame.

use crate::geometry::level_scale;
use crate::layout::ROW_PITCH;
use crate::mark::Mark;
use crate::time::{MIN_MS, Ms};
use std::collections::HashMap;
use std::sync::Arc;

const PITCH_FAR: f32 = 5.0;
const PITCH_NEAR: f32 = 22.0;
const BAR_FAR: f32 = 9.0;
const BAR_NEAR: f32 = 19.0;
/// Minutes per 1000 points far out and close in.
const FAR_MIN: f64 = 360.0;
const NEAR_MIN: f64 = 30.0;
/// A tracked row's padding above its first and below its last track.
pub const TRACK_PAD: f32 = 2.0;

/// How far in the zoom is between far (0) and near (1), log-linear in minutes per 1000 points.
pub fn closeness(level: i32) -> f32 {
    let per_1000 = 1000.0 / level_scale(level) / MIN_MS;
    let t = (FAR_MIN.ln() - per_1000.ln()) / (FAR_MIN.ln() - NEAR_MIN.ln());
    t.clamp(0.0, 1.0) as f32
}

/// One track's pitch and its bar's greatest thickness at a level, base points.
pub fn track_metrics(level: i32) -> (f32, f32) {
    let t = closeness(level);
    (
        PITCH_FAR + t * (PITCH_NEAR - PITCH_FAR),
        BAR_FAR + t * (BAR_NEAR - BAR_FAR),
    )
}

/// A tracked row's height for `n` tracks at a level, base points: never under a plain row's.
pub fn tracked_row_height(n: usize, level: i32) -> f32 {
    ROW_PITCH.max(n as f32 * track_metrics(level).0 + 2.0 * TRACK_PAD)
}

/// Within a tracked row of `n` tracks and `h` base points: each track's pitch and its bar's
/// thickness. The gap between neighbours grows with the pitch.
pub fn track_geometry(n: usize, h: f32, level: i32) -> (f32, f32) {
    let (pitch, bar) = track_metrics(level);
    let p = (h - 2.0 * TRACK_PAD) / n.max(1) as f32;
    (p, bar.min(p - (pitch * 0.15).max(1.0)).max(1.5))
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Tracks {
    /// Each mark's track (by mark index), 0 at the top of its row.
    pub of: HashMap<usize, usize>,
    /// Each row's track count; a row with no mark in the window is absent (one track).
    pub rows: HashMap<Arc<str>, usize>,
}

/// Interval partitioning per row over the marks overlapping `[from, to]`: sorted by start, each
/// takes the lowest track free by its start, so a row needs exactly as many tracks as its
/// most marks at once.
pub fn assign(marks: &[Mark], from: Ms, to: Ms, now: Ms) -> Tracks {
    let mut by_row: HashMap<Arc<str>, Vec<usize>> = HashMap::new();
    for (i, m) in marks.iter().enumerate() {
        let end = m.end.unwrap_or(now);
        if end < from || m.start > to {
            continue;
        }
        by_row.entry(m.row.clone()).or_default().push(i);
    }
    let mut out = Tracks::default();
    for (row, mut list) in by_row {
        list.sort_by(|&a, &b| marks[a].start.total_cmp(&marks[b].start));
        let mut free: Vec<Ms> = Vec::new();
        for i in list {
            let s = marks[i].start;
            let t = match free.iter().position(|&until| until <= s) {
                Some(t) => t,
                None => {
                    free.push(0.0);
                    free.len() - 1
                }
            };
            free[t] = marks[i].end.unwrap_or(f64::INFINITY);
            out.of.insert(i, t);
        }
        out.rows.insert(row, free.len());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mark::Paint;
    use canvas_draw::Rgba;

    fn job(row: &str, start: Ms, end: Option<Ms>) -> Mark {
        Mark {
            id: format!("{row}{start}").into(),
            row: row.into(),
            start,
            outcome: end.unwrap_or(start),
            end,
            scheduled: false,
            live: end.is_none(),
            stands_out: false,
            steppable: true,
            snap_weight: 1.0,
            sort: "x".into(),
            schedule: None,
            paint: Paint::rect(9.0, Rgba::WHITE),
        }
    }

    #[test]
    fn a_row_needs_as_many_tracks_as_its_most_jobs_at_once() {
        // a: 0–10, b: 5–15, c: 10–20 (a's track is free again at 10), d: 12–running.
        let marks = vec![
            job("lane", 0.0, Some(10.0)),
            job("lane", 5.0, Some(15.0)),
            job("lane", 10.0, Some(20.0)),
            job("lane", 12.0, None),
            job("other", 0.0, Some(1.0)),
        ];
        let t = assign(&marks, 0.0, 30.0, 30.0);
        assert_eq!(t.rows["lane"], 3, "at 12: b, c and d run");
        assert_eq!(t.of[&0], 0);
        assert_eq!(t.of[&1], 1);
        assert_eq!(t.of[&2], 0, "c reuses a's track");
        assert_eq!(t.of[&3], 2);
        assert_eq!(t.rows["other"], 1);
    }

    #[test]
    fn tracks_thicken_as_the_zoom_closes_in() {
        let far = crate::geometry::level_of(1000.0 / (24.0 * 60.0 * MIN_MS));
        let near = crate::geometry::level_of(1000.0 / (20.0 * MIN_MS));
        assert_eq!(closeness(far), 0.0);
        assert_eq!(closeness(near), 1.0);
        assert!(tracked_row_height(4, near) > tracked_row_height(4, far));
        assert_eq!(tracked_row_height(1, far), ROW_PITCH);
    }
}
