//! The estate's lenses: one event model, two timelines. Estate draws each box as a 92 pt lane of
//! Rollouts / Backups / Cleanups; Backups draws one row per backed-up surface. A backup is a bar
//! standing on its row, as tall as its size; a restore test, reconcile or gateway a mark whose
//! glyph says how it ended. Colour means status (D4): `ok` landed, `danger` failed or missed, a
//! rollback `warning`, a quiet cleanup the data tone. Timers are schedules whose repeats the
//! engine computes; rollback pins are bands across their box.

use super::{Lens, LensSpec, Palette};
use crate::density::FoldRules;
use crate::geometry::ZoomPolicy;
use crate::layout::{GroupSpec, RowSpec};
use crate::mark::{Band, Inset, Mark, Paint, Schedule, Shape};
use crate::time::{DAY_MS, HOUR_MS, Ms};
use canvas_draw::Rgba;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EventKind {
    Reconcile = 0,
    Gateway = 1,
    Eve = 2,
    Backup = 3,
    Restore = 4,
    Cleanup = 5,
    Cert = 6,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EventResult {
    Ok = 0,
    Fail = 1,
    Rollback = 2,
    Live = 3,
    Missed = 4,
    Scheduled = 5,
}

/// An estate row of a box's lane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Row {
    Rollouts,
    Backups,
    Cleanups,
}

impl Row {
    pub fn of(kind: EventKind) -> Row {
        match kind {
            EventKind::Reconcile | EventKind::Gateway | EventKind::Eve => Row::Rollouts,
            EventKind::Backup | EventKind::Restore => Row::Backups,
            EventKind::Cleanup | EventKind::Cert => Row::Cleanups,
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Row::Rollouts => "rollouts",
            Row::Backups => "backups",
            Row::Cleanups => "cleanups",
        }
    }
}

/// One event of Semafor's `/api/v1/estate/timeline`, times in ms.
#[derive(Debug, Clone, PartialEq)]
pub struct EstateEvent {
    pub id: Arc<str>,
    pub box_name: Arc<str>,
    pub kind: EventKind,
    pub result: EventResult,
    pub at: Ms,
    pub duration: Option<Ms>,
    pub size_bytes: Option<u64>,
    pub title: Arc<str>,
    /// The backed-up surface (a database, a volume), for the Backups lens's rows.
    pub surface: Option<Arc<str>>,
}

/// A systemd timer (`schedules`): its next run and period.
#[derive(Debug, Clone, PartialEq)]
pub struct EstateTimer {
    pub box_name: Arc<str>,
    pub unit: Arc<str>,
    pub kind: EventKind,
    pub surface: Option<Arc<str>>,
    pub next: Ms,
    pub period: Ms,
}

/// A rollback pin: the box held at a commit from `from` (to `to`, or still in force).
#[derive(Debug, Clone, PartialEq)]
pub struct EstatePin {
    pub box_name: Arc<str>,
    pub from: Ms,
    pub to: Option<Ms>,
    pub label: Arc<str>,
}

/// Rollouts, backups and cleanups stay marks up to three days per screen.
pub const ZOOM: ZoomPolicy = ZoomPolicy {
    from_days: 3.0,
    full_days: 5.0,
    bucket: |days| if days <= 14.0 { 6.0 * HOUR_MS } else { DAY_MS },
};

/// The estate row key of a box's row (`box|rollouts`).
pub fn estate_row(box_name: &str, row: Row) -> Arc<str> {
    format!("{box_name}|{}", row.key()).into()
}

/// The backups row key of a box's surface (`box|surface`).
pub fn backup_row(box_name: &str, surface: &str) -> Arc<str> {
    format!("{box_name}|{surface}").into()
}

/// One box's 92 pt lane: Rollouts, Backups, Cleanups.
pub fn estate_group(box_name: &str, tint: Option<Rgba>) -> GroupSpec {
    let row = |r: Row, label: &str, y: f32| RowSpec {
        key: estate_row(box_name, r),
        label: label.into(),
        y,
        tint,
    };
    GroupSpec {
        key: box_name.into(),
        label: box_name.into(),
        h: 92.0,
        rows: vec![
            row(Row::Rollouts, "Rollouts", 27.0),
            row(Row::Backups, "Backups", 54.0),
            row(Row::Cleanups, "Cleanups", 78.0),
        ],
        stack: None,
    }
}

/// A backup bar's height for its size, base points: 6 at nothing, 24 at most.
pub fn backup_height(size_bytes: Option<u64>) -> f32 {
    let gb = size_bytes.unwrap_or(0) as f64 / 1e9;
    (6.0 + 3.4 * (1.0 + gb).log2()).clamp(6.0, 24.0) as f32
}

/// Where its outcome holds: its end (its start while it runs or is scheduled).
pub fn outcome(e: &EstateEvent) -> Ms {
    match (e.result, e.duration) {
        (EventResult::Live | EventResult::Scheduled, _) | (_, None) => e.at,
        (_, Some(d)) => e.at + d.ceil(),
    }
}

fn source_label(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Reconcile => "reconcile",
        EventKind::Gateway => "deploy-gateway",
        EventKind::Eve => "eve lane",
        EventKind::Backup => "backup",
        EventKind::Restore => "restore test",
        EventKind::Cleanup => "cleanup",
        EventKind::Cert => "certificate",
    }
}

/// How one event is drawn.
pub fn paint(e: &EstateEvent, p: &Palette) -> Paint {
    let size: f32 = match e.kind {
        EventKind::Reconcile | EventKind::Gateway => 14.0,
        EventKind::Eve => 12.0,
        EventKind::Backup => 6.0,
        EventKind::Restore => 10.0,
        EventKind::Cleanup | EventKind::Cert => 8.0,
    };
    let radius: f32 = match e.kind {
        EventKind::Reconcile | EventKind::Restore | EventKind::Cleanup => -1.0,
        EventKind::Gateway => 4.0,
        EventKind::Eve | EventKind::Cert => 2.0,
        EventKind::Backup => 3.0,
    };
    let h = if e.kind == EventKind::Backup {
        backup_height(e.size_bytes)
    } else {
        size
    };
    let mut paint = Paint {
        shape: if radius < 0.0 {
            Shape::Circle
        } else if e.kind == EventKind::Eve {
            Shape::Diamond
        } else {
            Shape::Rect
        },
        w: size,
        h,
        r: radius.max(0.0),
        dy: if e.kind == EventKind::Backup {
            10.0 - h / 2.0
        } else {
            0.0
        },
        fill: None,
        inset: None,
        ring: None,
        glyph: None,
        above: e
            .size_bytes
            .filter(|&s| e.kind == EventKind::Backup && s >= 5_000_000_000)
            .map(|s| format!("{:.1} GB", s as f64 / 1e9).into()),
        live: (e.result == EventResult::Live).then_some(p.ok),
        span: None,
    };
    let quiet =
        matches!(e.kind, EventKind::Cleanup | EventKind::Cert) && e.result == EventResult::Ok;
    match e.result {
        EventResult::Ok if e.kind == EventKind::Restore => {
            paint.inset = Some(Inset {
                color: p.ok,
                width: 2.0,
            });
        }
        EventResult::Scheduled => {
            paint.inset = Some(Inset {
                color: p.foreground.with_alpha(0.35),
                width: 1.5,
            });
        }
        EventResult::Missed => {
            paint.inset = Some(Inset {
                color: p.danger,
                width: 2.0,
            });
            paint.ring = Some(p.danger.with_alpha(0.7));
        }
        r => {
            paint.fill = Some(match r {
                _ if quiet => p.data.with_alpha(0.7),
                EventResult::Ok => p.ok,
                EventResult::Fail => p.danger,
                EventResult::Rollback => p.warning,
                _ => p.ok,
            });
        }
    }
    if matches!(e.kind, EventKind::Reconcile | EventKind::Gateway) {
        paint.glyph = match e.result {
            EventResult::Ok => Some(("✓".into(), Rgba::BLACK.with_alpha(0.7))),
            EventResult::Fail => Some(("✕".into(), Rgba::WHITE)),
            EventResult::Rollback => Some(("↺".into(), Rgba::WHITE)),
            _ => None,
        };
    }
    paint
}

/// What both lenses share; they differ in the row an event sits on and what ← / → visit.
fn event_mark(e: &EstateEvent, p: &Palette, row: Arc<str>, steppable: bool, snap: f32) -> Mark {
    Mark {
        id: e.id.clone(),
        row,
        start: e.at,
        outcome: outcome(e),
        end: Some(outcome(e)),
        scheduled: e.result == EventResult::Scheduled,
        live: e.result == EventResult::Live,
        stands_out: matches!(
            e.result,
            EventResult::Fail | EventResult::Missed | EventResult::Live | EventResult::Rollback
        ),
        steppable,
        snap_weight: snap,
        sort: if e.result == EventResult::Scheduled || Row::of(e.kind) == Row::Cleanups {
            e.title.clone()
        } else {
            source_label(e.kind).into()
        },
        schedule: None,
        paint: paint(e, p),
    }
}

fn spec(key: &'static str) -> LensSpec {
    LensSpec {
        key,
        zoom: ZOOM,
        fold: FoldRules {
            folds: true,
            reach: 3.0 * HOUR_MS,
        },
        tracks: false,
        future: 3.0 * DAY_MS,
    }
}

/// A timer as the engine's schedule, on `row`. A loaded next run's id is the schedule's repeat
/// 0 (`key@0`), so the fold absorbs it into a rail.
pub fn timer_schedule(t: &EstateTimer, row: Arc<str>, p: &Palette) -> Schedule {
    let next = EstateEvent {
        id: "".into(),
        box_name: t.box_name.clone(),
        kind: t.kind,
        result: EventResult::Scheduled,
        at: t.next,
        duration: None,
        size_bytes: None,
        title: t.unit.clone(),
        surface: t.surface.clone(),
    };
    Schedule {
        key: format!("{}|{}", t.box_name, t.unit).into(),
        row,
        next: t.next,
        period: t.period,
        name: t.unit.trim_end_matches(".timer").into(),
        color: if matches!(t.kind, EventKind::Cleanup | EventKind::Cert) {
            p.data
        } else {
            p.ok
        },
        paint: paint(&next, p),
    }
}

/// A pin as a band across its box.
pub fn pin_band(pin: &EstatePin, p: &Palette) -> Band {
    Band {
        key: format!("{}|{}", pin.box_name, pin.from).into(),
        group: pin.box_name.clone(),
        from: pin.from,
        to: pin.to,
        label: format!("↺ {}", pin.label).into(),
        color: p.warning,
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct EstateLens;

impl Lens for EstateLens {
    type Item = EstateEvent;

    fn spec(&self) -> LensSpec {
        spec("estate")
    }

    fn mark(&self, e: &EstateEvent, p: &Palette) -> Mark {
        let rollout = Row::of(e.kind) == Row::Rollouts;
        let row = estate_row(&e.box_name, Row::of(e.kind));
        event_mark(e, p, row, rollout, if rollout { 1.0 } else { 1.6 })
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct BackupsLens;

impl Lens for BackupsLens {
    type Item = EstateEvent;

    fn spec(&self) -> LensSpec {
        spec("backups")
    }

    fn mark(&self, e: &EstateEvent, p: &Palette) -> Mark {
        let surface = e.surface.as_deref().unwrap_or(&e.title);
        let steppable = matches!(e.kind, EventKind::Backup | EventKind::Restore);
        event_mark(e, p, backup_row(&e.box_name, surface), steppable, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: EventKind, result: EventResult, size: Option<u64>) -> EstateEvent {
        EstateEvent {
            id: "e1".into(),
            box_name: "app-server".into(),
            kind,
            result,
            at: 1_000.0,
            duration: Some(500.0),
            size_bytes: size,
            title: "exampleapp-db".into(),
            surface: Some("postgres".into()),
        }
    }

    #[test]
    fn a_backup_stands_on_its_row_as_tall_as_its_size() {
        assert_eq!(backup_height(None), 6.0);
        assert_eq!(backup_height(Some(10_000_000_000_000)), 24.0);
        let p = Palette::default();
        let small = paint(
            &event(EventKind::Backup, EventResult::Ok, Some(1_000_000_000)),
            &p,
        );
        let large = paint(
            &event(EventKind::Backup, EventResult::Ok, Some(50_000_000_000)),
            &p,
        );
        assert!(large.h > small.h);
        assert_eq!(small.dy + small.h / 2.0, 10.0, "its foot on the row");
        assert_eq!(large.above.as_deref(), Some("50.0 GB"));
        assert_eq!(small.above, None);
    }

    #[test]
    fn colour_means_how_it_ended() {
        let p = Palette::default();
        let fill = |k, r| paint(&event(k, r, None), &p).fill;
        assert_eq!(fill(EventKind::Reconcile, EventResult::Ok), Some(p.ok));
        assert_eq!(fill(EventKind::Gateway, EventResult::Fail), Some(p.danger));
        assert_eq!(
            fill(EventKind::Reconcile, EventResult::Rollback),
            Some(p.warning)
        );
        assert_eq!(
            fill(EventKind::Cleanup, EventResult::Ok),
            Some(p.data.with_alpha(0.7))
        );
        let missed = paint(&event(EventKind::Backup, EventResult::Missed, None), &p);
        assert_eq!(missed.fill, None);
        assert!(missed.ring.is_some());
        let restore = paint(&event(EventKind::Restore, EventResult::Ok, None), &p);
        assert_eq!(restore.inset.map(|i| i.color), Some(p.ok));
    }

    #[test]
    fn an_estate_scene_draws_rails_pins_and_bins_crossfading_with_the_zoom() {
        use crate::mark::Bin;
        use crate::time::MIN_MS;
        use crate::{Timeline, scene::Hit};
        let now = 1_792_000_000_000.0;
        let p = Palette::default();
        let mut t = Timeline::new(EstateLens.spec(), p, now);
        t.set_groups(vec![estate_group("app-server", None)]);
        let mut rollout = event(EventKind::Reconcile, EventResult::Ok, None);
        rollout.at = now - 2.0 * HOUR_MS;
        t.set_marks(vec![EstateLens.mark(&rollout, &p)]);
        let health = EstateTimer {
            box_name: "app-server".into(),
            unit: "docker-health-metrics.timer".into(),
            kind: EventKind::Cleanup,
            surface: None,
            next: now + MIN_MS,
            period: MIN_MS,
        };
        t.set_schedules(vec![timer_schedule(
            &health,
            estate_row("app-server", Row::Cleanups),
            &p,
        )]);
        let pin = EstatePin {
            box_name: "app-server".into(),
            from: now - 5.0 * HOUR_MS,
            to: None,
            label: "exampleapp @ 3f9a1c2".into(),
        };
        t.set_bands(vec![pin_band(&pin, &p)]);
        let bins = (0..48)
            .map(|h| Bin {
                row: estate_row("app-server", Row::Rollouts),
                from: now - f64::from(h) * 6.0 * HOUR_MS,
                width: 6.0 * HOUR_MS,
                count: 3,
                failures: 1,
                scheduled: false,
                color: p.ok,
                grow: 2.4,
            })
            .collect();
        t.set_bins(bins);
        t.resize(1168.0, 400.0);
        let mut text = canvas_text::TextSystem::new();

        // A day per screen: marks only, the timer a cadence rail, the pin a band.
        t.build(&mut text);
        let s = t.scene().expect("built");
        assert_eq!(s.aggregation, 0.0);
        assert!(s.bins.is_empty());
        assert_eq!(s.rails.len(), 1, "an every-minute timer is a rail");
        assert_eq!(s.bands.len(), 1, "the pin, still in force, reaches now");
        let band_y = s.layout.groups[0].top + 10.0;
        let band_x = crate::timeline::LABEL_W + t.view().x_of(now - 4.0 * HOUR_MS) as f32;
        assert!(matches!(
            t.hit(band_x, band_y - t.scroll()),
            Some(Hit::Band(_))
        ));

        // Four days per screen: marks and bins crossfade; ten: bins only.
        t.zoom_by(0.25, None);
        t.build(&mut text);
        let mix = t.scene().expect("built").aggregation;
        assert!(mix > 0.0 && mix < 1.0, "{mix}");
        assert!(!t.scene().expect("built").bins.is_empty());
        t.zoom_by(0.4, None);
        t.build(&mut text);
        let s = t.scene().expect("built");
        assert_eq!(s.aggregation, 1.0);
        assert!(s.marks.is_empty(), "bins only");
    }

    #[test]
    fn the_lenses_put_one_event_on_different_rows() {
        let p = Palette::default();
        let e = event(EventKind::Backup, EventResult::Ok, None);
        assert_eq!(&*EstateLens.mark(&e, &p).row, "app-server|backups");
        assert_eq!(&*BackupsLens.mark(&e, &p).row, "app-server|postgres");
        assert!(
            !EstateLens.mark(&e, &p).steppable,
            "Estate's ← / → visit rollouts"
        );
        assert!(BackupsLens.mark(&e, &p).steppable);
        assert_eq!(EstateLens.mark(&e, &p).outcome, 1_500.0);
        let fail = event(EventKind::Reconcile, EventResult::Fail, None);
        assert!(
            EstateLens.mark(&fail, &p).stands_out,
            "a failure never folds"
        );
    }
}
