//! The merge's C ABI (vt-7968): Pultík's merge preview, drawn by `canvas_text::merge_view` — the
//! merge view both apps draw with — on the shared device. Swift hands it one file's merge base,
//! ours and theirs (and, for a past merge, what the commit committed), each pane's highlights as
//! they land, the panes' titles and the gestures; the engine merges (`code_core::merge`), lays
//! the panes out, scrolls them in step (a key's jump eases), draws the ribbons, walks ⇥ and
//! hit-tests. Points are the view's, from its top-left. It answers each region and why, in
//! Pultík's words ([`reason`]).

use super::{
    CanvasFrameReport, CanvasRgba, CanvasStatus, CanvasStr, Failure, Surface, call, owned, slice,
};
use crate::diff::{
    CANVAS_DIFF_STEP_EDGE, CANVAS_DIFF_STEP_LINE, CANVAS_DIFF_STEP_PAGE, GLIDE, LINE_HEIGHT,
    byte_of, colors, metrics,
};
use canvas_draw::{DisplayList, Point, Rgba, Size};
use canvas_gpu::FrameOutcome;
use canvas_text::code_view::CodeColors;
use canvas_text::diff_view::DiffMetrics;
use canvas_text::merge_view::{MergeHit, MergePane, MergeView};
use code_core::merge::{Committed, Merge, Region, RegionKind, Resolution, ResolutionKind, Side};
use code_core::syntax::{Language, LineTokens, TokenRun};
use std::ffi::{c_char, c_void};
use std::time::Instant;
use theme::SyntaxRole;

/// A pane, left to right (the base is shown on demand).
pub const CANVAS_MERGE_PANE_BASE: u8 = 0;
pub const CANVAS_MERGE_PANE_OURS: u8 = 1;
pub const CANVAS_MERGE_PANE_RESULT: u8 = 2;
pub const CANVAS_MERGE_PANE_THEIRS: u8 = 3;

/// What a region of the result is (`code_core::merge::RegionKind`).
pub const CANVAS_MERGE_REGION_UNCHANGED: u8 = 0;
pub const CANVAS_MERGE_REGION_OURS: u8 = 1;
pub const CANVAS_MERGE_REGION_THEIRS: u8 = 2;
pub const CANVAS_MERGE_REGION_BOTH: u8 = 3;
pub const CANVAS_MERGE_REGION_RESOLVED: u8 = 4;
pub const CANVAS_MERGE_REGION_CONFLICT: u8 = 5;

/// How a resolver merged a conflict (`ResolutionKind`); NONE on every other region.
pub const CANVAS_MERGE_RESOLUTION_NONE: u8 = 0;
pub const CANVAS_MERGE_RESOLUTION_IMPORTS: u8 = 1;
pub const CANVAS_MERGE_RESOLUTION_BOTH_ADDED: u8 = 2;
pub const CANVAS_MERGE_RESOLUTION_LINES: u8 = 3;
pub const CANVAS_MERGE_RESOLUTION_WORDS: u8 = 4;
pub const CANVAS_MERGE_RESOLUTION_REORDERED: u8 = 5;

/// What a past merge's commit took where it differs from the engine (`Committed`).
pub const CANVAS_MERGE_COMMITTED_NONE: u8 = 0;
pub const CANVAS_MERGE_COMMITTED_OURS: u8 = 1;
pub const CANVAS_MERGE_COMMITTED_THEIRS: u8 = 2;
pub const CANVAS_MERGE_COMMITTED_BASE: u8 = 3;
pub const CANVAS_MERGE_COMMITTED_HAND: u8 = 4;

pub const CANVAS_MERGE_HIT_NONE: u8 = 0;
pub const CANVAS_MERGE_HIT_HEADER: u8 = 1;
pub const CANVAS_MERGE_HIT_LINE: u8 = 2;
pub const CANVAS_MERGE_HIT_RIBBON: u8 = 3;

/// One region: its kind, how it was resolved or committed, and its lines (0-based,
/// end-exclusive) in each text.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CanvasMergeRegion {
    /// A CANVAS_MERGE_REGION_*.
    pub kind: u8,
    /// A CANVAS_MERGE_RESOLUTION_*.
    pub resolution: u8,
    /// A CANVAS_MERGE_COMMITTED_*.
    pub committed: u8,
    pub base_start: u32,
    pub base_end: u32,
    pub ours_start: u32,
    pub ours_end: u32,
    pub theirs_start: u32,
    pub theirs_end: u32,
    pub result_start: u32,
    pub result_end: u32,
}

/// What a point is over: a CANVAS_MERGE_HIT_* `kind`, its pane (header and line hits), the
/// line, and the region (-1: none).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CanvasMergeHit {
    pub kind: u8,
    pub pane: u8,
    pub line: u32,
    pub region: i64,
}

impl Default for CanvasMergeHit {
    fn default() -> Self {
        Self {
            kind: CANVAS_MERGE_HIT_NONE,
            pane: 0,
            line: 0,
            region: -1,
        }
    }
}

/// Where the merge is: its regions, the conflicts left and the resolutions, the region ⇥ is
/// on (-1: none), the scroll and the layout's height in points, the panes with highlights, and
/// whether the base pane shows.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CanvasMergeState {
    pub regions: u32,
    pub conflicts: u32,
    pub resolved: u32,
    /// Regions a past merge's commit decided differently from the engine.
    pub committed: u32,
    pub current: i64,
    pub top: f64,
    pub height: f64,
    pub highlighted: u32,
    pub shows_base: bool,
}

/// An eased jump in flight.
struct Glide {
    from: f64,
    to: f64,
    start: Instant,
}

/// One merge on screen.
pub struct CanvasMerge {
    view: MergeView,
    colors: CodeColors,
    accent: Rgba,
    font_size: f32,
    renderer: Option<Surface>,
    dl: DisplayList,
    glide: Option<Glide>,
    dirty: bool,
    built_at: u64,
}

/// # Safety
/// `h` is null (refused) or a live merge handle used by this thread alone.
unsafe fn merge<'a>(h: *mut CanvasMerge) -> Result<&'a mut CanvasMerge, Failure> {
    // SAFETY: per this function's contract.
    unsafe { h.as_mut() }.ok_or(Failure::Invalid("a null merge handle"))
}

fn pane(code: u8) -> Result<MergePane, Failure> {
    Ok(match code {
        CANVAS_MERGE_PANE_BASE => MergePane::Base,
        CANVAS_MERGE_PANE_OURS => MergePane::Ours,
        CANVAS_MERGE_PANE_RESULT => MergePane::Result,
        CANVAS_MERGE_PANE_THEIRS => MergePane::Theirs,
        _ => return Err(Failure::Invalid("an unknown pane")),
    })
}

fn pane_code(pane: MergePane) -> u8 {
    match pane {
        MergePane::Base => CANVAS_MERGE_PANE_BASE,
        MergePane::Ours => CANVAS_MERGE_PANE_OURS,
        MergePane::Result => CANVAS_MERGE_PANE_RESULT,
        MergePane::Theirs => CANVAS_MERGE_PANE_THEIRS,
    }
}

fn region_of(r: &Region) -> CanvasMergeRegion {
    let at = |n: usize| n as u32;
    CanvasMergeRegion {
        kind: match r.kind {
            RegionKind::Unchanged => CANVAS_MERGE_REGION_UNCHANGED,
            RegionKind::Ours => CANVAS_MERGE_REGION_OURS,
            RegionKind::Theirs => CANVAS_MERGE_REGION_THEIRS,
            RegionKind::Both => CANVAS_MERGE_REGION_BOTH,
            RegionKind::Resolved => CANVAS_MERGE_REGION_RESOLVED,
            RegionKind::Conflict => CANVAS_MERGE_REGION_CONFLICT,
        },
        resolution: match r.resolution.as_ref().map(|r| r.kind) {
            None => CANVAS_MERGE_RESOLUTION_NONE,
            Some(ResolutionKind::Imports) => CANVAS_MERGE_RESOLUTION_IMPORTS,
            Some(ResolutionKind::BothAdded) => CANVAS_MERGE_RESOLUTION_BOTH_ADDED,
            Some(ResolutionKind::Lines) => CANVAS_MERGE_RESOLUTION_LINES,
            Some(ResolutionKind::Words) => CANVAS_MERGE_RESOLUTION_WORDS,
            Some(ResolutionKind::Reordered) => CANVAS_MERGE_RESOLUTION_REORDERED,
        },
        committed: match r.committed {
            None => CANVAS_MERGE_COMMITTED_NONE,
            Some(Committed::Ours) => CANVAS_MERGE_COMMITTED_OURS,
            Some(Committed::Theirs) => CANVAS_MERGE_COMMITTED_THEIRS,
            Some(Committed::Base) => CANVAS_MERGE_COMMITTED_BASE,
            Some(Committed::Hand) => CANVAS_MERGE_COMMITTED_HAND,
        },
        base_start: at(r.base.start),
        base_end: at(r.base.end),
        ours_start: at(r.ours.start),
        ours_end: at(r.ours.end),
        theirs_start: at(r.theirs.start),
        theirs_end: at(r.theirs.end),
        result_start: at(r.result.start),
        result_end: at(r.result.end),
    }
}

/// Why a region reads as it does, in Pultík's words: what changed it, how a resolver merged it,
/// or what a past merge's commit took.
pub fn reason(r: &Region) -> String {
    let within = |res: &Resolution| {
        res.scope
            .as_deref()
            .map_or_else(String::new, |s| format!(" in `{s}`"))
    };
    if let Some(c) = r.committed {
        return match c {
            Committed::Ours => "The merge commit took ours here",
            Committed::Theirs => "The merge commit took theirs here",
            Committed::Base => "The merge commit kept the base here",
            Committed::Hand => "The merge commit wrote its own lines here",
        }
        .into();
    }
    match (r.kind, &r.resolution) {
        (RegionKind::Unchanged, _) => "Neither side changed this".into(),
        (RegionKind::Ours, _) => "Only ours changed this".into(),
        (RegionKind::Theirs, _) => "Only theirs changed this".into(),
        (RegionKind::Both, _) => "Both sides made this change".into(),
        (RegionKind::Conflict, _) => "Both sides changed these lines differently".into(),
        (RegionKind::Resolved, None) => "Merged".into(),
        (RegionKind::Resolved, Some(res)) => match res.kind {
            ResolutionKind::Imports => format!(
                "Both sides changed the imports{}: every import either side added is kept",
                within(res)
            ),
            ResolutionKind::BothAdded => {
                format!(
                    "Both sides added items here{}: ours first, then theirs",
                    within(res)
                )
            }
            ResolutionKind::Lines => format!(
                "The sides edited neighbouring lines{}: both edits are kept",
                within(res)
            ),
            ResolutionKind::Words => format!(
                "The sides edited different words of these lines{}: both edits are kept",
                within(res)
            ),
            ResolutionKind::Reordered => {
                let (moved, edited) = match res.reordered {
                    Some(Side::Theirs) => ("Theirs", "ours"),
                    _ => ("Ours", "theirs"),
                };
                format!(
                    "{moved} reordered the list{}; {edited}' edits land in the new order",
                    within(res)
                )
            }
        },
    }
}

impl CanvasMerge {
    fn glide_to(&mut self, y: f64, animated: bool) {
        let to = y.clamp(0.0, self.view.max_top());
        if animated && (to - self.view.top()).abs() > 0.5 {
            self.glide = Some(Glide {
                from: self.view.top(),
                to,
                start: Instant::now(),
            });
        } else {
            self.glide = None;
            self.view.set_top(to);
        }
        self.dirty = true;
    }

    /// The jump's place now; false once it landed.
    fn advance_glide(&mut self) -> bool {
        let Some(g) = &self.glide else {
            return false;
        };
        let t = (g.start.elapsed().as_secs_f64() / GLIDE.as_secs_f64()).min(1.0);
        let eased = 1.0 - (1.0 - t).powi(3);
        self.view.set_top(g.from + (g.to - g.from) * eased);
        self.dirty = true;
        if t >= 1.0 {
            self.glide = None;
        }
        t < 1.0
    }

    fn reveal(&mut self, region: usize, animated: bool) {
        if let Some(y) = self.view.region_top(region) {
            self.glide_to(y, animated);
        }
    }
}

/// A new merge at `font_size` points in code theme `theme`, with the host's `accent`: empty
/// until canvas_merge_set_file. Free it with canvas_merge_free.
///
/// # Safety
/// `theme` is valid for the call; `out` is valid; `error` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_new(
    theme: CanvasStr,
    accent: CanvasRgba,
    font_size: f32,
    out: *mut *mut CanvasMerge,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        // SAFETY: per this function's contract.
        let colors = colors(&unsafe { theme.text() }?)?;
        let metrics = DiffMetrics::for_cell(Size::new(font_size * 0.6, LINE_HEIGHT), font_size);
        let empty = Merge::new("", "", "", None);
        let h = Box::new(CanvasMerge {
            view: MergeView::new("", "", "", empty, metrics),
            dl: DisplayList::new(colors.background()),
            colors,
            accent: accent.into(),
            font_size,
            renderer: None,
            glide: None,
            dirty: true,
            built_at: 0,
        });
        // SAFETY: checked non-null above.
        unsafe { *out = Box::into_raw(h) };
        Ok(())
    })
}

/// Free a merge (detaching it first).
///
/// # Safety
/// `h` is null or a handle from canvas_merge_new, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_free(h: *mut CanvasMerge) {
    if !h.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Draw into `layer` (a `CAMetalLayer *`), `width` × `height` points at `scale`, on the shared
/// device.
///
/// # Safety
/// `h` is a live merge; `layer` is a valid CAMetalLayer that outlives the attachment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_attach(
    h: *mut CanvasMerge,
    layer: *mut c_void,
    width: f64,
    height: f64,
    scale: f64,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { merge(h) }?;
        // SAFETY: the caller's contract: a valid CAMetalLayer that outlives the attachment.
        let mut surface = unsafe { Surface::attach(layer, width, height, scale) }?;
        let font_size = h.font_size;
        let metrics = surface.with(|_, _, text| metrics(text, font_size, scale));
        h.view.set_metrics(metrics);
        h.view.resize(Size::new(width as f32, height as f32));
        h.renderer = Some(surface);
        h.dirty = true;
        Ok(())
    })
}

/// Stop drawing into the layer; the merge, the scroll and the shared device stay.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_detach(h: *mut CanvasMerge) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.renderer = None;
        h.glide = None;
        h.dirty = true;
    }
}

/// The surface is now `width` × `height` points at `scale`; the stretch at the centre stays.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_resize(
    h: *mut CanvasMerge,
    width: f64,
    height: f64,
    scale: f64,
) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        if let Some(r) = &mut h.renderer {
            r.resize(width, height, scale);
            let font_size = h.font_size;
            let metrics = r.with(|_, _, text| metrics(text, font_size, scale));
            h.view.set_metrics(metrics);
        }
        h.view.resize(Size::new(width as f32, height as f32));
        h.dirty = true;
    }
}

/// One file's merge: `ours` and `theirs` over `base`, the language read from `path`; a past
/// merge passes what its commit committed (`has_committed`), so the result pane is that text
/// and each region says what the commit took. Highlights, the ⇥ region and the scroll reset.
///
/// # Safety
/// The strings are valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_set_file(
    h: *mut CanvasMerge,
    path: CanvasStr,
    base: CanvasStr,
    ours: CanvasStr,
    theirs: CanvasStr,
    committed: CanvasStr,
    has_committed: bool,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, path, base, ours, theirs, committed) = unsafe {
            (
                merge(h)?,
                path.text()?,
                base.text()?,
                ours.text()?,
                theirs.text()?,
                committed.text()?,
            )
        };
        let mut m = Merge::new(&base, &ours, &theirs, Language::from_path(&path));
        if has_committed {
            m = m.against(&base, &ours, &theirs, &committed);
        }
        let metrics = h.view.metrics();
        let (size, origin, base_shown) = (h.view.size(), h.view.origin, h.view.shows_base());
        h.view = MergeView::new(&base, &ours, &theirs, m, metrics);
        h.view.origin = origin;
        h.view.set_shows_base(base_shown);
        h.view.resize(size);
        h.glide = None;
        h.dirty = true;
        Ok(())
    })
}

/// The panes' titles, four in CANVAS_MERGE_PANE_* order.
///
/// # Safety
/// `labels` is valid for four strings, each valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_set_labels(
    h: *mut CanvasMerge,
    labels: *const CanvasStr,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, labels) = unsafe { (merge(h)?, slice(labels, 4)?) };
        let mut out: [String; 4] = Default::default();
        for (slot, l) in out.iter_mut().zip(labels) {
            // SAFETY: per this function's contract.
            *slot = unsafe { l.text() }?.to_string();
        }
        h.view.set_labels(out);
        h.dirty = true;
        Ok(())
    })
}

/// One pane's (CANVAS_MERGE_PANE_*) highlights: `line_count + 1` entries of `line_starts` index
/// each line's runs in `runs` (UTF-16 units from the line's start, as Swift's `LineTokens`
/// holds them). Ask canvas_merge_result for the result pane's text to highlight.
///
/// # Safety
/// `runs` and `line_starts` are null with a zero count, or valid for theirs, for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_set_tokens(
    h: *mut CanvasMerge,
    pane_code: u8,
    runs: *const crate::diff::CanvasDiffRun,
    run_count: usize,
    line_starts: *const u32,
    line_start_count: usize,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, runs, starts) = unsafe {
            (
                merge(h)?,
                slice(runs, run_count)?,
                slice(line_starts, line_start_count)?,
            )
        };
        let p = pane(pane_code)?;
        let lines = (0..starts.len().saturating_sub(1)).map(|n| {
            let (a, b) = (starts[n] as usize, starts[n + 1] as usize);
            let line_runs = runs.get(a.min(b)..b.min(runs.len())).unwrap_or(&[]);
            let Some(text) = h.view.line(p, n) else {
                return Vec::new();
            };
            line_runs
                .iter()
                .filter_map(|r| {
                    let role = SyntaxRole::ALL.get(usize::from(r.kind).checked_sub(1)?)?;
                    let (start, end) = (byte_of(text, r.start), byte_of(text, r.start + r.length));
                    (end > start).then_some(TokenRun {
                        start,
                        len: end - start,
                        role: *role,
                    })
                })
                .collect::<Vec<_>>()
        });
        let tokens = LineTokens::from_lines(lines.collect::<Vec<_>>());
        h.view.set_tokens(p, tokens);
        h.dirty = true;
        Ok(())
    })
}

/// Draw in code theme `theme` with the host's `accent`.
///
/// # Safety
/// `h` is a live merge; `theme` is valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_set_theme(
    h: *mut CanvasMerge,
    theme: CanvasStr,
    accent: CanvasRgba,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, id) = unsafe { (merge(h)?, theme.text()?) };
        h.colors = colors(&id)?;
        h.dl.clear = h.colors.background();
        h.accent = accent.into();
        h.dirty = true;
        Ok(())
    })
}

/// Show the merge base as a fourth pane at the left; the stretch at the centre stays.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_set_shows_base(h: *mut CanvasMerge, shows: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.set_shows_base(shows);
        h.dirty = true;
    }
}

/// Two fingers moved the content by (`dx`, `dy`) points: positive scrolls toward the end. It
/// stops a key's jump.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_scroll(h: *mut CanvasMerge, dx: f64, dy: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.glide = None;
        h.view.scroll_by(dx as f32, dy);
        h.dirty = true;
    }
}

/// A key's scroll (a CANVAS_DIFF_STEP_*) toward the end (`sign` > 0) or the top, eased unless
/// `animated` is false (Reduce Motion).
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_step(
    h: *mut CanvasMerge,
    step: u8,
    sign: i8,
    animated: bool,
) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        let from = h.glide.as_ref().map_or(h.view.top(), |g| g.to);
        let line = f64::from(h.view.metrics().cell.h);
        let page = (f64::from(h.view.size().h) - 48.0).max(line * 3.0);
        let s = f64::from(sign.signum());
        let y = match step {
            CANVAS_DIFF_STEP_LINE => from + s * line * 3.0,
            CANVAS_DIFF_STEP_PAGE => from + s * page,
            CANVAS_DIFF_STEP_EDGE if sign > 0 => h.view.max_top(),
            _ => 0.0,
        };
        h.glide_to(y, animated);
    }
}

/// ⇥ (`forward`) or ⇧⇥: the next conflict or resolution (wrapping), revealed a third of the
/// way down, eased unless not `animated`; its index, or -1 when the merge has none.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_next(
    h: *mut CanvasMerge,
    forward: bool,
    animated: bool,
) -> i64 {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_mut() }) else {
        return -1;
    };
    match h.view.step(forward) {
        Some(k) => {
            h.reveal(k, animated);
            k as i64
        }
        None => -1,
    }
}

/// Region `region` becomes the one ⇥ is on (-1: none), and is revealed when `reveal`.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_select(
    h: *mut CanvasMerge,
    region: i64,
    reveal: bool,
    animated: bool,
) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        let k = usize::try_from(region).ok();
        h.view.select(k);
        if let (Some(k), true) = (h.view.current(), reveal) {
            h.reveal(k, animated);
        }
        h.dirty = true;
    }
}

/// Region `index` into `out`; false past the last.
///
/// # Safety
/// `h` is null or a live merge; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_region(
    h: *mut CanvasMerge,
    index: u32,
    out: *mut CanvasMergeRegion,
) -> bool {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return false;
    };
    match h.view.merge().regions.get(index as usize) {
        Some(r) if !out.is_null() => {
            // SAFETY: checked non-null; valid per this function's contract.
            unsafe { out.write(region_of(r)) };
            true
        }
        _ => false,
    }
}

/// Why region `index` reads as it does, in Pultík's words; null past the last. Free it with
/// canvas_string_free.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_region_reason(
    h: *mut CanvasMerge,
    index: u32,
) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }
        .and_then(|h| h.view.merge().regions.get(index as usize))
        .map_or(std::ptr::null_mut(), |r| owned(&reason(r)))
}

/// The result pane's text (the merged file, or a past merge's commit), for the host to
/// highlight. Free it with canvas_string_free.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_result(h: *mut CanvasMerge) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }.map_or(std::ptr::null_mut(), |h| owned(&h.view.merge().result))
}

/// One file's merge counted without a view: the conflicts left and the regions resolved, for
/// a file list. Takes no handle, so any thread may call it.
///
/// # Safety
/// The strings are valid for the call; `conflicts` and `resolved` are valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_summary(
    path: CanvasStr,
    base: CanvasStr,
    ours: CanvasStr,
    theirs: CanvasStr,
    conflicts: *mut u32,
    resolved: *mut u32,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        if conflicts.is_null() || resolved.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        // SAFETY: per this function's contract.
        let (path, base, ours, theirs) =
            unsafe { (path.text()?, base.text()?, ours.text()?, theirs.text()?) };
        let m = Merge::new(&base, &ours, &theirs, Language::from_path(&path));
        let n = m
            .regions
            .iter()
            .filter(|r| r.kind == RegionKind::Resolved)
            .count() as u32;
        // SAFETY: checked non-null; valid per this function's contract.
        unsafe {
            conflicts.write(m.conflicts() as u32);
            resolved.write(n);
        }
        Ok(())
    })
}

/// What view point (`x`, `y`) is over.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_hit(h: *mut CanvasMerge, x: f64, y: f64) -> CanvasMergeHit {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return CanvasMergeHit::default();
    };
    let region = |r: Option<usize>| r.map_or(-1, |k| k as i64);
    match h.view.hit(Point::new(x as f32, y as f32)) {
        MergeHit::None => CanvasMergeHit::default(),
        MergeHit::Header(p) => CanvasMergeHit {
            kind: CANVAS_MERGE_HIT_HEADER,
            pane: pane_code(p),
            ..Default::default()
        },
        MergeHit::Line {
            pane,
            line,
            region: r,
        } => CanvasMergeHit {
            kind: CANVAS_MERGE_HIT_LINE,
            pane: pane_code(pane),
            line: line as u32,
            region: region(r),
        },
        MergeHit::Ribbon { region: r } => CanvasMergeHit {
            kind: CANVAS_MERGE_HIT_RIBBON,
            region: r as i64,
            ..Default::default()
        },
    }
}

/// Each shown pane's title and lines in view (the panel driver's reading). Free it with
/// canvas_string_free.
///
/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_visible_text(h: *mut CanvasMerge) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }.map_or(std::ptr::null_mut(), |h| owned(&h.view.visible_text()))
}

/// # Safety
/// `h` is null or a live merge.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_state(h: *mut CanvasMerge) -> CanvasMergeState {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return CanvasMergeState::default();
    };
    let m = h.view.merge();
    let count = |f: &dyn Fn(&Region) -> bool| m.regions.iter().filter(|r| f(r)).count() as u32;
    CanvasMergeState {
        regions: m.regions.len() as u32,
        conflicts: count(&|r| r.kind == RegionKind::Conflict),
        resolved: count(&|r| r.kind == RegionKind::Resolved),
        committed: count(&|r| r.committed.is_some()),
        current: h.view.current().map_or(-1, |k| k as i64),
        top: h.view.top(),
        height: h.view.height(),
        highlighted: MergePane::ALL
            .iter()
            .filter(|&&p| h.view.has_tokens(p))
            .count() as u32,
        shows_base: h.view.shows_base(),
    }
}

/// Draw a frame if anything changed (or a key's jump is in flight). Call it from the display
/// link while it reports `animating`, and after any input.
///
/// # Safety
/// `h` is a live merge; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_merge_frame(
    h: *mut CanvasMerge,
    out: *mut CanvasFrameReport,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { merge(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let mut frame = CanvasFrameReport::default();
        let gliding = h.advance_glide();
        if let Some(mut r) = h.renderer.take() {
            let result = r.with(|gpu, target, text| -> Result<(), Failure> {
                if h.dirty || h.built_at != text.atlas().generation() {
                    let mut ops = std::mem::take(&mut h.dl.ops);
                    // The last frame's blocks go back to the view before it fills them again.
                    ops.clear();
                    h.view.paint(&h.colors, h.accent, &mut ops);
                    h.dl.ops = ops;
                    // The ribbons' layer follows the scroll.
                    gpu.set_camera(target, h.view.camera());
                    frame.built = true;
                    frame.presented = gpu
                        .render(target, &h.dl, text)
                        .map_err(|e| Failure::Engine(e.to_string()))?
                        == FrameOutcome::Presented;
                    h.built_at = text.atlas().generation();
                    h.dirty = false;
                } else if target.animating() {
                    frame.presented = gpu
                        .redraw(target)
                        .map_err(|e| Failure::Engine(e.to_string()))?
                        == FrameOutcome::Presented;
                }
                Ok(())
            });
            frame.animating = gliding || r.animating();
            h.renderer = Some(r);
            result?;
        }
        frame.next_due_ms = f64::NAN;
        // SAFETY: checked non-null above.
        unsafe { out.write(frame) };
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    fn s(text: &str) -> CanvasStr {
        CanvasStr {
            ptr: text.as_ptr(),
            len: text.len(),
        }
    }

    const BASE: &str =
        "use a;\n\nfn f() {\n    let x = 1;\n    let y = 2;\n}\n\nconst N: u8 = 1;\n";
    const OURS: &str =
        "use a;\nuse b;\n\nfn f() {\n    let x = 10;\n    let y = 2;\n}\n\nconst N: u8 = 2;\n";
    const THEIRS: &str =
        "use a;\nuse c;\n\nfn f() {\n    let x = 1;\n    let y = 20;\n}\n\nconst N: u8 = 3;\n";

    /// A merge of `BASE`, `OURS` and `THEIRS` in a 900 × 400 pt view, not attached (no GPU).
    fn merged(committed: Option<&str>) -> *mut CanvasMerge {
        let mut h = std::ptr::null_mut();
        let accent = CanvasRgba {
            r: 1.0,
            g: 0.6,
            b: 0.0,
            a: 1.0,
        };
        // SAFETY: valid arguments for the calls.
        unsafe {
            let status = canvas_merge_new(
                s(theme::DEFAULT_ID),
                accent,
                12.0,
                &mut h,
                std::ptr::null_mut(),
            );
            assert_eq!(status, crate::CANVAS_OK);
            canvas_merge_resize(h, 900.0, 400.0, 2.0);
            let status = canvas_merge_set_file(
                h,
                s("src/lib.rs"),
                s(BASE),
                s(OURS),
                s(THEIRS),
                s(committed.unwrap_or("")),
                committed.is_some(),
                std::ptr::null_mut(),
            );
            assert_eq!(status, crate::CANVAS_OK);
        }
        h
    }

    fn regions(h: *mut CanvasMerge) -> Vec<CanvasMergeRegion> {
        let mut out = Vec::new();
        let mut r = CanvasMergeRegion::default();
        // SAFETY: a live handle and a valid out.
        while unsafe { canvas_merge_region(h, out.len() as u32, &mut r) } {
            out.push(r);
        }
        out
    }

    #[test]
    fn a_file_merges_into_regions_with_reasons_and_tab_walks_what_needs_a_look() {
        let h = merged(None);
        let rs = regions(h);
        let kinds: Vec<(u8, u8)> = rs.iter().map(|r| (r.kind, r.resolution)).collect();
        assert!(kinds.contains(&(
            CANVAS_MERGE_REGION_RESOLVED,
            CANVAS_MERGE_RESOLUTION_IMPORTS
        )));
        assert!(kinds.contains(&(CANVAS_MERGE_REGION_RESOLVED, CANVAS_MERGE_RESOLUTION_LINES)));
        assert!(kinds.contains(&(CANVAS_MERGE_REGION_CONFLICT, CANVAS_MERGE_RESOLUTION_NONE)));
        // SAFETY: a live handle, freed at the end.
        unsafe {
            let state = canvas_merge_state(h);
            assert_eq!((state.conflicts, state.resolved, state.current), (1, 2, -1));
            let lines = rs
                .iter()
                .position(|r| r.resolution == CANVAS_MERGE_RESOLUTION_LINES)
                .unwrap();
            let why = canvas_merge_region_reason(h, lines as u32);
            assert_eq!(
                CStr::from_ptr(why).to_str(),
                Ok("The sides edited neighbouring lines in `f`: both edits are kept")
            );
            crate::canvas_string_free(why);
            // ⇥ walks the imports, the function, the conflict, then wraps.
            let stops: Vec<i64> = (0..4).map(|_| canvas_merge_next(h, true, false)).collect();
            assert_eq!(stops[3], stops[0]);
            assert_eq!(rs[stops[2] as usize].kind, CANVAS_MERGE_REGION_CONFLICT);
            assert_eq!(canvas_merge_state(h).current, stops[3]);
            let result = canvas_merge_result(h);
            let text = CStr::from_ptr(result).to_str().unwrap().to_owned();
            crate::canvas_string_free(result);
            assert!(text.starts_with("use a;\nuse b;\nuse c;\n"));
            assert!(text.contains("let x = 10;\n    let y = 20;"));
            canvas_merge_free(h);
        }
    }

    #[test]
    fn a_ribbon_and_a_line_hit_their_region_and_the_panes_stay_in_step() {
        let h = merged(None);
        // SAFETY: a live handle, freed at the end.
        unsafe {
            let v = &(*h).view;
            let state = canvas_merge_state(h);
            assert!(state.height > 0.0);
            // The result pane's first line (under the 30 pt headers): the unchanged `use a;`.
            let w = v.size().w;
            let line = canvas_merge_hit(h, f64::from(w) / 2.0, 30.0 + 9.0);
            assert_eq!(
                (line.kind, line.pane, line.line),
                (CANVAS_MERGE_HIT_LINE, CANVAS_MERGE_PANE_RESULT, 0)
            );
            let r = regions(h)[line.region as usize];
            assert_eq!(r.kind, CANVAS_MERGE_REGION_UNCHANGED);
            // Every pane at the top: the file is shorter than the view.
            for p in [MergePane::Ours, MergePane::Result, MergePane::Theirs] {
                assert_eq!(v.pane_top(p), 0.0);
            }
            assert_eq!(
                canvas_merge_hit(h, f64::from(w) / 2.0, 5.0).kind,
                CANVAS_MERGE_HIT_HEADER
            );
            canvas_merge_set_shows_base(h, true);
            assert!(canvas_merge_state(h).shows_base);
            assert_eq!(canvas_merge_hit(h, 20.0, 5.0).pane, CANVAS_MERGE_PANE_BASE);
            canvas_merge_free(h);
        }
    }

    #[test]
    fn a_past_merge_shows_its_commit_and_says_what_it_took() {
        // The commit took theirs' constant.
        let committed = "use a;\nuse b;\nuse c;\n\nfn f() {\n    let x = 10;\n    let y = 20;\n}\n\nconst N: u8 = 3;\n";
        let h = merged(Some(committed));
        // SAFETY: a live handle, freed at the end.
        unsafe {
            let result = canvas_merge_result(h);
            assert_eq!(CStr::from_ptr(result).to_str(), Ok(committed));
            crate::canvas_string_free(result);
            let rs = regions(h);
            let took = rs
                .iter()
                .position(|r| r.committed == CANVAS_MERGE_COMMITTED_THEIRS)
                .unwrap();
            assert_eq!(rs[took].kind, CANVAS_MERGE_REGION_CONFLICT);
            let why = canvas_merge_region_reason(h, took as u32);
            assert_eq!(
                CStr::from_ptr(why).to_str(),
                Ok("The merge commit took theirs here")
            );
            crate::canvas_string_free(why);
            assert_eq!(canvas_merge_state(h).committed, 1);
            canvas_merge_free(h);
        }
    }

    #[test]
    fn every_resolution_kind_has_its_words() {
        let region = |kind, scope: Option<&str>, reordered| Region {
            kind: RegionKind::Resolved,
            base: 0..1,
            ours: 0..1,
            theirs: 0..1,
            result: 0..1,
            resolution: Some(Resolution {
                kind,
                scope: scope.map(String::from),
                reordered,
            }),
            committed: None,
        };
        let cases = [
            (
                ResolutionKind::Imports,
                None,
                None,
                "Both sides changed the imports: every import either side added is kept",
            ),
            (
                ResolutionKind::BothAdded,
                Some("Config"),
                None,
                "Both sides added items here in `Config`: ours first, then theirs",
            ),
            (
                ResolutionKind::Lines,
                Some("f"),
                None,
                "The sides edited neighbouring lines in `f`: both edits are kept",
            ),
            (
                ResolutionKind::Words,
                None,
                None,
                "The sides edited different words of these lines: both edits are kept",
            ),
            (
                ResolutionKind::Reordered,
                Some("ROUTES"),
                Some(Side::Theirs),
                "Theirs reordered the list in `ROUTES`; ours' edits land in the new order",
            ),
        ];
        for (kind, scope, side, words) in cases {
            assert_eq!(reason(&region(kind, scope, side)), words);
        }
    }
}
