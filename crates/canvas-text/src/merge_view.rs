//! The merge view (vt-7968, decision M4 in `docs/specs/2026-10-18-merge-view-decisions.md`):
//! one file's three-way merge as WebStorm draws it. Ours, the result and theirs side by side,
//! the merge base on demand at the left; each pane holds its own lines, never padded to line up,
//! and a curved ribbon joins a region's lines across each gap. Both apps draw merges only
//! through it, as they draw diffs only through [`crate::diff_view`].
//!
//! **Scrolling.** One scroll runs down the regions laid end to end, each as tall as its longest
//! shown pane (a stretch nobody changed moves every pane one to one). Each pane is placed so the
//! line at the view's centre is the same stretch in all of them: through a region a pane moves
//! at its share of the region's height, so a side that added ten lines scrolls on while the
//! others wait.
//!
//! **Ribbons** are paths in a camera layer that follows the scroll: while the panes move
//! together a ribbon's world points stay put, so the renderer tessellates it once, and only a
//! region the panes cross at different speeds is rebuilt (crates/CLAUDE.md, `Op::Path`).
//!
//! **Regions** come from `code_core::merge`: a pane washes its lines in the region's tone
//! (changed: info, resolved: the added colour, conflict: error, decided by a past merge's
//! commit: warning), an empty stretch is a rule across the pane, ⇥ walks the conflicts and
//! the resolutions, and a strip at the right marks every changed region over the whole file.

use crate::code_view::CodeColors;
use crate::diff_view::DiffMetrics;
use canvas_draw::{
    Camera, CellSpan, CodeBlock, CodeRows, Follow, Op, Path, PathOp, Point, Rect, Rgba,
    RoundedRect, Size, Stroke, TextRun,
};
use code_core::Placer;
use code_core::diff::columns;
use code_core::merge::{Merge, Region, RegionKind, Side};
use code_core::syntax::LineTokens;
use std::fmt::Write;
use std::ops::Range;
use std::sync::Arc;

fn rgba(c: theme::Rgba) -> Rgba {
    Rgba::new(c.r, c.g, c.b, c.a)
}

/// A pane of the view, left to right.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MergePane {
    /// The merge base (shown on demand).
    Base,
    Ours,
    Result,
    Theirs,
}

impl MergePane {
    pub const ALL: [MergePane; 4] = [
        MergePane::Base,
        MergePane::Ours,
        MergePane::Result,
        MergePane::Theirs,
    ];

    fn index(self) -> usize {
        self as usize
    }
}

/// A region's lines in `pane`'s text.
fn range(r: &Region, pane: MergePane) -> &Range<usize> {
    match pane {
        MergePane::Base => r.range(Side::Base),
        MergePane::Ours => r.range(Side::Ours),
        MergePane::Result => &r.result,
        MergePane::Theirs => r.range(Side::Theirs),
    }
}

/// One pane's text and where each line starts.
#[derive(Debug, Default)]
struct PaneText {
    text: String,
    /// Each line's first byte, then the text's length.
    starts: Vec<usize>,
}

impl PaneText {
    fn new(text: &str) -> Self {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(at, _)| at + 1));
        if starts.last() != Some(&text.len()) {
            starts.push(text.len());
        }
        Self {
            text: text.to_owned(),
            starts,
        }
    }

    fn len(&self) -> usize {
        self.starts.len() - 1
    }

    /// Line `i` without its ending.
    fn line(&self, i: usize) -> &str {
        let l = &self.text[self.starts[i]..self.starts[i + 1]];
        let l = l.strip_suffix('\n').unwrap_or(l);
        l.strip_suffix('\r').unwrap_or(l)
    }
}

/// What a point is over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeHit {
    None,
    Header(MergePane),
    /// A pane's line, and the region holding it (an unchanged one included).
    Line {
        pane: MergePane,
        line: usize,
        region: Option<usize>,
    },
    /// A ribbon between two panes.
    Ribbon {
        region: usize,
    },
}

/// A ribbon's cache key: its gap's edges and its four ends, in 1/64 pt world units.
type RibbonKey = [i32; 6];

/// One file's merge on screen.
#[derive(Debug)]
pub struct MergeView {
    merge: Merge,
    panes: [PaneText; 4],
    tokens: [Option<LineTokens>; 4],
    labels: [String; 4],
    base: bool,
    metrics: DiffMetrics,
    /// The view's top-left in the host's points.
    pub origin: Point,
    size: Size,
    /// Points down the regions laid end to end.
    scroll: f64,
    left: f32,
    /// Each region's top in that layout, in lines, then the total.
    virt: Vec<f64>,
    current: Option<usize>,
    digits: usize,
    widest: u32,
    pool: Vec<Arc<CodeRows>>,
    used: usize,
    cols: Vec<u16>,
    byte_cols: Vec<u16>,
    text: String,
    /// Per region and gap: the last ribbon built and what it was built from.
    ribbons: Vec<Option<(RibbonKey, Arc<Path>)>>,
    /// The region strip's ticks (top and height in the body, tone), laid for a body `strip_h` tall.
    strip: Vec<(f32, f32, Tone)>,
    strip_h: f32,
}

impl MergeView {
    /// `merge` of `base`, `ours` and `theirs` (the result is the merge's own text).
    pub fn new(base: &str, ours: &str, theirs: &str, merge: Merge, metrics: DiffMetrics) -> Self {
        let panes = [
            PaneText::new(base),
            PaneText::new(ours),
            PaneText::new(&merge.result),
            PaneText::new(theirs),
        ];
        let mut view = Self {
            ribbons: vec![None; 3 * merge.regions.len()],
            strip: Vec::new(),
            strip_h: -1.0,
            merge,
            panes,
            tokens: [None, None, None, None],
            labels: ["Base", "Ours", "Result", "Theirs"].map(String::from),
            base: false,
            metrics,
            origin: Point::ZERO,
            size: Size::new(0.0, 0.0),
            scroll: 0.0,
            left: 0.0,
            virt: Vec::new(),
            current: None,
            digits: 3,
            widest: 0,
            pool: Vec::new(),
            used: 0,
            cols: Vec::new(),
            byte_cols: Vec::new(),
            text: String::new(),
        };
        view.relayout();
        view
    }

    pub fn merge(&self) -> &Merge {
        &self.merge
    }

    /// `pane`'s lines.
    pub fn line_count(&self, pane: MergePane) -> usize {
        self.panes[pane.index()].len()
    }

    /// `pane`'s line `i` without its ending.
    pub fn line(&self, pane: MergePane, i: usize) -> Option<&str> {
        let p = &self.panes[pane.index()];
        (i < p.len()).then(|| p.line(i))
    }

    /// Each pane's title (`MergePane` order): the branches, the commit, what the result is.
    pub fn set_labels(&mut self, labels: [String; 4]) {
        self.labels = labels;
    }

    /// One pane's highlights, by its lines.
    pub fn set_tokens(&mut self, pane: MergePane, tokens: LineTokens) {
        self.tokens[pane.index()] = Some(tokens);
    }

    pub fn has_tokens(&self, pane: MergePane) -> bool {
        self.tokens[pane.index()].is_some()
    }

    pub fn shows_base(&self) -> bool {
        self.base
    }

    /// Show the merge base as a fourth pane at the left; the stretch at the centre stays.
    pub fn set_shows_base(&mut self, base: bool) {
        if base != self.base {
            let center = self.center_line();
            self.base = base;
            self.relayout();
            self.set_center_line(center);
        }
    }

    pub fn metrics(&self) -> DiffMetrics {
        self.metrics
    }

    /// The code font changed size (a zoom): the stretch at the centre stays.
    pub fn set_metrics(&mut self, metrics: DiffMetrics) {
        if metrics != self.metrics {
            let center = self.center_line();
            self.metrics = metrics;
            self.relayout();
            self.set_center_line(center);
        }
    }

    pub fn size(&self) -> Size {
        self.size
    }

    pub fn resize(&mut self, size: Size) {
        if size != self.size {
            let center = self.center_line();
            self.size = size;
            self.set_center_line(center);
        }
    }

    /// The panes shown, left to right.
    pub fn shown(&self) -> &'static [MergePane] {
        match self.base {
            true => &MergePane::ALL,
            false => &MergePane::ALL[1..],
        }
    }

    fn k(&self) -> f32 {
        self.metrics.cell.h / 18.0
    }

    fn relayout(&mut self) {
        self.strip_h = -1.0;
        self.virt.clear();
        self.virt.push(0.0);
        let mut v = 0.0;
        for r in &self.merge.regions {
            let tall = self
                .shown()
                .iter()
                .map(|&p| range(r, p).len())
                .max()
                .unwrap_or(0);
            v += tall as f64;
            self.virt.push(v);
        }
        let most = self.panes.iter().map(PaneText::len).max().unwrap_or(0);
        self.digits = most.to_string().len().max(3);
        self.widest = self
            .panes
            .iter()
            .flat_map(|p| (0..p.len()).map(|i| columns(p.line(i))))
            .max()
            .unwrap_or(0);
        self.clamp();
    }

    // ---- geometry ---------------------------------------------------------------------------

    fn line_h(&self) -> f64 {
        f64::from(self.metrics.cell.h)
    }

    /// The panes' band below their headers, in the host's points.
    fn body(&self) -> Rect {
        let h = self.metrics.header_height;
        Rect::new(
            self.origin.x,
            self.origin.y + h,
            self.size.w,
            (self.size.h - h).max(0.0),
        )
    }

    fn gap_w(&self) -> f32 {
        40.0 * self.k()
    }

    fn strip_w(&self) -> f32 {
        8.0 * self.k()
    }

    fn pane_w(&self) -> f32 {
        let n = self.shown().len() as f32;
        ((self.size.w - (n - 1.0) * self.gap_w() - self.strip_w()) / n).max(0.0)
    }

    /// Shown pane `i`'s left edge.
    fn pane_x(&self, i: usize) -> f32 {
        self.origin.x + i as f32 * (self.pane_w() + self.gap_w())
    }

    fn gutter_cols(&self) -> u16 {
        self.digits as u16 + 2
    }

    /// Where a pane's code starts, from its left edge.
    pub fn code_x(&self) -> f32 {
        f32::from(self.gutter_cols()) * self.metrics.cell.w
    }

    /// The whole layout's height in points.
    pub fn height(&self) -> f64 {
        self.virt.last().copied().unwrap_or(0.0) * self.line_h()
    }

    pub fn top(&self) -> f64 {
        self.scroll
    }

    pub fn max_top(&self) -> f64 {
        (self.height() - f64::from(self.body().h)).max(0.0)
    }

    fn max_left(&self) -> f32 {
        let code_w = self.pane_w() - self.code_x();
        (self.widest as f32 * self.metrics.cell.w + 24.0 * self.k() - code_w).max(0.0)
    }

    fn clamp(&mut self) {
        self.scroll = self.scroll.clamp(0.0, self.max_top());
        self.left = self.left.clamp(0.0, self.max_left());
    }

    /// Scroll by points (a gesture's delta: positive moves toward the end and right).
    pub fn scroll_by(&mut self, dx: f32, dy: f64) {
        self.scroll += dy;
        self.left += dx;
        self.clamp();
    }

    pub fn set_top(&mut self, y: f64) {
        self.scroll = y;
        self.clamp();
    }

    /// Where the view's centre is, in the layout's lines.
    fn center_line(&self) -> f64 {
        (self.scroll + f64::from(self.body().h) / 2.0) / self.line_h()
    }

    fn set_center_line(&mut self, line: f64) {
        self.scroll = line * self.line_h() - f64::from(self.body().h) / 2.0;
        self.clamp();
    }

    /// The region at layout line `v`: the first whose stretch reaches past it.
    fn region_at_virt(&self, v: f64) -> usize {
        let n = self.merge.regions.len();
        self.virt[1..]
            .partition_point(|&end| end <= v)
            .min(n.saturating_sub(1))
    }

    /// `pane`'s line (fractional) at layout line `v`: through a region, its share of the
    /// region's height.
    fn pane_line(&self, pane: MergePane, v: f64) -> f64 {
        let n = self.merge.regions.len();
        if n == 0 {
            return v;
        }
        let v = v.clamp(0.0, self.virt[n]);
        let k = self.region_at_virt(v);
        let r = range(&self.merge.regions[k], pane);
        let tall = self.virt[k + 1] - self.virt[k];
        let into = match tall > 0.0 {
            true => (v - self.virt[k]) * r.len() as f64 / tall,
            false => 0.0,
        };
        r.start as f64 + into
    }

    /// `pane`'s scroll in points: its line at the view's centre is the layout's.
    pub fn pane_top(&self, pane: MergePane) -> f64 {
        let h = f64::from(self.body().h);
        let y = self.pane_line(pane, self.center_line()) * self.line_h() - h / 2.0;
        let most = (self.panes[pane.index()].len() as f64 * self.line_h() - h).max(0.0);
        y.clamp(0.0, most)
    }

    /// `pane`'s lines in view.
    fn lines_in_view(&self, pane: MergePane, top: f64) -> Range<usize> {
        let lh = self.line_h();
        let len = self.panes[pane.index()].len();
        let first = (top / lh).floor().max(0.0) as usize;
        let last = ((top + f64::from(self.body().h)) / lh).ceil().max(0.0) as usize;
        first.min(len)..last.min(len)
    }

    /// The regions whose stretch in `pane` meets lines `lines` (an empty stretch at either edge
    /// included).
    fn regions_meeting(&self, pane: MergePane, lines: &Range<usize>) -> Range<usize> {
        let regions = &self.merge.regions;
        let a = regions.partition_point(|r| range(r, pane).end < lines.start);
        let b = regions.partition_point(|r| range(r, pane).start <= lines.end);
        a..b.max(a)
    }

    /// The region holding `pane`'s line `line`.
    pub fn region_at(&self, pane: MergePane, line: usize) -> Option<usize> {
        let regions = &self.merge.regions;
        let k = regions.partition_point(|r| range(r, pane).end <= line);
        (k < regions.len() && range(&regions[k], pane).contains(&line)).then_some(k)
    }

    // ---- regions and ⇥ ----------------------------------------------------------------------

    /// The regions ⇥ stops at: conflicts, resolutions and a past merge's own decisions.
    pub fn stops(&self) -> impl Iterator<Item = usize> + '_ {
        self.merge.regions.iter().enumerate().filter_map(|(k, r)| {
            (matches!(r.kind, RegionKind::Conflict | RegionKind::Resolved) || r.committed.is_some())
                .then_some(k)
        })
    }

    pub fn current(&self) -> Option<usize> {
        self.current
    }

    pub fn select(&mut self, region: Option<usize>) {
        self.current = region.filter(|&k| k < self.merge.regions.len());
    }

    /// ⇥ (`forward`) or ⇧⇥: the next stop after the current one, wrapping; from none, the
    /// first at or past the view's top.
    pub fn step(&mut self, forward: bool) -> Option<usize> {
        let stops: Vec<usize> = self.stops().collect();
        let (first, last) = (*stops.first()?, *stops.last()?);
        let from = self
            .current
            .unwrap_or_else(|| self.region_at_virt(self.scroll / self.line_h()));
        let next = match (forward, self.current.is_some()) {
            (true, true) => stops.iter().find(|&&k| k > from).copied().unwrap_or(first),
            (true, false) => stops.iter().find(|&&k| k >= from).copied().unwrap_or(first),
            (false, _) => stops
                .iter()
                .rev()
                .find(|&&k| k < from)
                .copied()
                .unwrap_or(last),
        };
        self.current = Some(next);
        Some(next)
    }

    /// The scroll that puts region `k` a third of the way down.
    pub fn region_top(&self, k: usize) -> Option<f64> {
        let v = *self.virt.get(k)?;
        let y = v * self.line_h() - f64::from(self.body().h) / 3.0;
        Some(y.clamp(0.0, self.max_top()))
    }

    // ---- hit-testing --------------------------------------------------------------------------

    /// What view point `p` (the host's points) is over.
    pub fn hit(&self, p: Point) -> MergeHit {
        let (x, y) = (p.x - self.origin.x, p.y);
        if p.y < self.origin.y || p.y >= self.origin.y + self.size.h || x < 0.0 {
            return MergeHit::None;
        }
        let (pane_w, gap) = (self.pane_w(), self.gap_w());
        let i = (x / (pane_w + gap)).floor() as usize;
        let shown = self.shown();
        let Some(&pane) = shown.get(i) else {
            return MergeHit::None;
        };
        let into = x - i as f32 * (pane_w + gap);
        if into <= pane_w {
            if y < self.body().y {
                return MergeHit::Header(pane);
            }
            let top = self.pane_top(pane);
            let line = ((f64::from(y - self.body().y) + top) / self.line_h()).floor() as usize;
            if line >= self.panes[pane.index()].len() {
                return MergeHit::None;
            }
            return MergeHit::Line {
                pane,
                line,
                region: self.region_at(pane, line),
            };
        }
        // A gap: the ribbon whose band holds y where x crosses it.
        let Some(&right) = shown.get(i + 1) else {
            return MergeHit::None;
        };
        let t = f64::from((into - pane_w) / gap);
        let ease = t * t * (3.0 - 2.0 * t);
        let (ta, tb) = (self.pane_top(pane), self.pane_top(right));
        let y = f64::from(y - self.body().y);
        let lh = self.line_h();
        let lines = self.lines_in_view(pane, ta);
        for k in self.regions_meeting(pane, &lines) {
            let r = &self.merge.regions[k];
            if r.kind == RegionKind::Unchanged {
                continue;
            }
            let (a, b) = (range(r, pane), range(r, right));
            let at = |sa: usize, sb: usize| {
                let (ya, yb) = (sa as f64 * lh - ta, sb as f64 * lh - tb);
                ya + (yb - ya) * ease
            };
            let (lo, hi) = (at(a.start, b.start), at(a.end, b.end));
            if y >= lo - 2.0 && y <= hi + 2.0 {
                return MergeHit::Ribbon { region: k };
            }
        }
        MergeHit::None
    }

    /// Each shown pane's title and lines in view: the panel driver's reading of the screen.
    pub fn visible_text(&self) -> String {
        let mut out = String::new();
        for &pane in self.shown() {
            let p = &self.panes[pane.index()];
            let _ = writeln!(out, "── {}", self.labels[pane.index()]);
            for i in self.lines_in_view(pane, self.pane_top(pane)) {
                out.push_str(p.line(i));
                out.push('\n');
            }
        }
        out
    }

    /// The camera the host's target draws the ribbons through: it follows the scroll.
    pub fn camera(&self) -> Camera {
        Camera {
            scale: Point::new(1.0, 1.0),
            offset: Point::new(0.0, -self.scroll as f32),
        }
    }

    // ---- painting -----------------------------------------------------------------------------

    /// A region's tone: what decided it.
    fn tone(r: &Region, colors: &CodeColors) -> Option<Rgba> {
        Tone::of(r).map(|t| t.color(colors))
    }

    /// The panes, the ribbons and the region strip into `out`; `accent` rings the current
    /// region.
    pub fn paint(&mut self, colors: &CodeColors, accent: Rgba, out: &mut Vec<Op>) {
        self.used = 0;
        let view = Rect::new(self.origin.x, self.origin.y, self.size.w, self.size.h);
        out.push(Op::PushClip(view));
        let shown = self.shown();
        for (i, &pane) in shown.iter().enumerate() {
            self.paint_pane(i, pane, colors, accent, out);
        }
        out.push(Op::PushCamera(Follow::Y));
        for (i, pair) in shown.windows(2).enumerate() {
            self.paint_ribbons(i, pair[0], pair[1], colors, accent, out);
        }
        out.push(Op::PopCamera);
        self.paint_strip(colors, out);
        out.push(Op::PopClip);
    }

    /// A pooled block, emptied, whose rows the last frame's renderer no longer holds.
    fn block(&mut self) -> usize {
        if self.used == self.pool.len() {
            self.pool.push(Arc::new(CodeRows::default()));
        }
        let k = self.used;
        if Arc::get_mut(&mut self.pool[k]).is_none() {
            self.pool[k] = Arc::new(CodeRows::default());
        }
        Arc::get_mut(&mut self.pool[k])
            .expect("a fresh block is unshared")
            .clear();
        self.used += 1;
        k
    }

    fn code_op(&self, k: usize, origin: Point, cell: Size) -> Op {
        Op::Code(CodeBlock {
            origin,
            cell,
            font_size: self.metrics.font_size,
            rows: self.pool[k].clone(),
        })
    }

    fn paint_pane(
        &mut self,
        i: usize,
        pane: MergePane,
        colors: &CodeColors,
        accent: Rgba,
        out: &mut Vec<Op>,
    ) {
        let (m, p) = (self.metrics, *colors.palette());
        let (x, w, body) = (self.pane_x(i), self.pane_w(), self.body());
        // The header: a band and the pane's title.
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(x, self.origin.y, w, m.header_height),
            0.0,
            rgba(p.header),
        )));
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(x, self.origin.y + m.header_height - 1.0, w, 1.0),
            0.0,
            rgba(p.border),
        )));
        let mut title = TextRun::new(
            self.labels[pane.index()].as_str(),
            Point::new(
                x + 10.0 * self.k(),
                self.origin.y + (m.header_height - m.note_size * 1.25) / 2.0,
            ),
            m.note_size,
            colors.fg(),
        );
        title.max_width = Some((w - 20.0 * self.k()).max(0.0));
        out.push(Op::Text(title));
        out.push(Op::PushClip(Rect::new(x, body.y, w, body.h)));
        let top = self.pane_top(pane);
        let lines = self.lines_in_view(pane, top);
        let lh = self.line_h();
        let y0 = body.y + (lines.start as f64 * lh - top) as f32;
        let (gutter, code) = (self.block(), self.block());
        let fill_cols = ((w + self.left) / m.cell.w.max(0.1))
            .ceil()
            .min(f32::from(u16::MAX)) as u16;
        let gutter_cols = self.gutter_cols();
        let digits = self.digits;
        for line in lines.clone() {
            let region = self.region_at(pane, line);
            let wash = region.and_then(|k| {
                let r = &self.merge.regions[k];
                let alpha = if self.current == Some(k) { 0.26 } else { 0.13 };
                Self::tone(r, colors).map(|t| t.with_alpha(alpha))
            });
            // Gutter: the line's number on its region's wash.
            self.text.clear();
            let _ = write!(self.text, " {:>digits$} ", line + 1);
            place(&self.text, &mut self.cols);
            let rows = Arc::get_mut(&mut self.pool[gutter]).expect("unshared while filled");
            rows.fg = rgba(p.line_number);
            let r = rows.rows.len() as u32;
            rows.push_row(&self.text, &self.cols);
            rows.backgrounds
                .push(span(r, 0, gutter_cols, rgba(p.gutter)));
            if let Some(wash) = wash {
                rows.backgrounds.push(span(r, 0, gutter_cols, wash));
            }
            // Code: the line's chars, coloured by the pane's highlights.
            let text = self.panes[pane.index()].line(line);
            place(text, &mut self.cols);
            // Each byte's column, the end column past the last.
            self.byte_cols.clear();
            for ((at, c), &col) in text.char_indices().zip(&self.cols) {
                debug_assert_eq!(self.byte_cols.len(), at);
                self.byte_cols
                    .extend(std::iter::repeat_n(col, c.len_utf8()));
            }
            self.byte_cols.push(*self.cols.last().unwrap_or(&0));
            let rows = Arc::get_mut(&mut self.pool[code]).expect("unshared while filled");
            rows.fg = colors.fg();
            let r = rows.rows.len() as u32;
            rows.push_row(text, &self.cols);
            if let Some(wash) = wash {
                rows.backgrounds.push(span(r, 0, fill_cols, wash));
            }
            if let Some(tokens) = &self.tokens[pane.index()]
                && line < tokens.line_count()
            {
                let col = |byte: usize| self.byte_cols[byte.min(text.len())];
                for run in tokens.runs(line) {
                    let (a, b) = (col(run.start as usize), col((run.start + run.len) as usize));
                    if a < b {
                        rows.push_styled_span(a, b, colors.role(run.role), colors.face(run.role));
                    }
                }
            }
        }
        out.push(self.code_op(gutter, Point::new(x, y0), m.cell));
        let code_x = x + self.code_x();
        out.push(Op::PushClip(Rect::new(
            code_x,
            body.y,
            (x + w - code_x).max(0.0),
            body.h,
        )));
        out.push(self.code_op(code, Point::new(code_x - self.left, y0), m.cell));
        out.push(Op::PopClip);
        // An empty stretch is a rule across the pane; the current region's lines get a bar.
        let k = self.k();
        for r in self.regions_meeting(pane, &lines) {
            let region = &self.merge.regions[r];
            let span_r = range(region, pane);
            let Some(tone) = Self::tone(region, colors) else {
                continue;
            };
            let ya = body.y + (span_r.start as f64 * lh - top) as f32;
            if span_r.is_empty() {
                let alpha = if self.current == Some(r) { 1.0 } else { 0.7 };
                out.push(Op::Rect(RoundedRect::new(
                    Rect::new(x, ya - 1.0 * k, w, 2.0 * k),
                    0.0,
                    tone.with_alpha(alpha),
                )));
            }
            if self.current == Some(r) {
                let h = (span_r.len() as f64 * lh) as f32;
                out.push(Op::Rect(RoundedRect::new(
                    Rect::new(
                        x,
                        ya - if h == 0.0 { 3.0 * k } else { 0.0 },
                        3.0 * k,
                        h.max(6.0 * k),
                    ),
                    0.0,
                    accent,
                )));
            }
        }
        out.push(Op::PopClip);
    }

    /// The ribbons of gap `gap` between panes `a` and `b`, in world points (the camera
    /// layer adds the scroll back).
    fn paint_ribbons(
        &mut self,
        gap: usize,
        a: MergePane,
        b: MergePane,
        colors: &CodeColors,
        accent: Rgba,
        out: &mut Vec<Op>,
    ) {
        let body = self.body();
        let xa = self.pane_x(gap) + self.pane_w();
        let xb = xa + self.gap_w();
        out.push(Op::PushClip(Rect::new(xa, body.y, xb - xa, body.h)));
        let (ta, tb) = (self.pane_top(a), self.pane_top(b));
        let (la, lb) = (self.lines_in_view(a, ta), self.lines_in_view(b, tb));
        let (ra, rb) = (self.regions_meeting(a, &la), self.regions_meeting(b, &lb));
        let lh = self.line_h();
        let world = |line: usize, top: f64| body.y as f64 + line as f64 * lh - top + self.scroll;
        let q = |v: f64| (v * 64.0).round() as i32;
        let k = self.k();
        for r in ra.start.min(rb.start)..ra.end.max(rb.end) {
            let region = &self.merge.regions[r];
            let Some(tone) = Self::tone(region, colors) else {
                continue;
            };
            let (sa, sb) = (range(region, a), range(region, b));
            // Each end at least a hairline thick, so an empty stretch still shows where it goes.
            let ends = |s: &Range<usize>, top: f64| {
                let (y0, y1) = (world(s.start, top), world(s.end, top));
                let half = f64::from(0.75 * k);
                match y1 - y0 < 2.0 * half {
                    true => ((y0 + y1) / 2.0 - half, (y0 + y1) / 2.0 + half),
                    false => (y0, y1),
                }
            };
            let ((ya0, ya1), (yb0, yb1)) = (ends(sa, ta), ends(sb, tb));
            let key = [
                q(f64::from(xa)),
                q(f64::from(xb)),
                q(ya0),
                q(ya1),
                q(yb0),
                q(yb1),
            ];
            let slot = 3 * r + gap.min(2);
            let path = match &self.ribbons[slot] {
                Some((was, path)) if *was == key => path.clone(),
                _ => {
                    let snap = |v: f64| ((v * 64.0).round() / 64.0) as f32;
                    let xm = (xa + xb) / 2.0;
                    let mut p = Path::new();
                    p.move_to(Point::new(xa, snap(ya0)))
                        .cubic_to(
                            Point::new(xm, snap(ya0)),
                            Point::new(xm, snap(yb0)),
                            Point::new(xb, snap(yb0)),
                        )
                        .line_to(Point::new(xb, snap(yb1)))
                        .cubic_to(
                            Point::new(xm, snap(yb1)),
                            Point::new(xm, snap(ya1)),
                            Point::new(xa, snap(ya1)),
                        )
                        .close();
                    let path = Arc::new(p);
                    self.ribbons[slot] = Some((key, path.clone()));
                    path
                }
            };
            let alpha = if self.current == Some(r) { 0.42 } else { 0.22 };
            out.push(Op::Path(PathOp::fill(path.clone(), tone.with_alpha(alpha))));
            if self.current == Some(r) {
                out.push(Op::Path(PathOp::stroke(path, Stroke::new(1.5 * k, accent))));
            }
        }
        out.push(Op::PopClip);
    }

    /// Every changed region over the whole file as a tick at the right, with the view's span.
    fn paint_strip(&mut self, colors: &CodeColors, out: &mut Vec<Op>) {
        let body = self.body();
        let total = self.virt.last().copied().unwrap_or(0.0);
        if total <= 0.0 || body.h <= 0.0 {
            return;
        }
        let (k, w) = (self.k(), self.strip_w());
        let x = self.origin.x + self.size.w - w;
        let p = colors.palette();
        let scale = f64::from(body.h) / total;
        let span = f64::from(body.h) / (total * self.line_h()).max(1.0) * f64::from(body.h);
        out.push(Op::Rect(RoundedRect::new(
            Rect::new(
                x,
                body.y + (self.scroll / (total * self.line_h()) * f64::from(body.h)) as f32,
                w,
                (span as f32).min(body.h),
            ),
            1.5 * k,
            rgba(p.line_number).with_alpha(0.18),
        )));
        if self.strip_h != body.h {
            self.strip_h = body.h;
            self.strip.clear();
            for (r, region) in self.merge.regions.iter().enumerate() {
                let Some(tone) = Tone::of(region) else {
                    continue;
                };
                let y = (self.virt[r] * scale) as f32;
                let h = (((self.virt[r + 1] - self.virt[r]) * scale) as f32).max(2.0 * k);
                // Ticks of one tone a point apart or closer draw as one.
                match self.strip.last_mut() {
                    Some((ly, lh, lt)) if *lt == tone && y <= *ly + *lh + 1.0 => {
                        *lh = (y + h - *ly).max(*lh)
                    }
                    _ => self.strip.push((y, h, tone)),
                }
            }
        }
        for &(y, h, tone) in &self.strip {
            out.push(Op::Rect(RoundedRect::new(
                Rect::new(x + 1.5 * k, body.y + y, w - 3.0 * k, h),
                0.0,
                tone.color(colors),
            )));
        }
    }
}

/// What decided a region, as its colour reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tone {
    /// One side changed it, or both alike.
    Changed,
    Resolved,
    Conflict,
    /// A past merge's commit decided it otherwise than the engine.
    Committed,
}

impl Tone {
    fn of(r: &Region) -> Option<Tone> {
        if r.committed.is_some() {
            return Some(Tone::Committed);
        }
        Some(match r.kind {
            RegionKind::Unchanged => return None,
            RegionKind::Ours | RegionKind::Theirs | RegionKind::Both => Tone::Changed,
            RegionKind::Resolved => Tone::Resolved,
            RegionKind::Conflict => Tone::Conflict,
        })
    }

    fn color(self, colors: &CodeColors) -> Rgba {
        let p = colors.palette();
        rgba(match self {
            Tone::Changed => p.info,
            Tone::Resolved => p.added_mark,
            Tone::Conflict => p.error,
            Tone::Committed => p.warning,
        })
    }
}

fn span(row: u32, start: u16, end: u16, color: Rgba) -> CellSpan {
    CellSpan {
        row,
        start,
        end,
        color,
    }
}

/// Each char of `text`'s column from 0, then the end column, into `cols`.
fn place(text: &str, cols: &mut Vec<u16>) {
    cols.clear();
    let mut placer = Placer::new(None);
    let mut end = 0;
    for c in text.chars() {
        let p = placer.place(c);
        cols.push(p.x.min(u32::from(u16::MAX)) as u16);
        end = (p.x + p.width).min(u32::from(u16::MAX)) as u16;
    }
    cols.push(end);
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_core::syntax::Language;

    /// 100 lines; ours inserts ten after line 20, theirs edits line 40, both edit line 60
    /// alike word for word (a conflict) and different words of line 80 (resolved).
    fn view() -> MergeView {
        let line = |i: usize| match i {
            60 => "let shared = 60;\n".to_owned(),
            80 => "let a = b;\n".to_owned(),
            _ => format!("line {i}\n"),
        };
        let base: String = (0..100).map(line).collect();
        let ours: String = (0..100)
            .flat_map(|i| {
                let mut v = vec![match i {
                    60 => "let shared = 61;\n".to_owned(),
                    80 => "let a2 = b;\n".to_owned(),
                    _ => line(i),
                }];
                if i == 19 {
                    v.extend((0..10).map(|j| format!("ours {j}\n")));
                }
                v
            })
            .collect();
        let theirs: String = (0..100)
            .map(|i| match i {
                40 => "theirs 40\n".to_owned(),
                60 => "let shared = 62;\n".to_owned(),
                80 => "let a = b2;\n".to_owned(),
                _ => line(i),
            })
            .collect();
        let merge = Merge::new(&base, &ours, &theirs, Some(Language::Rust));
        let metrics = DiffMetrics::for_cell(Size::new(7.0, 18.0), 12.0);
        let mut v = MergeView::new(&base, &ours, &theirs, merge, metrics);
        // A 20-line body under the 30 pt headers.
        v.resize(Size::new(900.0, 30.0 + 20.0 * 18.0));
        v
    }

    fn kinds(v: &MergeView) -> Vec<RegionKind> {
        v.merge().regions.iter().map(|r| r.kind).collect()
    }

    #[test]
    fn panes_keep_step_through_unchanged_lines_and_a_side_scrolls_on_through_its_insertion() {
        use RegionKind::*;
        let mut v = view();
        assert_eq!(
            kinds(&v),
            [
                Unchanged, Ours, Unchanged, Theirs, Unchanged, Conflict, Unchanged, Resolved,
                Unchanged
            ]
        );
        // The centre (line 10) is in the first stretch: every pane at the top.
        for &p in v.shown() {
            assert_eq!(v.pane_top(p), 0.0);
        }
        // Halfway through ours' ten new lines: ours and the result move on, theirs waits.
        v.set_top(25.0 * 18.0 - 180.0);
        assert_eq!(v.pane_top(MergePane::Ours), 25.0 * 18.0 - 180.0);
        assert_eq!(v.pane_top(MergePane::Result), 25.0 * 18.0 - 180.0);
        assert_eq!(v.pane_top(MergePane::Theirs), 20.0 * 18.0 - 180.0);
        // Past them, all three move together again, theirs ten lines behind.
        v.scroll_by(0.0, 10.0 * 18.0);
        let gap = v.pane_top(MergePane::Ours) - v.pane_top(MergePane::Theirs);
        assert_eq!(gap, 10.0 * 18.0);
        v.scroll_by(0.0, 18.0);
        assert_eq!(
            v.pane_top(MergePane::Ours) - v.pane_top(MergePane::Theirs),
            gap
        );
    }

    #[test]
    fn a_line_hits_its_region_and_a_gap_hits_the_ribbon_crossing_it() {
        let mut v = view();
        v.set_top(25.0 * 18.0 - 180.0);
        let body = v.body();
        let result_x = v.pane_x(1) + 100.0;
        // Ours' inserted lines sit at 90..270 pt into the body in ours and the result.
        let hit = v.hit(Point::new(result_x, body.y + 100.0));
        assert_eq!(
            hit,
            MergeHit::Line {
                pane: MergePane::Result,
                line: 20,
                region: Some(1)
            }
        );
        let gap_x = v.pane_x(0) + v.pane_w() + v.gap_w() / 2.0;
        assert_eq!(
            v.hit(Point::new(gap_x, body.y + 180.0)),
            MergeHit::Ribbon { region: 1 }
        );
        assert_eq!(
            v.hit(Point::new(result_x, 5.0)),
            MergeHit::Header(MergePane::Result)
        );
    }

    #[test]
    fn tab_walks_the_conflict_and_the_resolution_and_wraps() {
        let mut v = view();
        assert_eq!(v.stops().collect::<Vec<_>>(), [5, 7]);
        assert_eq!(v.step(true), Some(5));
        assert_eq!(v.step(true), Some(7));
        assert_eq!(v.step(true), Some(5));
        assert_eq!(v.step(false), Some(7));
        let top = v.region_top(7).unwrap();
        v.set_top(top);
        assert!(v.visible_text().contains("let a2 = b2;"));
    }

    #[test]
    fn the_merge_base_joins_at_the_left_keeping_the_stretch_at_the_centre() {
        let mut v = view();
        v.set_top(40.0 * 18.0);
        let center = v.center_line();
        v.set_shows_base(true);
        assert_eq!(v.shown()[0], MergePane::Base);
        assert!((v.center_line() - center).abs() < 1e-9);
        assert!(matches!(
            v.hit(Point::new(v.pane_x(0) + 100.0, v.body().y + 1.0)),
            MergeHit::Line {
                pane: MergePane::Base,
                ..
            }
        ));
    }

    #[test]
    fn a_ribbon_is_built_once_while_the_panes_move_together() {
        let mut v = view();
        let colors = CodeColors::new(theme::default_theme());
        let accent = Rgba::new(1.0, 0.6, 0.0, 1.0);
        // The centre past ours' insertion (layout lines 30..50 are one unchanged stretch).
        v.set_top(32.0 * 18.0 - 180.0);
        let mut ops = Vec::new();
        v.paint(&colors, accent, &mut ops);
        let first = v.ribbons[3].clone().expect("region 1's ribbon in gap 0").1;
        ops.clear();
        v.scroll_by(0.0, 18.0);
        v.paint(&colors, accent, &mut ops);
        let again = v.ribbons[3].clone().expect("still in view").1;
        assert!(Arc::ptr_eq(&first, &again));
        assert!(
            ops.iter()
                .any(|op| matches!(op, Op::PushCamera(f) if *f == Follow::Y))
        );
    }
}
