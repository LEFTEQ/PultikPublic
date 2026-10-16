//! The time ↔ point mapping, the zoom limits, the zoom levels (√2 apart: the only zoom changes
//! that re-fold and re-emit) and the policy that trades marks for density bins.

use crate::time::{DAY_MS, MIN_MS, Ms};

/// The axis strip above the lanes, points.
pub const AXIS_PT: f32 = 30.0;
/// Zoom limits: 15 min to 90 d per screen width.
pub const MIN_SPAN_MS: Ms = 15.0 * MIN_MS;
pub const MAX_SPAN_MS: Ms = 90.0 * DAY_MS;

/// When a lens trades its marks for density bins and how wide the bins are: marks cross-fade
/// into bins between `from_days` and `full_days` per screen.
#[derive(Debug, Clone, Copy)]
pub struct ZoomPolicy {
    pub from_days: f64,
    pub full_days: f64,
    /// The bin width, ms, at `days` per screen (past `from_days`).
    pub bucket: fn(f64) -> Ms,
}

/// What the lanes show: `t0` at their left edge, `scale` points per ms, `width` points wide.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct View {
    pub t0: Ms,
    pub scale: f64,
    pub width: f64,
}

impl View {
    pub fn x_of(&self, t: Ms) -> f64 {
        (t - self.t0) * self.scale
    }
    pub fn t_of(&self, x: f64) -> Ms {
        self.t0 + x / self.scale
    }
    pub fn span(&self) -> Ms {
        self.width / self.scale
    }
    pub fn days(&self) -> f64 {
        self.span() / DAY_MS
    }
}

/// 0 = individual marks, 1 = only density bins.
pub fn aggregation(v: &View, z: &ZoomPolicy) -> f64 {
    ((v.days() - z.from_days) / (z.full_days - z.from_days)).clamp(0.0, 1.0)
}

/// The bin width the server is asked for at this zoom; `None` while marks are enough.
pub fn bucket_for(v: &View, z: &ZoomPolicy) -> Option<Ms> {
    let days = v.days();
    (days > z.from_days).then(|| (z.bucket)(days))
}

/// Zoom limits for lanes `width` points wide, as points per ms.
pub fn scale_limits(width: f64) -> (f64, f64) {
    (width / MAX_SPAN_MS, width / MIN_SPAN_MS)
}

const LEVEL_BASE: f64 = std::f64::consts::SQRT_2;

/// The zoom level of `scale`: levels are √2 apart, and a level's own scale is in it.
pub fn level_of(scale: f64) -> i32 {
    (scale.ln() / LEVEL_BASE.ln() + 1e-9).floor() as i32
}

/// A level's own scale (its lower bound): what folds, ticks and emission use across the level,
/// so a zoom inside one level is a camera move.
pub fn level_scale(level: i32) -> f64 {
    LEVEL_BASE.powi(level)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Marks,
    Mix,
    Bins,
}

pub fn phase_of(v: &View, z: &ZoomPolicy) -> Phase {
    let a = aggregation(v, z);
    if a <= 0.0 {
        Phase::Marks
    } else if a >= 1.0 {
        Phase::Bins
    } else {
        Phase::Mix
    }
}

/// Everything an emission depends on that a gesture can change: the rendered window (the
/// visible span plus one span either side), the zoom level, the bin width and the phase.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Semantic {
    pub from: Ms,
    pub to: Ms,
    pub level: i32,
    pub bucket: Option<Ms>,
    pub phase: Phase,
}

impl Semantic {
    pub fn of(v: &View, z: &ZoomPolicy) -> Semantic {
        let span = v.span();
        Semantic {
            from: v.t0 - span,
            to: v.t0 + 2.0 * span,
            level: level_of(v.scale),
            bucket: bucket_for(v, z),
            phase: phase_of(v, z),
        }
    }

    /// `v` left this semantic: the visible span is outside the rendered window, or the level,
    /// the bin width or the phase changed. Anything else is a camera move.
    pub fn left_by(&self, v: &View, z: &ZoomPolicy) -> bool {
        v.t0 < self.from
            || v.t0 + v.span() > self.to
            || level_of(v.scale) != self.level
            || bucket_for(v, z) != self.bucket
            || phase_of(v, z) != self.phase
    }

    /// The level's scale, points per ms: what this semantic's world x is laid out in.
    pub fn scale(&self) -> f64 {
        level_scale(self.level)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::HOUR_MS;

    const Z: ZoomPolicy = ZoomPolicy {
        from_days: 1.5,
        full_days: 2.5,
        bucket: |d| if d <= 7.0 { HOUR_MS } else { DAY_MS },
    };

    #[test]
    fn levels_are_root_two_apart_and_a_pinch_inside_one_is_a_camera_move() {
        let v = View {
            t0: 0.0,
            scale: 1000.0 / DAY_MS,
            width: 1000.0,
        };
        let s = Semantic::of(&v, &Z);
        assert!((level_scale(s.level + 1) / level_scale(s.level) - 2f64.sqrt()).abs() < 1e-12);
        assert!(level_scale(s.level) <= v.scale && v.scale < level_scale(s.level + 1));
        // Zooming within the level and panning within the window keep the semantic.
        let inside = View {
            t0: v.t0 + 0.2 * v.span(),
            scale: level_scale(s.level) * 1.05,
            ..v
        };
        assert!(!s.left_by(&inside, &Z));
        let next = View {
            scale: level_scale(s.level + 1),
            ..v
        };
        assert!(s.left_by(&next, &Z), "a level change re-emits");
        let far = View {
            t0: v.t0 + 1.5 * v.span(),
            ..v
        };
        assert!(s.left_by(&far, &Z), "leaving the rendered window re-emits");
    }

    #[test]
    fn marks_cross_fade_into_bins() {
        let at = |days: f64| View {
            t0: 0.0,
            scale: 1000.0 / (days * DAY_MS),
            width: 1000.0,
        };
        assert_eq!(phase_of(&at(1.0), &Z), Phase::Marks);
        assert_eq!(bucket_for(&at(1.0), &Z), None);
        assert_eq!(phase_of(&at(2.0), &Z), Phase::Mix);
        assert_eq!(phase_of(&at(3.0), &Z), Phase::Bins);
        assert_eq!(bucket_for(&at(3.0), &Z), Some(HOUR_MS));
        assert_eq!(bucket_for(&at(30.0), &Z), Some(DAY_MS));
    }
}
