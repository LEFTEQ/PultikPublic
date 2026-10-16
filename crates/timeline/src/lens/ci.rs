//! CI's lens: every job a span on its lane: a thin line while it waited for admission (queued
//! to its start), then a bar while it ran. Colour means status (D4): a finished bar is the data
//! tone, a failed one `danger`, a running one carries the `ok` head and reaches now, a
//! cancelled one is an outline, a waiting one its line alone. Jobs never fold; past a day and a
//! half per screen per-lane bins take over. A lane opens into a track per job running at once.

use super::{Lens, LensSpec, Palette};
use crate::density::FoldRules;
use crate::geometry::ZoomPolicy;
use crate::mark::{Inset, Mark, Paint, Shape, Span};
use crate::time::{DAY_MS, HOUR_MS, Ms, SECOND_MS, duration};
use canvas_draw::Rgba;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CiResult {
    Succeeded = 0,
    Failed = 1,
    Cancelled = 2,
    Unknown = 3,
    Running = 4,
    Waiting = 5,
}

impl CiResult {
    pub fn open(self) -> bool {
        matches!(self, CiResult::Running | CiResult::Waiting)
    }

    pub fn word(self) -> &'static str {
        match self {
            CiResult::Succeeded => "succeeded",
            CiResult::Failed => "failed",
            CiResult::Cancelled => "cancelled",
            CiResult::Unknown => "unknown",
            CiResult::Running => "running",
            CiResult::Waiting => "waiting",
        }
    }
}

/// One job as Semafor lists it (`/api/v1/ci/timeline`'s `jobs`), times in ms.
#[derive(Debug, Clone, PartialEq)]
pub struct CiJob {
    pub id: Arc<str>,
    pub lane: Arc<str>,
    pub repo: Arc<str>,
    /// Its GitHub job name, else the controller's job id.
    pub name: Arc<str>,
    pub queued_at: Ms,
    pub started_at: Option<Ms>,
    pub completed_at: Option<Ms>,
    pub result: CiResult,
    pub peak_mib: Option<u32>,
    pub reserved_mib: Option<u32>,
}

/// CI aggregates sooner than the estate: a busy lane runs a couple of hundred jobs a day.
pub const ZOOM: ZoomPolicy = ZoomPolicy {
    from_days: 1.5,
    full_days: 2.5,
    bucket: |days| {
        if days <= 7.0 {
            HOUR_MS
        } else if days <= 30.0 {
            6.0 * HOUR_MS
        } else {
            DAY_MS
        }
    },
};

#[derive(Debug, Clone, Copy, Default)]
pub struct CiLens;

impl Lens for CiLens {
    type Item = CiJob;

    fn spec(&self) -> LensSpec {
        LensSpec {
            key: "ci",
            zoom: ZOOM,
            fold: FoldRules {
                folds: false,
                reach: 6.0 * DAY_MS,
            },
            tracks: true,
            future: 60.0 * SECOND_MS,
        }
    }

    fn mark(&self, j: &CiJob, p: &Palette) -> Mark {
        let ran = match (j.started_at, j.completed_at) {
            (Some(s), Some(e)) => Some(duration(e - s)),
            (Some(_), None) => Some("running".to_string()),
            _ => None,
        };
        let mem = j
            .peak_mib
            .zip(j.reserved_mib)
            .map(|(peak, reserved)| format!("{peak} / {reserved} MiB"));
        let mut text: Vec<Arc<str>> = vec![j.name.clone()];
        if let Some(ran) = &ran {
            text.push(format!("{} · {ran}", j.name).into());
            if let Some(mem) = &mem {
                text.push(format!("{} · {ran} · {mem}", j.name).into());
            }
        }
        let wait = j
            .started_at
            .filter(|s| s - j.queued_at >= SECOND_MS)
            .map(|s| format!("waited {}", duration(s - j.queued_at)).into());
        let mut paint = Paint {
            shape: Shape::Rect,
            w: 9.0,
            h: 9.0,
            r: 2.5,
            dy: 0.0,
            fill: Some(p.data),
            inset: None,
            ring: None,
            glyph: None,
            above: None,
            live: (j.result == CiResult::Running).then_some(p.ok),
            span: Some(Span {
                run: j.started_at,
                end: j.completed_at,
                lead: p.foreground.with_alpha(0.5),
                wait,
                core: j
                    .peak_mib
                    .zip(j.reserved_mib.filter(|&r| r > 0))
                    .map(|(peak, reserved)| peak as f32 / reserved as f32),
                text,
                ink: p.background,
            }),
        };
        match j.result {
            CiResult::Failed => {
                paint.fill = Some(p.danger);
                if let Some(s) = &mut paint.span {
                    s.ink = Rgba::WHITE;
                }
            }
            CiResult::Cancelled => {
                paint.fill = None;
                paint.inset = Some(Inset {
                    color: p.foreground.with_alpha(0.45),
                    width: 1.5,
                });
                if let Some(s) = &mut paint.span {
                    s.ink = p.foreground;
                }
            }
            CiResult::Unknown => paint.fill = Some(p.data.with_alpha(0.45)),
            CiResult::Waiting => paint.fill = None,
            CiResult::Succeeded | CiResult::Running => {}
        }
        let outcome = j.completed_at.or(j.started_at).unwrap_or(j.queued_at);
        Mark {
            id: j.id.clone(),
            row: j.lane.clone(),
            start: j.queued_at,
            outcome,
            end: j.completed_at,
            scheduled: false,
            live: j.result.open(),
            stands_out: j.result == CiResult::Failed || j.result.open(),
            steppable: !j.result.open(),
            snap_weight: 1.0,
            sort: j.repo.clone(),
            schedule: None,
            paint,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(result: CiResult) -> CiJob {
        CiJob {
            id: "j1".into(),
            lane: "exampleapp-l".into(),
            repo: "ExampleApp".into(),
            name: "build".into(),
            queued_at: 0.0,
            started_at: Some(41_000.0),
            completed_at: (!result.open()).then_some(293_000.0),
            result,
            peak_mib: Some(589),
            reserved_mib: Some(2048),
        }
    }

    #[test]
    fn colour_means_status() {
        let p = Palette::default();
        let ok = CiLens.mark(&job(CiResult::Succeeded), &p);
        assert_eq!(ok.paint.fill, Some(p.data));
        assert_eq!(ok.outcome, 293_000.0);
        let span = ok.paint.span.as_ref().expect("a job is a span");
        assert_eq!(span.wait.as_deref(), Some("waited 41 s"));
        assert_eq!(&*span.text[2], "build · 4 min 12 s · 589 / 2048 MiB");
        assert_eq!(
            CiLens.mark(&job(CiResult::Failed), &p).paint.fill,
            Some(p.danger)
        );
        let running = CiLens.mark(&job(CiResult::Running), &p);
        assert_eq!(running.paint.live, Some(p.ok));
        assert!(running.live && running.stands_out && !running.steppable);
        assert_eq!(CiLens.mark(&job(CiResult::Cancelled), &p).paint.fill, None);
    }
}
