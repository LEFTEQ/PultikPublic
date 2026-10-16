//! What one zoom level draws, as pure functions: the fold of the rendered window's marks too
//! close to tell apart into counted clusters, cadence rails for timers denser than a mark, and
//! the two stepping orders.
//!
//! A schedule's repeats are folded arithmetically, a run of them per cell; only a repeat that
//! ends up drawn on its own becomes a mark, so an every-minute timer costs what the screen
//! shows. Clusters sit on a grid anchored at a fixed origin, so a pan never reshuffles them.

use crate::geometry::level_scale;
use crate::mark::{Mark, Schedule};
use crate::time::{MIN_MS, Ms};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// Marks of one row inside one cell this wide (points at the level's scale) fold into a cluster.
pub const CELL_PT: f64 = 10.0;
/// A timer whose runs fall closer than this draws as a cadence rail.
pub const RAIL_PT: f64 = 20.0;

/// How a lens folds: never (CI jobs part by zooming, bins take over further out), and how far
/// back an item can start and still reach into the window.
#[derive(Debug, Clone, Copy)]
pub struct FoldRules {
    pub folds: bool,
    /// The longest an item spans from its start to its outcome.
    pub reach: Ms,
}

/// A run of one schedule's repeats folded into a cluster: repeats `k0..=k1`.
#[derive(Debug, Clone, PartialEq)]
pub struct Run {
    pub schedule: usize,
    pub k0: i64,
    pub k1: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Cluster {
    pub id: String,
    pub row: Arc<str>,
    /// The members' mean start: where it draws.
    pub at: Ms,
    pub from: Ms,
    pub to: Ms,
    pub count: u64,
    /// Indices of the loaded marks folded here, in time order.
    pub marks: Vec<usize>,
    pub runs: Vec<Run>,
    /// Every member is a scheduled run.
    pub scheduled: bool,
}

/// The timers of one row that run more than once per cell, drawn as one dashed line from the
/// earliest next run to the end of the scheduled future.
#[derive(Debug, Clone, PartialEq)]
pub struct Rail {
    pub row: Arc<str>,
    pub from: Ms,
    /// Schedule indices, soonest next run first.
    pub members: Vec<usize>,
}

/// A drawn mark: a loaded one, or a schedule's repeat made a mark because it stands alone.
#[derive(Debug, Clone, PartialEq)]
pub enum Drawn {
    Loaded(usize),
    Repeat(Box<Mark>),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Folded {
    pub marks: Vec<Drawn>,
    pub clusters: Vec<Cluster>,
    pub rails: Vec<Rail>,
    /// Schedule keys drawn as rails at this level.
    pub railed: HashSet<Arc<str>>,
}

/// Index of the first mark starting at or after `t` (marks sorted by start).
pub fn lower_bound(marks: &[Mark], t: Ms) -> usize {
    marks.partition_point(|m| m.start < t)
}

/// The fold's cells by (row, index on the grid anchored at `origin`), in the order first used.
struct Cells {
    cells: HashMap<(Arc<str>, i64), Cell>,
    order: Vec<(Arc<str>, i64)>,
    origin: Ms,
    cell_ms: Ms,
}

impl Cells {
    fn at(&mut self, row: &Arc<str>, t: Ms) -> &mut Cell {
        let key = (
            row.clone(),
            ((t - self.origin) / self.cell_ms).floor() as i64,
        );
        let order = &mut self.order;
        self.cells.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Cell {
                row: row.clone(),
                key,
                count: 0,
                sum: 0.0,
                from: f64::INFINITY,
                to: f64::NEG_INFINITY,
                marks: Vec::new(),
                runs: Vec::new(),
                scheduled: true,
            }
        })
    }
}

struct Cell {
    row: Arc<str>,
    key: (Arc<str>, i64),
    count: u64,
    /// Sum of member starts relative to the origin (keeps the mean exact).
    sum: f64,
    from: Ms,
    to: Ms,
    marks: Vec<usize>,
    runs: Vec<Run>,
    scheduled: bool,
}

/// Fold the marks of `[from, to)` at `level`: the loaded marks (sorted by start) and every
/// schedule's repeats up to `until`. Marks of one row inside one [`CELL_PT`] cell fold into a
/// cluster; a cell holding one mark draws it as it is. What stands out and the selected mark
/// never fold. A timer that runs more than once per cell joins its row's cadence rail instead.
#[allow(clippy::too_many_arguments)]
pub fn fold_window(
    rules: FoldRules,
    marks: &[Mark],
    schedules: &[Schedule],
    from: Ms,
    to: Ms,
    until: Ms,
    level: i32,
    origin: Ms,
    selected: Option<&str>,
) -> Folded {
    let cell_ms = CELL_PT / level_scale(level);
    let rail_ms = RAIL_PT / level_scale(level);
    let mut cells = Cells {
        cells: HashMap::new(),
        order: Vec::new(),
        origin,
        cell_ms,
    };
    let mut out = Folded::default();
    let end = to.min(until);
    let mut absorbed: HashSet<Arc<str>> = HashSet::new();
    let mut rails: Vec<Rail> = Vec::new();
    for (i, s) in schedules.iter().enumerate() {
        if !s.is_periodic() || s.period >= rail_ms || s.next >= end || until <= from {
            continue;
        }
        out.railed.insert(s.key.clone());
        let next = s.repeat(0);
        if selected != Some(&*next.id) {
            absorbed.insert(next.id.clone());
        }
        match rails.iter_mut().find(|r| r.row == s.row) {
            Some(r) => {
                r.from = r.from.min(s.next);
                r.members.push(i);
            }
            None => rails.push(Rail {
                row: s.row.clone(),
                from: s.next,
                members: vec![i],
            }),
        }
        if let Some(k) = selected.and_then(|id| s.repeat_k(id)) {
            let t = s.at(k);
            if t >= from && t < end {
                out.marks.push(Drawn::Repeat(Box::new(s.repeat(k))));
            }
        }
    }
    for r in &mut rails {
        r.members
            .sort_by(|&a, &b| schedules[a].next.total_cmp(&schedules[b].next));
    }
    out.rails = rails;
    // A lens whose items span reaches back for those started before the window and still in it.
    let lead = if rules.folds { 0.0 } else { rules.reach };
    for (i, m) in marks
        .iter()
        .enumerate()
        .skip(lower_bound(marks, from - lead))
    {
        let t = m.start;
        if t >= to {
            break;
        }
        if absorbed.contains(&m.id) || (t < from && m.outcome < from && !m.live) {
            continue;
        }
        let selected_here = selected == Some(&*m.id);
        if !rules.folds || selected_here || m.stands_out {
            out.marks.push(Drawn::Loaded(i));
            continue;
        }
        let c = cells.at(&m.row, t);
        c.marks.push(i);
        c.count += 1;
        c.sum += t - origin;
        c.from = c.from.min(t);
        c.to = c.to.max(t);
        c.scheduled &= m.scheduled;
    }
    for (si, s) in schedules.iter().enumerate() {
        if !s.is_periodic() || out.railed.contains(&s.key) {
            continue;
        }
        let sel = selected.and_then(|id| s.repeat_k(id));
        let add = |cells: &mut Cells, k0: i64, k1: i64| {
            if k1 < k0 {
                return;
            }
            let n = (k1 - k0 + 1) as f64;
            let t0 = s.at(k0);
            let c = cells.at(&s.row, t0);
            c.runs.push(Run {
                schedule: si,
                k0,
                k1,
            });
            c.count += (k1 - k0 + 1) as u64;
            // Σ (next + k·period − origin) over k0..=k1, arithmetically.
            c.sum += n * (s.next - origin) + s.period * (k0 + k1) as f64 * n / 2.0;
            c.from = c.from.min(t0);
            c.to = c.to.max(s.at(k1));
        };
        // One step per occupied cell: k jumps to the last repeat inside the cell.
        let mut k = 1.max(((from - s.next) / s.period).ceil() as i64);
        while s.at(k) < end {
            let t = s.at(k);
            let cell_end = origin + (((t - origin) / cell_ms).floor() + 1.0) * cell_ms;
            let k1 = k.max(((cell_end.min(end) - s.next) / s.period).ceil() as i64 - 1);
            match sel {
                Some(sk) if sk >= k && sk <= k1 => {
                    out.marks.push(Drawn::Repeat(Box::new(s.repeat(sk))));
                    add(&mut cells, k, sk - 1);
                    add(&mut cells, sk + 1, k1);
                }
                _ => add(&mut cells, k, k1),
            }
            k = k1 + 1;
        }
    }
    for key in std::mem::take(&mut cells.order) {
        let c = cells.cells.remove(&key).expect("ordered cell");
        if c.count == 1 {
            if let Some(&i) = c.marks.first() {
                out.marks.push(Drawn::Loaded(i));
            } else if let Some(r) = c.runs.first() {
                out.marks
                    .push(Drawn::Repeat(Box::new(schedules[r.schedule].repeat(r.k0))));
            }
            continue;
        }
        out.clusters.push(Cluster {
            id: format!("{}|{}|{level}", c.key.0, c.key.1),
            row: c.row,
            at: origin + c.sum / c.count as f64,
            from: c.from,
            to: c.to,
            count: c.count,
            marks: c.marks,
            runs: c.runs,
            scheduled: c.scheduled,
        });
    }
    out
}

/// The mark after (`dir` > 0) or before the position (`t`, `id`) in (start, id) order, over the
/// loaded marks and every schedule's repeats up to `until`. An empty `id` stands for "at `t`":
/// forward includes marks at `t`, backward excludes them.
pub fn step_marks(
    marks: &[Mark],
    schedules: &[Schedule],
    until: Ms,
    t: Ms,
    id: &str,
    dir: i32,
) -> Option<Mark> {
    let after = |bt: Ms, bid: &str| bt > t || (bt == t && bid > id);
    let before = |bt: Ms, bid: &str| bt < t || (bt == t && bid < id);
    let better = |a: Ms, aid: &str, b: Ms, bid: &str| {
        if dir > 0 {
            a < b || (a == b && aid < bid)
        } else {
            a > b || (a == b && aid > bid)
        }
    };
    let mut best: Option<Mark> = None;
    let mut offer = |m: &Mark| {
        if best
            .as_ref()
            .is_none_or(|b| better(m.start, &m.id, b.start, &b.id))
        {
            best = Some(m.clone());
        }
    };
    let k = lower_bound(marks, t);
    if dir > 0 {
        // Marks sharing a start sit in no id order: scan the tie group, then the next start's.
        let mut group: Option<Ms> = None;
        for m in &marks[k..] {
            if group.is_some_and(|g| m.start > g) {
                break;
            }
            if !after(m.start, &m.id) {
                continue;
            }
            if m.start > t {
                group.get_or_insert(m.start);
            }
            offer(m);
        }
    } else {
        for m in &marks[k..] {
            if m.start > t {
                break;
            }
            if before(t, &m.id) {
                offer(m);
            }
        }
        let mut group: Option<Ms> = None;
        for m in marks[..k].iter().rev() {
            if group.is_some_and(|g| m.start < g) {
                break;
            }
            group.get_or_insert(m.start);
            offer(m);
        }
    }
    for s in schedules.iter().filter(|s| s.is_periodic()) {
        let mut kk = if dir > 0 {
            1.max(((t - s.next) / s.period).ceil() as i64)
        } else {
            (((t - s.next) / s.period).floor() as i64)
                .min(((until - s.next) / s.period).ceil() as i64 - 1)
        };
        // At most two candidates either way: the repeat at `t` may sit on the wrong side of `id`.
        for _ in 0..2 {
            if kk < 1 || s.at(kk) >= until {
                break;
            }
            let r = s.repeat(kk);
            if (dir > 0 && after(r.start, &r.id)) || (dir < 0 && before(r.start, &r.id)) {
                offer(&r);
                break;
            }
            kk += i64::from(dir.signum());
        }
    }
    best
}

/// The next (`dir` > 0) or previous finished, steppable outcome after `t`, by outcome time
/// (ties by id): what ← / → visit.
pub fn step_outcomes(marks: &[Mark], now: Ms, t: Ms, id: &str, dir: i32) -> Option<usize> {
    let mut best: Option<usize> = None;
    for (i, m) in marks.iter().enumerate() {
        if !m.steppable || m.live || m.scheduled || m.outcome > now {
            continue;
        }
        let (o, mid) = (m.outcome, &*m.id);
        let past = if dir > 0 {
            o > t || (o == t && mid > id)
        } else {
            o < t || (o == t && mid < id)
        };
        if !past {
            continue;
        }
        let wins = best.is_none_or(|b| {
            let (bo, bid) = (marks[b].outcome, &*marks[b].id);
            if dir > 0 {
                o < bo || (o == bo && mid < bid)
            } else {
                o > bo || (o == bo && mid > bid)
            }
        });
        if wins {
            best = Some(i);
        }
    }
    best
}

/// Where a playhead released at `t` snaps: the outcome nearest `t` (its distance weighted by
/// the mark) of a finished mark, within `tol`.
pub fn nearest_outcome(marks: &[Mark], t: Ms, tol: Ms, now: Ms, reach: Ms) -> Option<Ms> {
    let mut best = None;
    let mut best_d = f64::INFINITY;
    for m in &marks[lower_bound(marks, t - tol - reach)..] {
        if m.start > t + tol {
            break;
        }
        if m.scheduled || m.live {
            continue;
        }
        let o = m.outcome;
        if o > now || (o - t).abs() > tol {
            continue;
        }
        let d = (o - t).abs() * f64::from(m.snap_weight);
        if d < best_d {
            best_d = d;
            best = Some(o);
        }
    }
    best
}

/// "every 5 min" for a period.
pub fn every_label(period: Ms) -> String {
    let s = period / 1000.0;
    if s < 60.0 {
        format!("every {} s", s.round())
    } else if s < 3600.0 {
        format!("every {} min", (s / 60.0).round())
    } else {
        format!("every {:.1} h", s / 3600.0)
    }
}

/// False when even the 15 min limit keeps a cluster's members in one cell.
pub fn can_unfold(c: &Cluster, width: f64) -> bool {
    (c.to - c.from) * crate::geometry::scale_limits(width).1 >= CELL_PT
}

/// The scale that opens a cluster: its members across a quarter of the screen, at least twice
/// the current zoom, never past the 15 min limit.
pub fn unfold_scale(c: &Cluster, scale: f64, width: f64) -> f64 {
    let extent = (c.to - c.from).max(MIN_MS);
    let (_, max) = crate::geometry::scale_limits(width);
    max.min((scale * 2.0).max(width / 4.0 / extent))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mark::Paint;
    use crate::time::HOUR_MS;
    use canvas_draw::Rgba;

    fn mark(id: &str, row: &str, start: Ms) -> Mark {
        Mark {
            id: id.into(),
            row: row.into(),
            start,
            outcome: start,
            end: Some(start),
            scheduled: false,
            live: false,
            stands_out: false,
            steppable: true,
            snap_weight: 1.0,
            sort: "x".into(),
            schedule: None,
            paint: Paint::rect(8.0, Rgba::WHITE),
        }
    }

    const FOLDS: FoldRules = FoldRules {
        folds: true,
        reach: 3.0 * HOUR_MS,
    };

    fn folded_ids(f: &Folded, marks: &[Mark]) -> (Vec<String>, Vec<(String, u64)>) {
        let mut drawn: Vec<String> = f
            .marks
            .iter()
            .map(|d| match d {
                Drawn::Loaded(i) => marks[*i].id.to_string(),
                Drawn::Repeat(m) => m.id.to_string(),
            })
            .collect();
        drawn.sort();
        let mut clusters: Vec<(String, u64)> =
            f.clusters.iter().map(|c| (c.id.clone(), c.count)).collect();
        clusters.sort();
        (drawn, clusters)
    }

    #[test]
    fn a_pan_never_reshuffles_the_fold() {
        // Marks every 3 minutes at a level where a cell is ~10 minutes.
        let level = crate::geometry::level_of(CELL_PT / (10.0 * MIN_MS));
        let marks: Vec<Mark> = (0..200)
            .map(|i| mark(&format!("m{i:03}"), "a", i as f64 * 3.0 * MIN_MS))
            .collect();
        let at = |from: Ms| {
            fold_window(
                FOLDS,
                &marks,
                &[],
                from,
                from + 4.0 * HOUR_MS,
                f64::INFINITY,
                level,
                0.0,
                None,
            )
        };
        let a = at(2.0 * HOUR_MS);
        let b = at(2.0 * HOUR_MS + 17.0 * MIN_MS);
        // Every cluster wholly inside both windows is identical in both.
        let inner = |f: &Folded| -> Vec<(String, u64)> {
            let mut v: Vec<_> = f
                .clusters
                .iter()
                .filter(|c| c.from >= 2.5 * HOUR_MS && c.to < 5.5 * HOUR_MS)
                .map(|c| (c.id.clone(), c.count))
                .collect();
            v.sort();
            v
        };
        assert!(!inner(&a).is_empty());
        assert_eq!(inner(&a), inner(&b));
    }

    #[test]
    fn what_stands_out_and_the_selection_never_fold() {
        let level = crate::geometry::level_of(CELL_PT / (10.0 * MIN_MS));
        let mut marks: Vec<Mark> = (0..3)
            .map(|i| mark(&format!("m{i}"), "a", i as f64 * MIN_MS))
            .collect();
        marks[1].stands_out = true;
        let f = fold_window(
            FOLDS,
            &marks,
            &[],
            0.0,
            HOUR_MS,
            f64::INFINITY,
            level,
            0.0,
            Some("m2"),
        );
        let (drawn, clusters) = folded_ids(&f, &marks);
        assert_eq!(
            drawn,
            ["m0", "m1", "m2"],
            "the cell left with one mark draws it as it is"
        );
        assert!(clusters.is_empty());
    }

    #[test]
    fn a_dense_timer_is_a_rail_and_a_sparse_one_folds_counted() {
        let level = crate::geometry::level_of(CELL_PT / (10.0 * MIN_MS));
        let sched = |key: &str, next: Ms, period: Ms| Schedule {
            key: key.into(),
            row: "timers".into(),
            next,
            period,
            name: key.into(),
            color: Rgba::WHITE,
            paint: Paint::rect(6.0, Rgba::WHITE),
        };
        // health runs every minute (denser than a rail's 20 pt); two backups a minute apart share
        // each cell (~11 min here).
        let schedules = [
            sched("health", 0.0, MIN_MS),
            sched("db", 0.0, 50.0 * MIN_MS),
            sched("files", MIN_MS, 50.0 * MIN_MS),
        ];
        let until = 3.0 * HOUR_MS;
        let f = fold_window(FOLDS, &[], &schedules, 0.0, until, until, level, 0.0, None);
        assert_eq!(f.rails.len(), 1);
        assert_eq!(f.rails[0].members, vec![0]);
        assert!(f.railed.contains("health"));
        // db at 50, 100 and 150 min, files a minute after each (k ≥ 1): three counted clusters.
        let mut counts: Vec<u64> = f.clusters.iter().map(|c| c.count).collect();
        counts.sort();
        assert_eq!(counts, [2, 2, 2]);
        assert!(f.marks.is_empty());
        assert!(f.clusters.iter().all(|c| c.scheduled && c.marks.is_empty()));
    }

    #[test]
    fn both_stepping_orders_break_equal_times_by_id() {
        let marks = vec![
            mark("b", "r", 10.0),
            mark("a", "r", 10.0),
            mark("c", "r", 20.0),
        ];
        let mut sorted = marks.clone();
        sorted.sort_by(|x, y| x.start.total_cmp(&y.start));
        let fwd = |t: Ms, id: &str| {
            step_marks(&sorted, &[], f64::INFINITY, t, id, 1).map(|m| m.id.to_string())
        };
        let back = |t: Ms, id: &str| {
            step_marks(&sorted, &[], f64::INFINITY, t, id, -1).map(|m| m.id.to_string())
        };
        assert_eq!(
            fwd(10.0, "").as_deref(),
            Some("a"),
            "forward from 'at t' includes t"
        );
        assert_eq!(fwd(10.0, "a").as_deref(), Some("b"));
        assert_eq!(fwd(10.0, "b").as_deref(), Some("c"));
        assert_eq!(back(20.0, "c").as_deref(), Some("b"));
        assert_eq!(back(10.0, "b").as_deref(), Some("a"));
        assert_eq!(back(10.0, "a"), None);
        // Outcome stepping orders by outcome, ties by id, and skips what still runs.
        let mut o = sorted.clone();
        o[2].outcome = 10.0;
        o.iter_mut().find(|m| &*m.id == "a").expect("a").live = true;
        let step = |t: Ms, id: &str, dir| {
            step_outcomes(&o, 100.0, t, id, dir).map(|i| o[i].id.to_string())
        };
        assert_eq!(
            step(0.0, "", 1).as_deref(),
            Some("b"),
            "a runs, so b is first"
        );
        assert_eq!(step(10.0, "b", 1).as_deref(), Some("c"));
        assert_eq!(step(10.0, "c", -1).as_deref(), Some("b"));
    }

    #[test]
    fn a_released_playhead_snaps_to_the_nearest_finished_outcome() {
        let mut marks = vec![
            mark("a", "r", 0.0),
            mark("b", "r", 50.0),
            mark("c", "r", 90.0),
        ];
        marks[1].outcome = 60.0;
        marks[2].live = true;
        assert_eq!(
            nearest_outcome(&marks, 70.0, 20.0, 100.0, 100.0),
            Some(60.0)
        );
        assert_eq!(
            nearest_outcome(&marks, 85.0, 5.0, 100.0, 100.0),
            None,
            "c runs"
        );
    }
}
