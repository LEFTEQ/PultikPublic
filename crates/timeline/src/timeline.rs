//! One timeline on screen: its lens's data, the view (time at the left edge, zoom, vertical
//! scroll), the selection and the playhead, and the rule for when the scene is built again.
//! Gestures and keys move the view; a move that stays inside the scene's semantic is a camera
//! move ([`Timeline::camera`]) and builds nothing.

use crate::density::{nearest_outcome, step_marks, step_outcomes};
use crate::geometry::{AXIS_PT, MAX_SPAN_MS, Semantic, View, scale_limits};
use crate::layout::GroupSpec;
use crate::lens::{LensSpec, Palette};
use crate::mark::{Band, Bin, Mark, Schedule};
use crate::scene::{Hit, Scene, SceneInput};
use crate::time::{DAY_MS, Ms};
use canvas_draw::{Camera, DisplayList};
use canvas_text::TextSystem;
use std::sync::Arc;

/// The label column's width, points.
pub const LABEL_W: f32 = 168.0;
/// One −/= press: a level (√2) per step.
const ZOOM_STEP: f64 = std::f64::consts::SQRT_2;
/// ⌥←/→: a fifth of the screen.
const PAN_STEP: f64 = 0.2;
/// How far a released playhead looks for an outcome to snap to, points.
const SNAP_PT: f64 = 12.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// ←/→: finished outcomes, by outcome time.
    Outcome,
    /// ⇧←/→: every mark, by (start, id).
    Every,
}

pub struct Timeline {
    pub spec: LensSpec,
    pub palette: Palette,
    marks: Vec<Mark>,
    bins: Vec<Bin>,
    bands: Vec<Band>,
    schedules: Vec<Schedule>,
    groups: Vec<GroupSpec>,
    view: View,
    /// The lanes' vertical scroll, points.
    scroll: f32,
    size: (f32, f32),
    k: f32,
    now: Ms,
    selected: Option<Arc<str>>,
    playhead: Option<Ms>,
    scene: Option<Scene>,
    /// Data, selection, size or playhead changed since the scene was built.
    stale: bool,
}

impl Timeline {
    pub fn new(spec: LensSpec, palette: Palette, now: Ms) -> Timeline {
        let width = 1000.0;
        Timeline {
            spec,
            palette,
            marks: Vec::new(),
            bins: Vec::new(),
            bands: Vec::new(),
            schedules: Vec::new(),
            groups: Vec::new(),
            // The first view: the last and the next twelve hours.
            view: View {
                t0: now - DAY_MS / 2.0,
                scale: width / DAY_MS,
                width,
            },
            scroll: 0.0,
            size: (width as f32 + LABEL_W, 400.0),
            k: 1.0,
            now,
            selected: None,
            playhead: None,
            scene: None,
            stale: true,
        }
    }

    /// The marks to draw, any order (they are sorted by start here).
    pub fn set_marks(&mut self, mut marks: Vec<Mark>) {
        marks.sort_by(|a, b| a.start.total_cmp(&b.start).then_with(|| a.id.cmp(&b.id)));
        self.marks = marks;
        self.stale = true;
    }
    pub fn set_bins(&mut self, bins: Vec<Bin>) {
        self.bins = bins;
        self.stale = true;
    }
    pub fn set_bands(&mut self, bands: Vec<Band>) {
        self.bands = bands;
        self.stale = true;
    }
    pub fn set_schedules(&mut self, schedules: Vec<Schedule>) {
        self.schedules = schedules;
        self.stale = true;
    }
    pub fn set_groups(&mut self, groups: Vec<GroupSpec>) {
        self.groups = groups;
        self.stale = true;
    }
    pub fn set_palette(&mut self, palette: Palette) {
        self.palette = palette;
        self.stale = true;
    }

    pub fn marks(&self) -> &[Mark] {
        &self.marks
    }

    /// The surface is `w` × `h` points.
    pub fn resize(&mut self, w: f32, h: f32) {
        let lanes = f64::from((w - LABEL_W).max(1.0));
        // Keep the time at the lanes' centre where it was.
        let centre = self.view.t_of(self.view.width / 2.0);
        self.view.width = lanes;
        self.view.t0 = centre - lanes / 2.0 / self.view.scale;
        self.size = (w, h);
        self.clamp();
        self.stale = true;
    }

    /// The host's clock moved on.
    pub fn set_now(&mut self, now: Ms) {
        self.now = now;
    }

    pub fn now(&self) -> Ms {
        self.now
    }

    pub fn view(&self) -> View {
        self.view
    }

    pub fn scroll(&self) -> f32 {
        self.scroll
    }

    /// What a host loads: the visible span plus one span either side.
    pub fn wanted(&self) -> (Ms, Ms) {
        let s = Semantic::of(&self.view, &self.spec.zoom);
        (s.from, s.to)
    }

    /// The bin width the server is asked for at this zoom (`None`: marks).
    pub fn bucket(&self) -> Option<Ms> {
        crate::geometry::bucket_for(&self.view, &self.spec.zoom)
    }

    fn content_height(&self) -> f32 {
        self.scene.as_ref().map_or(AXIS_PT, |s| s.layout.height)
    }

    fn clamp(&mut self) {
        let (lo, hi) = scale_limits(self.view.width);
        self.view.scale = self.view.scale.clamp(lo, hi);
        let latest = self.now + self.spec.future.max(0.0) - self.view.span() * 0.5;
        let earliest = self.now - MAX_SPAN_MS * 4.0;
        self.view.t0 = self.view.t0.clamp(earliest, latest.max(earliest));
        let max_scroll = (self.content_height() - self.size.1).max(0.0);
        self.scroll = self.scroll.clamp(0.0, max_scroll);
    }

    /// Two fingers moved the content by (`dx`, `dy`) points (momentum included: the system
    /// sends its own momentum events).
    pub fn scroll_by(&mut self, dx: f64, dy: f32) {
        self.view.t0 -= dx / self.view.scale;
        self.scroll -= dy;
        self.clamp();
    }

    /// A pinch (or −/=) by `factor` around lanes point `x` (`None`: the lanes' centre).
    pub fn zoom_by(&mut self, factor: f64, x: Option<f64>) {
        let x = x.unwrap_or(self.view.width / 2.0);
        let t = self.view.t_of(x);
        self.view.scale *= factor;
        self.clamp();
        self.view.t0 = t - x / self.view.scale;
        self.clamp();
    }

    /// −/=: one level out (`dir` < 0) or in.
    pub fn zoom_step(&mut self, dir: i32) {
        let f = if dir > 0 { ZOOM_STEP } else { 1.0 / ZOOM_STEP };
        let anchor = self
            .selected_mark()
            .map(|m| self.view.x_of(m.outcome))
            .filter(|x| (0.0..=self.view.width).contains(x));
        self.zoom_by(f, anchor);
    }

    /// ⌥←/→: a fifth of the screen.
    pub fn pan_step(&mut self, dir: i32) {
        self.view.t0 += f64::from(dir.signum()) * self.view.span() * PAN_STEP;
        self.clamp();
    }

    /// N: now at the lanes' right third, the playhead released.
    pub fn go_now(&mut self) {
        self.view.t0 = self.now - self.view.span() * 2.0 / 3.0;
        self.playhead = None;
        self.clamp();
        self.stale = true;
    }

    pub fn selected(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    fn selected_mark(&self) -> Option<&Mark> {
        let id = self.selected.as_deref()?;
        self.marks.iter().find(|m| &*m.id == id)
    }

    /// Select a mark by id (`None` clears it); the view follows it into sight.
    pub fn select(&mut self, id: Option<&str>) {
        self.selected = id.map(Arc::from);
        if let Some(m) = self.selected_mark() {
            let (x0, x1) = (self.view.x_of(m.start), self.view.x_of(m.outcome));
            if x1 < 0.0 || x0 > self.view.width {
                self.view.t0 = m.outcome - self.view.span() / 2.0;
                self.clamp();
            }
        }
        self.stale = true;
    }

    /// ←/→ (`Step::Outcome`) or ⇧←/→ (`Step::Every`): select the next mark that way and put the
    /// playhead on its outcome. Returns its id.
    pub fn step(&mut self, how: Step, dir: i32) -> Option<Arc<str>> {
        let current = self.selected_mark().cloned();
        let id = current.as_ref().map_or("", |m| &*m.id).to_string();
        let next = match how {
            Step::Outcome => {
                let t = current
                    .as_ref()
                    .map_or_else(|| self.playhead.unwrap_or(self.now), |m| m.outcome);
                step_outcomes(&self.marks, self.now, t, &id, dir).map(|i| self.marks[i].clone())
            }
            Step::Every => {
                let t = current
                    .as_ref()
                    .map_or_else(|| self.playhead.unwrap_or(self.now), |m| m.start);
                let until = self.now + self.spec.future;
                step_marks(&self.marks, &self.schedules, until, t, &id, dir)
            }
        }?;
        self.playhead = Some(next.outcome.min(self.now));
        self.select(Some(&next.id));
        Some(next.id)
    }

    /// The playhead dragged to lanes point `x`; on `release` it snaps to the nearest finished
    /// outcome near it.
    pub fn drag_playhead(&mut self, x: f64, release: bool) -> Ms {
        let mut t = self.view.t_of(x).min(self.now);
        if release
            && let Some(o) = nearest_outcome(
                &self.marks,
                t,
                SNAP_PT / self.view.scale,
                self.now,
                self.spec.fold.reach,
            )
        {
            t = o;
        }
        self.playhead = Some(t);
        self.stale = true;
        t
    }

    pub fn playhead(&self) -> Option<Ms> {
        self.playhead
    }

    pub fn release_playhead(&mut self) {
        self.playhead = None;
        self.stale = true;
    }

    /// How long until a running item on screen has grown by a point and the scene is due again
    /// (`None`: nothing runs in the window). A host sleeps until then instead of ticking.
    pub fn next_build_in(&self) -> Option<Ms> {
        let s = self.scene.as_ref().filter(|s| s.live_in_window)?;
        Some((1.0 / self.view.scale - (self.now - s.now)).max(0.0))
    }

    /// Show `[from, to]` across a quarter of the lanes, at least twice the current zoom (a
    /// cluster or a band opened by a click).
    pub fn zoom_to(&mut self, from: Ms, to: Ms) {
        let extent = (to - from).max(crate::time::MIN_MS);
        let (_, max) = scale_limits(self.view.width);
        self.view.scale = max.min((self.view.scale * 2.0).max(self.view.width / 4.0 / extent));
        self.view.t0 = (from + to) / 2.0 - self.view.span() / 2.0;
        self.clamp();
    }

    /// Whether the scene must be built again before the next frame: the view left it, its data,
    /// size, selection or playhead changed, or a running item grew by a point.
    pub fn needs_build(&self) -> bool {
        let Some(s) = &self.scene else {
            return true;
        };
        self.stale
            || s.semantic.left_by(&self.view, &self.spec.zoom)
            || (s.live_in_window && (self.now - s.now) * self.view.scale >= 1.0)
    }

    /// Build the scene for the current view and return its display list; the camera then places
    /// it ([`Timeline::camera`]).
    pub fn build(&mut self, text: &mut TextSystem) -> DisplayList {
        let semantic = Semantic::of(&self.view, &self.spec.zoom);
        let scene = Scene::build(SceneInput {
            spec: self.spec,
            marks: &self.marks,
            bins: &self.bins,
            bands: &self.bands,
            schedules: &self.schedules,
            groups: &self.groups,
            k: self.k,
            semantic,
            now: self.now,
            grid_origin: 0.0,
            selected: self.selected.as_deref(),
            playhead: self.playhead,
        });
        let dl = scene.emit(self.size, LABEL_W, &self.palette, text, &self.view);
        self.scene = Some(scene);
        self.stale = false;
        self.clamp();
        dl
    }

    /// Where the built scene's camera layers draw at the current view.
    pub fn camera(&self) -> Camera {
        self.scene.as_ref().map_or(Camera::IDENTITY, |s| {
            s.camera(&self.view, LABEL_W, self.scroll)
        })
    }

    pub fn scene(&self) -> Option<&Scene> {
        self.scene.as_ref()
    }

    /// What view point (`x`, `y`) is on.
    pub fn hit(&self, x: f32, y: f32) -> Option<Hit> {
        let s = self.scene.as_ref()?;
        if x < LABEL_W || y < AXIS_PT {
            return None;
        }
        s.hit(&self.view, f64::from(x - LABEL_W), y + self.scroll)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::stacked_group;
    use crate::lens::Lens;
    use crate::lens::ci::{CiJob, CiLens, CiResult};
    use crate::time::{HOUR_MS, MIN_MS};

    const NOW: Ms = 1_792_000_000_000.0;

    fn job(id: &str, lane: &str, queued: Ms, ran: Ms, result: CiResult) -> CiJob {
        CiJob {
            id: id.into(),
            lane: lane.into(),
            repo: "ExampleApp".into(),
            name: id.into(),
            queued_at: queued,
            started_at: Some(queued + MIN_MS),
            completed_at: (!result.open()).then_some(queued + MIN_MS + ran),
            result,
            peak_mib: None,
            reserved_mib: None,
        }
    }

    fn ci(jobs: &[CiJob]) -> Timeline {
        let p = Palette::default();
        let mut t = Timeline::new(CiLens.spec(), p, NOW);
        t.set_groups(vec![stacked_group(
            "org",
            "ExampleApp",
            &[
                ("a".into(), "lane a".into(), None),
                ("b".into(), "lane b".into(), None),
            ],
            0.0,
        )]);
        t.set_marks(jobs.iter().map(|j| CiLens.mark(j, &p)).collect());
        t.resize(1168.0, 400.0);
        t
    }

    #[test]
    fn a_pan_or_pinch_inside_a_level_builds_nothing() {
        let mut t = ci(&[job(
            "j1",
            "a",
            NOW - HOUR_MS,
            10.0 * MIN_MS,
            CiResult::Succeeded,
        )]);
        let mut text = TextSystem::new();
        t.build(&mut text);
        assert!(!t.needs_build());
        let before = t.camera();
        t.scroll_by(40.0, 0.0);
        let level = t.scene().expect("built").semantic.level;
        t.zoom_by(1.1, None);
        if crate::geometry::level_of(t.view().scale) == level {
            assert!(!t.needs_build(), "inside the level: a camera move");
            assert_ne!(t.camera(), before);
        }
        t.zoom_by(2.0, None);
        assert!(t.needs_build(), "a level away: built again");
    }

    #[test]
    fn origin_relative_world_points_stay_precise_at_any_date() {
        let mut t = ci(&[job(
            "j1",
            "a",
            NOW - HOUR_MS,
            10.0 * MIN_MS,
            CiResult::Succeeded,
        )]);
        t.zoom_by(1e6, None); // clamps to 15 min per screen
        let mut text = TextSystem::new();
        t.build(&mut text);
        let s = t.scene().expect("built");
        let cam = t.camera();
        // A mark's view x through the f32 world and camera equals the exact f64 mapping.
        let at = NOW - 3.0 * MIN_MS;
        let via_world = s.x(at) * cam.scale.x + cam.offset.x;
        let exact = LABEL_W as f64 + t.view().x_of(at);
        assert!(
            (f64::from(via_world) - exact).abs() < 0.01,
            "{via_world} vs {exact}"
        );
    }

    #[test]
    fn hits_prefer_the_selection_then_the_nearest() {
        let jobs = [
            job(
                "j1",
                "a",
                NOW - 2.0 * HOUR_MS,
                30.0 * MIN_MS,
                CiResult::Succeeded,
            ),
            job(
                "j2",
                "a",
                NOW - 2.0 * HOUR_MS + 5.0 * MIN_MS,
                30.0 * MIN_MS,
                CiResult::Failed,
            ),
        ];
        let mut t = ci(&jobs);
        let mut text = TextSystem::new();
        t.build(&mut text);
        let s = t.scene().expect("built");
        // Two tracks: j1 on the first, j2 (overlapping) on the second.
        let ys: Vec<f32> = s.items.iter().map(|i| i.y).collect();
        assert_ne!(ys[0], ys[1]);
        let x = LABEL_W + t.view().x_of(NOW - 2.0 * HOUR_MS + 15.0 * MIN_MS) as f32;
        let on = |t: &Timeline, y: f32| match t.hit(x, y - t.scroll()) {
            Some(Hit::Mark(id)) => Some(id.to_string()),
            _ => None,
        };
        assert_eq!(on(&t, ys[0]).as_deref(), Some("j1"));
        assert_eq!(on(&t, ys[1]).as_deref(), Some("j2"));
        t.select(Some("j1"));
        t.build(&mut text);
        let mid = (ys[0] + ys[1]) / 2.0;
        assert_eq!(
            on(&t, mid).as_deref(),
            Some("j1"),
            "the selection answers first"
        );
    }

    #[test]
    fn arrows_step_finished_outcomes_and_park_the_playhead() {
        let jobs = [
            job(
                "j1",
                "a",
                NOW - 3.0 * HOUR_MS,
                10.0 * MIN_MS,
                CiResult::Succeeded,
            ),
            job(
                "j2",
                "b",
                NOW - 2.0 * HOUR_MS,
                10.0 * MIN_MS,
                CiResult::Failed,
            ),
            job("j3", "a", NOW - HOUR_MS, 0.0, CiResult::Running),
        ];
        let mut t = ci(&jobs);
        assert_eq!(
            t.step(Step::Outcome, -1).as_deref(),
            Some("j2"),
            "← from now: the last finished"
        );
        assert_eq!(t.playhead(), Some(NOW - 2.0 * HOUR_MS + 11.0 * MIN_MS));
        assert_eq!(t.step(Step::Outcome, -1).as_deref(), Some("j1"));
        assert_eq!(t.step(Step::Outcome, -1), None);
        assert_eq!(t.step(Step::Every, 1).as_deref(), Some("j2"));
        assert_eq!(
            t.step(Step::Every, 1).as_deref(),
            Some("j3"),
            "⇧→ visits a running job too"
        );
        t.go_now();
        assert_eq!(t.playhead(), None);
    }
}
