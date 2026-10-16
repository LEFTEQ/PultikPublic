//! The timeline's C ABI: what Pultík's `Packages/Timeline` calls. Swift owns the data, paging,
//! polling, cards, chrome and every key; it hands this crate plain data and gestures, and the
//! timeline owns marks, layout, hit testing, stepping, the camera and drawing (on the canvas
//! crates, into the host's `CAMetalLayer`). `include/timeline.h` is generated from this crate by
//! cbindgen (`cargo xtask timeline-header`, `--check` for drift).
//!
//! - Plain data only: `#[repr(C)]` structs, [`TimelineStr`] (UTF-8 pointer and byte length),
//!   arrays as pointer and count, times as `f64` ms since the epoch with NaN for none.
//! - A handle is used by one thread at a time (the main thread). Its GPU device exists only
//!   between [`timeline_attach`] and [`timeline_detach`] (or [`timeline_free`]).
//! - Every entry point runs inside [`call`]: a panic becomes [`TIMELINE_PANICKED`] with its
//!   message, never an unwind into Swift (Pultík builds the `dev` and `ffi-release` profiles,
//!   which unwind).

use canvas_gpu::{FrameOutcome, Gpu, Target};
use canvas_text::TextSystem;
use std::ffi::{CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use timeline::layout::{GroupSpec, stacked_group};
use timeline::lens::ci::{CiJob, CiLens, CiResult};
use timeline::lens::estate::{
    BackupsLens, EstateEvent, EstateLens, EstatePin, EstateTimer, EventKind, EventResult, Row,
    backup_row, estate_group, estate_row, pin_band, timer_schedule,
};
use timeline::scene::Hit;

pub mod map;
use timeline::{Bin, Lens, Palette, Step, Timeline};

/// What a call answered: TIMELINE_OK or why not.
pub type TimelineStatus = i32;
pub const TIMELINE_OK: TimelineStatus = 0;
/// The engine refused (no GPU adapter, a surface it could not configure); the message says why.
pub const TIMELINE_FAILED: TimelineStatus = 1;
/// The engine panicked: caught here, the message is the panic's.
pub const TIMELINE_PANICKED: TimelineStatus = 2;
/// An argument was unusable: a null pointer, text that is not UTF-8, an unknown code.
pub const TIMELINE_INVALID: TimelineStatus = 3;

/// UTF-8 text by pointer and byte length (never NUL-terminated), owned by the caller for the call.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineStr {
    pub ptr: *const u8,
    pub len: usize,
}

impl TimelineStr {
    /// # Safety
    /// `ptr` is null with `len` 0, or valid for `len` bytes for the call.
    unsafe fn text(self) -> Result<Arc<str>, Failure> {
        let bytes = match (self.ptr.is_null(), self.len) {
            (true, 0) => &[][..],
            (true, _) => return Err(Failure::Invalid("a null text with a length")),
            // SAFETY: per this function's contract.
            (false, len) => unsafe { std::slice::from_raw_parts(self.ptr, len) },
        };
        std::str::from_utf8(bytes)
            .map(Arc::from)
            .map_err(|_| Failure::Invalid("text is not UTF-8"))
    }
}

/// A straight-alpha sRGB colour in `0..=1`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl From<TimelineRgba> for canvas_draw::Rgba {
    fn from(c: TimelineRgba) -> Self {
        canvas_draw::Rgba::new(c.r, c.g, c.b, c.a)
    }
}

/// The host's status tokens (Pultík's Theme): colour means status, never a repository.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelinePalette {
    pub background: TimelineRgba,
    pub band: TimelineRgba,
    pub foreground: TimelineRgba,
    pub muted: TimelineRgba,
    pub grid: TimelineRgba,
    pub data: TimelineRgba,
    pub ok: TimelineRgba,
    pub danger: TimelineRgba,
    pub warning: TimelineRgba,
    pub accent: TimelineRgba,
}

impl From<TimelinePalette> for Palette {
    fn from(p: TimelinePalette) -> Self {
        Palette {
            background: p.background.into(),
            band: p.band.into(),
            foreground: p.foreground.into(),
            muted: p.muted.into(),
            grid: p.grid.into(),
            data: p.data.into(),
            ok: p.ok.into(),
            danger: p.danger.into(),
            warning: p.warning.into(),
            accent: p.accent.into(),
        }
    }
}

/// Which lens a handle draws.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimelineLens {
    Ci = 0,
    /// Each box a lane of Rollouts / Backups / Cleanups (timeline_set_estate_*).
    Estate = 1,
    /// One row per backed-up surface: groups of rows keyed `box|surface`.
    Backups = 2,
}

/// One CI job (Semafor's `/api/v1/ci/timeline` `jobs`). Times are ms since the epoch, NaN for
/// none; `result` is a TIMELINE_RESULT_*; a memory figure of `UINT32_MAX` is unmeasured.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineCiJob {
    pub id: TimelineStr,
    pub lane: TimelineStr,
    pub repo: TimelineStr,
    pub name: TimelineStr,
    pub queued_at: f64,
    pub started_at: f64,
    pub completed_at: f64,
    pub result: u8,
    pub peak_mib: u32,
    pub reserved_mib: u32,
}

pub const TIMELINE_RESULT_SUCCEEDED: u8 = 0;
pub const TIMELINE_RESULT_FAILED: u8 = 1;
pub const TIMELINE_RESULT_CANCELLED: u8 = 2;
pub const TIMELINE_RESULT_UNKNOWN: u8 = 3;
pub const TIMELINE_RESULT_RUNNING: u8 = 4;
pub const TIMELINE_RESULT_WAITING: u8 = 5;

/// One density bin: `count` items on `row` in `[from, from + width)` ms, `failures` of them failed.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineBin {
    pub row: TimelineStr,
    pub from: f64,
    pub width: f64,
    pub count: u32,
    pub failures: u32,
}

/// A row: its key (what an item's row names), label and lane-glyph tint (`has_tint`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineRow {
    pub key: TimelineStr,
    pub label: TimelineStr,
    pub tint: TimelineRgba,
    pub has_tint: bool,
}

/// A group of rows stacked under its label (an organisation's lanes, the hosted lanes).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineGroup {
    pub key: TimelineStr,
    pub label: TimelineStr,
    pub rows: *const TimelineRow,
    pub row_count: usize,
}

/// A key's intent (KeyboardCoordinator's entered-timeline context, D5).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimelineIntent {
    /// ← / →: the previous / next finished outcome.
    OutcomeBack = 0,
    OutcomeForward = 1,
    /// ⇧← / ⇧→: every mark by (start, id).
    MarkBack = 2,
    MarkForward = 3,
    /// ⌥← / ⌥→: pan a fifth of the screen.
    PanBack = 4,
    PanForward = 5,
    /// − / =: a zoom level out, in.
    ZoomOut = 6,
    ZoomIn = 7,
    /// N: now, the playhead released.
    Now = 8,
}

/// What a frame did.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineFrame {
    /// The scene was built again (a level, the window, the data or the selection changed).
    pub built: bool,
    /// A frame reached the layer.
    pub presented: bool,
    /// Keep the display link running: something moves every frame (a flowing dash).
    pub animating: bool,
    /// ms until the next frame is due without input (a running job grows by a point): sleep
    /// until then instead of ticking. NaN: nothing is due.
    pub next_due_ms: f64,
}

impl Default for TimelineFrame {
    fn default() -> Self {
        TimelineFrame {
            built: false,
            presented: false,
            animating: false,
            next_due_ms: f64::NAN,
        }
    }
}

/// The axis strip's height and the label column's width, points: where the host's own hit
/// zones (the playhead drag) begin. Literals, so cbindgen writes them; a test holds them equal to
/// the engine's.
pub const TIMELINE_AXIS_PT: f32 = 30.0;
pub const TIMELINE_LABEL_W: f32 = 168.0;

/// Show `[from, to]` (ms) across a quarter of the lanes, at least twice the current zoom: what a
/// click on a cluster or a band opens.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_zoom_to(h: *mut TimelineHandle, from: f64, to: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() }
        && from.is_finite()
        && to.is_finite()
    {
        h.timeline.zoom_to(from.min(to), from.max(to));
    }
}

/// The view and what the host should load and replay.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct TimelineState {
    /// Time at the lanes' left edge and the span they show, ms.
    pub t0: f64,
    pub span: f64,
    /// What to load: the visible span plus one either side, ms.
    pub wanted_from: f64,
    pub wanted_to: f64,
    /// The bin width to ask for, ms; NaN while marks are enough.
    pub bucket: f64,
    /// The playhead (the replay instant), ms; NaN when it follows now.
    pub playhead: f64,
}

/// What a point is on: TIMELINE_HIT_NONE, _MARK (its id in `id`) or _CLUSTER (`from`..`to`).
#[repr(C)]
#[derive(Debug)]
pub struct TimelineHit {
    pub kind: u8,
    /// An owned NUL-terminated id (free with timeline_string_free), or null.
    pub id: *mut c_char,
    pub from: f64,
    pub to: f64,
}

pub const TIMELINE_HIT_NONE: u8 = 0;
pub const TIMELINE_HIT_MARK: u8 = 1;
pub const TIMELINE_HIT_CLUSTER: u8 = 2;
pub const TIMELINE_HIT_RAIL: u8 = 3;
pub const TIMELINE_HIT_BAND: u8 = 4;

/// The GPU side of an attached handle.
struct Renderer {
    gpu: Gpu,
    target: Target,
}

/// One timeline on screen.
pub struct TimelineHandle {
    lens: TimelineLens,
    timeline: Timeline,
    text: TextSystem,
    renderer: Option<Renderer>,
    /// The camera last drawn, so an unchanged view presents nothing.
    drawn: Option<canvas_draw::Camera>,
}

#[derive(Debug)]
enum Failure {
    Engine(String),
    Invalid(&'static str),
}

fn owned(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', " "))
        .expect("NULs replaced")
        .into_raw()
}

/// Run one entry point: a panic or a failure becomes its status, its message goes to `error`.
fn call(error: *mut *mut c_char, f: impl FnOnce() -> Result<(), Failure>) -> TimelineStatus {
    let (status, message) = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => (TIMELINE_OK, None),
        Ok(Err(Failure::Engine(m))) => (TIMELINE_FAILED, Some(m)),
        Ok(Err(Failure::Invalid(why))) => (TIMELINE_INVALID, Some(why.to_owned())),
        Err(payload) => {
            let m = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "a panic without a message".to_owned());
            (TIMELINE_PANICKED, Some(m))
        }
    };
    if !error.is_null() {
        // SAFETY: the caller passes null or a pointer it owns for the call.
        unsafe { *error = message.map_or(std::ptr::null_mut(), |m| owned(&m)) };
    }
    status
}

/// # Safety
/// `h` is null (refused) or a live handle from [`timeline_new`] used by this thread alone.
unsafe fn handle<'a>(h: *mut TimelineHandle) -> Result<&'a mut TimelineHandle, Failure> {
    // SAFETY: per this function's contract.
    unsafe { h.as_mut() }.ok_or(Failure::Invalid("a null handle"))
}

/// # Safety
/// `ptr` is null with `count` 0, or valid for `count` elements for the call.
unsafe fn slice<'a, T>(ptr: *const T, count: usize) -> Result<&'a [T], Failure> {
    match (ptr.is_null(), count) {
        (true, 0) => Ok(&[]),
        (true, _) => Err(Failure::Invalid("a null array with a count")),
        // SAFETY: per this function's contract.
        (false, n) => Ok(unsafe { std::slice::from_raw_parts(ptr, n) }),
    }
}

fn time(t: f64) -> Option<f64> {
    t.is_finite().then_some(t)
}

fn mib(v: u32) -> Option<u32> {
    (v != u32::MAX).then_some(v)
}

fn result(code: u8) -> Result<CiResult, Failure> {
    Ok(match code {
        TIMELINE_RESULT_SUCCEEDED => CiResult::Succeeded,
        TIMELINE_RESULT_FAILED => CiResult::Failed,
        TIMELINE_RESULT_CANCELLED => CiResult::Cancelled,
        TIMELINE_RESULT_UNKNOWN => CiResult::Unknown,
        TIMELINE_RESULT_RUNNING => CiResult::Running,
        TIMELINE_RESULT_WAITING => CiResult::Waiting,
        _ => return Err(Failure::Invalid("an unknown job result")),
    })
}

/// A new timeline of `lens` (a TimelineLens) at `now`, drawn in `palette`. Free it with
/// timeline_free.
///
/// # Safety
/// `palette` and `out` are valid; `error` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_new(
    lens: u8,
    palette: *const TimelinePalette,
    now: f64,
    out: *mut *mut TimelineHandle,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        let lens = match lens {
            0 => TimelineLens::Ci,
            1 => TimelineLens::Estate,
            2 => TimelineLens::Backups,
            _ => return Err(Failure::Invalid("an unknown lens")),
        };
        // SAFETY: per this function's contract.
        let palette = unsafe { palette.as_ref() }.ok_or(Failure::Invalid("a null palette"))?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let spec = match lens {
            TimelineLens::Ci => CiLens.spec(),
            TimelineLens::Estate => EstateLens.spec(),
            TimelineLens::Backups => BackupsLens.spec(),
        };
        let h = Box::new(TimelineHandle {
            lens,
            timeline: Timeline::new(spec, (*palette).into(), now),
            text: TextSystem::new(),
            renderer: None,
            drawn: None,
        });
        // SAFETY: checked non-null above.
        unsafe { *out = Box::into_raw(h) };
        Ok(())
    })
}

/// Free a handle (and its GPU device, when attached).
///
/// # Safety
/// `h` is null or a handle from timeline_new, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_free(h: *mut TimelineHandle) {
    if !h.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Free a string this library returned.
///
/// # Safety
/// `s` is null or a string from this library, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Draw into `layer` (a `CAMetalLayer *`), `width` × `height` points at `scale`: creates the GPU
/// device. Fails with TIMELINE_FAILED when the machine has no adapter.
///
/// # Safety
/// `h` is a live handle; `layer` is a valid CAMetalLayer that outlives the attachment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_attach(
    h: *mut TimelineHandle,
    layer: *mut c_void,
    width: f64,
    height: f64,
    scale: f64,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        if layer.is_null() {
            return Err(Failure::Invalid("a null layer"));
        }
        let gpu = Gpu::new().map_err(|e| Failure::Engine(e.to_string()))?;
        #[cfg(target_vendor = "apple")]
        // SAFETY: the caller's contract: a valid CAMetalLayer that outlives the target.
        let target = unsafe {
            gpu.create_layer_target(layer, canvas_gpu::Compositing::Opaque, width, height, scale)
        }
        .map_err(|e| Failure::Engine(e.to_string()))?;
        #[cfg(not(target_vendor = "apple"))]
        let target: Target = {
            let _ = (width, height, scale);
            return Err(Failure::Engine("layers are Apple-only".into()));
        };
        h.timeline.resize(width as f32, height as f32);
        let mut target = target;
        // The host's display link paces frames. In step with the display, the panel's surface
        // is composited at 60 Hz on a 120 Hz screen and every frame waits ~11 ms for a drawable
        // (AC 8, Metal System Trace 2026-10-16); presented as soon as done, it costs ~0.4 ms.
        gpu.set_vsync(&mut target, false);
        h.renderer = Some(Renderer { gpu, target });
        h.drawn = None;
        Ok(())
    })
}

/// Present in step with the display (`vsync`) or as soon as a frame is done (the default since
/// attach: the host's display link paces frames).
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_vsync(h: *mut TimelineHandle, vsync: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() }
        && let Some(r) = &mut h.renderer
    {
        r.gpu.set_vsync(&mut r.target, vsync);
    }
}

/// Stop drawing and release the GPU device (the panel's 30 s tree release); the data stays.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_detach(h: *mut TimelineHandle) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.renderer = None;
        h.drawn = None;
    }
}

/// The surface is now `width` × `height` points at `scale`.
///
/// # Safety
/// `h` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_resize(
    h: *mut TimelineHandle,
    width: f64,
    height: f64,
    scale: f64,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        h.timeline.resize(width as f32, height as f32);
        if let Some(r) = &mut h.renderer {
            r.gpu.resize(&mut r.target, width, height, scale);
        }
        h.drawn = None;
        Ok(())
    })
}

/// The host's clock, ms since the epoch.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_now(h: *mut TimelineHandle, now: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.timeline.set_now(now);
    }
}

/// Replace the CI lens's jobs.
///
/// # Safety
/// `h` is a live CI handle; `jobs` is valid for `count` elements, their texts for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_ci_jobs(
    h: *mut TimelineHandle,
    jobs: *const TimelineCiJob,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        if h.lens != TimelineLens::Ci {
            return Err(Failure::Invalid("not a CI timeline"));
        }
        let palette = h.timeline.palette;
        let mut marks = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for j in unsafe { slice(jobs, count) }? {
            // SAFETY: per this function's contract.
            let job = unsafe {
                CiJob {
                    id: j.id.text()?,
                    lane: j.lane.text()?,
                    repo: j.repo.text()?,
                    name: j.name.text()?,
                    queued_at: j.queued_at,
                    started_at: time(j.started_at),
                    completed_at: time(j.completed_at),
                    result: result(j.result)?,
                    peak_mib: mib(j.peak_mib),
                    reserved_mib: mib(j.reserved_mib),
                }
            };
            marks.push(CiLens.mark(&job, &palette));
        }
        h.timeline.set_marks(marks);
        Ok(())
    })
}

/// Replace the density bins (zoomed out past the lens's marks).
///
/// # Safety
/// `h` is a live handle; `bins` is valid for `count` elements, their texts for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_bins(
    h: *mut TimelineHandle,
    bins: *const TimelineBin,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        let palette = h.timeline.palette;
        let mut out = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for b in unsafe { slice(bins, count) }? {
            out.push(Bin {
                // SAFETY: per this function's contract.
                row: unsafe { b.row.text() }?,
                from: b.from,
                width: b.width,
                count: b.count,
                failures: b.failures,
                scheduled: false,
                color: palette.data.with_alpha(0.7),
                grow: 0.6,
            });
        }
        h.timeline.set_bins(out);
        Ok(())
    })
}

/// Replace the groups of rows, top to bottom.
///
/// # Safety
/// `h` is a live handle; `groups` is valid for `count` elements, each `rows` for `row_count`,
/// their texts for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_groups(
    h: *mut TimelineHandle,
    groups: *const TimelineGroup,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        let mut out: Vec<GroupSpec> = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for g in unsafe { slice(groups, count) }? {
            let mut rows = Vec::with_capacity(g.row_count);
            // SAFETY: per this function's contract.
            for r in unsafe { slice(g.rows, g.row_count) }? {
                // SAFETY: per this function's contract.
                let (key, label) = unsafe { (r.key.text()?, r.label.text()?) };
                rows.push((key, label, r.has_tint.then(|| r.tint.into())));
            }
            // SAFETY: per this function's contract.
            let (key, label) = unsafe { (g.key.text()?, g.label.text()?) };
            out.push(stacked_group(&key, &label, &rows, 0.0));
        }
        h.timeline.set_groups(out);
        Ok(())
    })
}

/// Recolour (the host's theme changed).
///
/// # Safety
/// `h` is null or a live handle; `palette` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_palette(
    h: *mut TimelineHandle,
    palette: *const TimelinePalette,
) {
    // SAFETY: per this function's contract.
    if let (Some(h), Some(p)) = unsafe { (h.as_mut(), palette.as_ref()) } {
        h.timeline.set_palette((*p).into());
    }
}

/// Two fingers moved the content by (`dx`, `dy`) points (momentum included).
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_scroll(h: *mut TimelineHandle, dx: f64, dy: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.timeline.scroll_by(dx, dy as f32);
    }
}

/// A pinch by `factor` (1 + the event's magnification) around view point `x` (NaN: the lanes'
/// centre).
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_magnify(h: *mut TimelineHandle, factor: f64, x: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        let lanes_x = x
            .is_finite()
            .then(|| x - f64::from(timeline::timeline::LABEL_W));
        h.timeline.zoom_by(factor.max(0.01), lanes_x);
    }
}

/// Run a key's intent (a TimelineIntent). The selection after it is timeline_selected's.
///
/// # Safety
/// `h` is a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_key(
    h: *mut TimelineHandle,
    intent: u8,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        let t = &mut h.timeline;
        match intent {
            0 => drop(t.step(Step::Outcome, -1)),
            1 => drop(t.step(Step::Outcome, 1)),
            2 => drop(t.step(Step::Every, -1)),
            3 => drop(t.step(Step::Every, 1)),
            4 => t.pan_step(-1),
            5 => t.pan_step(1),
            6 => t.zoom_step(-1),
            7 => t.zoom_step(1),
            8 => t.go_now(),
            _ => return Err(Failure::Invalid("an unknown intent")),
        }
        Ok(())
    })
}

/// Select the mark `id` (empty: clear it).
///
/// # Safety
/// `h` is a live handle; `id` is valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_select(
    h: *mut TimelineHandle,
    id: TimelineStr,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, id) = unsafe { (handle(h)?, id.text()?) };
        h.timeline.select((!id.is_empty()).then_some(&*id));
        Ok(())
    })
}

/// The selected mark's id as an owned string (free with timeline_string_free), or null.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_selected(h: *mut TimelineHandle) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }
        .and_then(|h| h.timeline.selected())
        .map_or(std::ptr::null_mut(), owned)
}

/// The playhead dragged to view point `x`; `release` snaps it to a finished outcome nearby.
/// NaN `x` releases it back to now.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_playhead(h: *mut TimelineHandle, x: f64, release: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        if x.is_finite() {
            let lanes_x = x - f64::from(timeline::timeline::LABEL_W);
            h.timeline.drag_playhead(lanes_x, release);
        } else {
            h.timeline.release_playhead();
        }
    }
}

/// What view point (`x`, `y`) is on.
///
/// # Safety
/// `h` is a live handle; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_hit(
    h: *mut TimelineHandle,
    x: f64,
    y: f64,
    out: *mut TimelineHit,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let none = TimelineHit {
            kind: TIMELINE_HIT_NONE,
            id: std::ptr::null_mut(),
            from: f64::NAN,
            to: f64::NAN,
        };
        let hit = match h.timeline.hit(x as f32, y as f32) {
            None => none,
            Some(Hit::Mark(id)) => TimelineHit {
                kind: TIMELINE_HIT_MARK,
                id: owned(&id),
                ..none
            },
            Some(Hit::Cluster(c)) => TimelineHit {
                kind: TIMELINE_HIT_CLUSTER,
                from: c.from,
                to: c.to,
                ..none
            },
            Some(Hit::Rail(r)) => TimelineHit {
                kind: TIMELINE_HIT_RAIL,
                from: r.from,
                ..none
            },
            Some(Hit::Band(b)) => TimelineHit {
                kind: TIMELINE_HIT_BAND,
                id: owned(&b.key),
                from: b.from,
                to: b.to.unwrap_or(f64::NAN),
            },
        };
        // SAFETY: checked non-null above.
        unsafe { out.write(hit) };
        Ok(())
    })
}

/// The view and what to load.
///
/// # Safety
/// `h` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_state(h: *mut TimelineHandle) -> TimelineState {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return TimelineState::default();
    };
    let t = &h.timeline;
    let (from, to) = t.wanted();
    TimelineState {
        t0: t.view().t0,
        span: t.view().span(),
        wanted_from: from,
        wanted_to: to,
        bucket: t.bucket().unwrap_or(f64::NAN),
        playhead: t.playhead().unwrap_or(f64::NAN),
    }
}

/// Draw a frame if anything changed: build the scene when the view left it, else move the
/// camera. Call it from the display link while it reports `animating`, and after any input.
///
/// # Safety
/// `h` is a live handle; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_frame(
    h: *mut TimelineHandle,
    out: *mut TimelineFrame,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { handle(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let mut frame = TimelineFrame::default();
        if let Some(r) = &mut h.renderer {
            if h.timeline.needs_build() {
                let dl = h.timeline.build(&mut h.text);
                r.gpu.set_camera(&mut r.target, h.timeline.camera());
                frame.built = true;
                frame.presented = r
                    .gpu
                    .render(&mut r.target, &dl, &mut h.text)
                    .map_err(|e| Failure::Engine(e.to_string()))?
                    == FrameOutcome::Presented;
                h.drawn = Some(h.timeline.camera());
            } else {
                let camera = h.timeline.camera();
                if h.drawn != Some(camera) || r.target.animating() {
                    r.gpu.set_camera(&mut r.target, camera);
                    frame.presented = r
                        .gpu
                        .redraw(&mut r.target)
                        .map_err(|e| Failure::Engine(e.to_string()))?
                        == FrameOutcome::Presented;
                    h.drawn = Some(camera);
                }
            }
            frame.animating = r.target.animating();
            frame.next_due_ms = h.timeline.next_build_in().unwrap_or(f64::NAN);
        }
        // SAFETY: checked non-null above.
        unsafe { out.write(frame) };
        Ok(())
    })
}

/// One estate event (Semafor's `/api/v1/estate/timeline` `events`): `kind` a
/// TIMELINE_EVENT_KIND_*, `result` a TIMELINE_EVENT_RESULT_*; `duration` ms or NaN, `size_bytes`
/// `UINT64_MAX` when unknown, an empty `surface` when none.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineEstateEvent {
    pub id: TimelineStr,
    pub box_name: TimelineStr,
    pub title: TimelineStr,
    pub surface: TimelineStr,
    pub kind: u8,
    pub result: u8,
    pub at: f64,
    pub duration: f64,
    pub size_bytes: u64,
}

/// A systemd timer (`schedules`): its next run and period, ms.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineEstateTimer {
    pub box_name: TimelineStr,
    pub unit: TimelineStr,
    pub surface: TimelineStr,
    pub kind: u8,
    pub next: f64,
    pub period: f64,
}

/// A rollback pin across its box, from `from` to `to` (NaN: still in force).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineEstatePin {
    pub box_name: TimelineStr,
    pub label: TimelineStr,
    pub from: f64,
    pub to: f64,
}

/// An estate density bin (`buckets`): `row` 0 rollouts, 1 backups, 2 cleanups; the Backups lens
/// keys it by `surface` and skips one without.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineEstateBin {
    pub box_name: TimelineStr,
    pub surface: TimelineStr,
    pub row: u8,
    pub from: f64,
    pub width: f64,
    pub count: u32,
    pub failures: u32,
    pub scheduled: bool,
}

pub const TIMELINE_EVENT_KIND_RECONCILE: u8 = 0;
pub const TIMELINE_EVENT_KIND_GATEWAY: u8 = 1;
pub const TIMELINE_EVENT_KIND_EVE: u8 = 2;
pub const TIMELINE_EVENT_KIND_BACKUP: u8 = 3;
pub const TIMELINE_EVENT_KIND_RESTORE: u8 = 4;
pub const TIMELINE_EVENT_KIND_CLEANUP: u8 = 5;
pub const TIMELINE_EVENT_KIND_CERT: u8 = 6;
pub const TIMELINE_EVENT_RESULT_OK: u8 = 0;
pub const TIMELINE_EVENT_RESULT_FAIL: u8 = 1;
pub const TIMELINE_EVENT_RESULT_ROLLBACK: u8 = 2;
pub const TIMELINE_EVENT_RESULT_LIVE: u8 = 3;
pub const TIMELINE_EVENT_RESULT_MISSED: u8 = 4;
pub const TIMELINE_EVENT_RESULT_SCHEDULED: u8 = 5;

fn event_kind(code: u8) -> Result<EventKind, Failure> {
    Ok(match code {
        0 => EventKind::Reconcile,
        1 => EventKind::Gateway,
        2 => EventKind::Eve,
        3 => EventKind::Backup,
        4 => EventKind::Restore,
        5 => EventKind::Cleanup,
        6 => EventKind::Cert,
        _ => return Err(Failure::Invalid("an unknown event kind")),
    })
}

fn event_result(code: u8) -> Result<EventResult, Failure> {
    Ok(match code {
        0 => EventResult::Ok,
        1 => EventResult::Fail,
        2 => EventResult::Rollback,
        3 => EventResult::Live,
        4 => EventResult::Missed,
        5 => EventResult::Scheduled,
        _ => return Err(Failure::Invalid("an unknown event result")),
    })
}

/// # Safety
/// As [`TimelineStr::text`].
unsafe fn optional(s: TimelineStr) -> Result<Option<Arc<str>>, Failure> {
    // SAFETY: per this function's contract.
    let t = unsafe { s.text() }?;
    Ok((!t.is_empty()).then_some(t))
}

/// # Safety
/// `h` is a live handle.
unsafe fn estate_handle<'a>(h: *mut TimelineHandle) -> Result<&'a mut TimelineHandle, Failure> {
    // SAFETY: per this function's contract.
    let h = unsafe { handle(h) }?;
    match h.lens {
        TimelineLens::Estate | TimelineLens::Backups => Ok(h),
        TimelineLens::Ci => Err(Failure::Invalid("not an Estate or Backups timeline")),
    }
}

/// Replace an Estate or Backups timeline's events.
///
/// # Safety
/// `h` is a live Estate or Backups handle; `events` is valid for `count` elements, their texts
/// for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_estate_events(
    h: *mut TimelineHandle,
    events: *const TimelineEstateEvent,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { estate_handle(h) }?;
        let palette = h.timeline.palette;
        let mut marks = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for e in unsafe { slice(events, count) }? {
            // SAFETY: per this function's contract.
            let event = unsafe {
                EstateEvent {
                    id: e.id.text()?,
                    box_name: e.box_name.text()?,
                    kind: event_kind(e.kind)?,
                    result: event_result(e.result)?,
                    at: e.at,
                    duration: time(e.duration),
                    size_bytes: (e.size_bytes != u64::MAX).then_some(e.size_bytes),
                    title: e.title.text()?,
                    surface: optional(e.surface)?,
                }
            };
            marks.push(match h.lens {
                TimelineLens::Backups => BackupsLens.mark(&event, &palette),
                _ => EstateLens.mark(&event, &palette),
            });
        }
        h.timeline.set_marks(marks);
        Ok(())
    })
}

/// Replace the timers whose repeats the timeline computes.
///
/// # Safety
/// As timeline_set_estate_events, for `timers`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_estate_timers(
    h: *mut TimelineHandle,
    timers: *const TimelineEstateTimer,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { estate_handle(h) }?;
        let palette = h.timeline.palette;
        let mut out = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for t in unsafe { slice(timers, count) }? {
            // SAFETY: per this function's contract.
            let timer = unsafe {
                EstateTimer {
                    box_name: t.box_name.text()?,
                    unit: t.unit.text()?,
                    kind: event_kind(t.kind)?,
                    surface: optional(t.surface)?,
                    next: t.next,
                    period: t.period,
                }
            };
            let row = match (h.lens, &timer.surface) {
                (TimelineLens::Backups, surface) => {
                    backup_row(&timer.box_name, surface.as_deref().unwrap_or(&timer.unit))
                }
                _ => estate_row(&timer.box_name, Row::of(timer.kind)),
            };
            out.push(timer_schedule(&timer, row, &palette));
        }
        h.timeline.set_schedules(out);
        Ok(())
    })
}

/// Replace the rollback pins (bands across their box).
///
/// # Safety
/// As timeline_set_estate_events, for `pins`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_estate_pins(
    h: *mut TimelineHandle,
    pins: *const TimelineEstatePin,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { estate_handle(h) }?;
        let palette = h.timeline.palette;
        let mut out = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for p in unsafe { slice(pins, count) }? {
            // SAFETY: per this function's contract.
            let pin = unsafe {
                EstatePin {
                    box_name: p.box_name.text()?,
                    from: p.from,
                    to: time(p.to),
                    label: p.label.text()?,
                }
            };
            out.push(pin_band(&pin, &palette));
        }
        h.timeline.set_bands(out);
        Ok(())
    })
}

/// Replace the estate's density bins.
///
/// # Safety
/// As timeline_set_estate_events, for `bins`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_estate_bins(
    h: *mut TimelineHandle,
    bins: *const TimelineEstateBin,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { estate_handle(h) }?;
        let p = h.timeline.palette;
        let mut out = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for b in unsafe { slice(bins, count) }? {
            // SAFETY: per this function's contract.
            let (box_name, surface) = unsafe { (b.box_name.text()?, optional(b.surface)?) };
            let (row, kind_row) = match b.row {
                0 => (Row::Rollouts, 0),
                1 => (Row::Backups, 1),
                2 => (Row::Cleanups, 2),
                _ => return Err(Failure::Invalid("an unknown estate row")),
            };
            let key = match (h.lens, surface) {
                (TimelineLens::Backups, Some(s)) => backup_row(&box_name, &s),
                (TimelineLens::Backups, None) => continue,
                _ => estate_row(&box_name, row),
            };
            let (color, grow) = match kind_row {
                0 => (p.warning.with_alpha(0.6), 2.4),
                1 => (p.ok.with_alpha(0.55), 2.4),
                _ => (p.data.with_alpha(0.35), 1.2),
            };
            out.push(Bin {
                row: key,
                from: b.from,
                width: b.width,
                count: b.count,
                failures: b.failures,
                scheduled: b.scheduled,
                color,
                grow,
            });
        }
        h.timeline.set_bins(out);
        Ok(())
    })
}

/// The Estate lens's lanes: one per box, top to bottom, its rows Rollouts / Backups / Cleanups.
///
/// # Safety
/// `h` is a live Estate handle; `boxes` is valid for `count` texts for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_set_estate_boxes(
    h: *mut TimelineHandle,
    boxes: *const TimelineStr,
    count: usize,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { estate_handle(h) }?;
        let mut groups = Vec::with_capacity(count);
        // SAFETY: per this function's contract.
        for b in unsafe { slice(boxes, count) }? {
            // SAFETY: per this function's contract.
            groups.push(estate_group(&unsafe { b.text() }?, None));
        }
        h.timeline.set_groups(groups);
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &str) -> TimelineStr {
        TimelineStr {
            ptr: text.as_ptr(),
            len: text.len(),
        }
    }

    fn rgba(v: f32) -> TimelineRgba {
        TimelineRgba {
            r: v,
            g: v,
            b: v,
            a: 1.0,
        }
    }

    #[test]
    fn the_header_constants_are_the_engine_s() {
        assert_eq!(TIMELINE_AXIS_PT, timeline::geometry::AXIS_PT);
        assert_eq!(TIMELINE_LABEL_W, timeline::timeline::LABEL_W);
    }

    #[test]
    fn a_handle_takes_jobs_groups_and_keys_without_a_gpu() {
        let palette = TimelinePalette {
            background: rgba(0.1),
            band: rgba(0.12),
            foreground: rgba(0.9),
            muted: rgba(0.6),
            grid: rgba(0.2),
            data: rgba(0.5),
            ok: rgba(0.4),
            danger: rgba(0.8),
            warning: rgba(0.7),
            accent: rgba(0.95),
        };
        let now = 1_792_000_000_000.0;
        let mut h = std::ptr::null_mut();
        let mut err = std::ptr::null_mut();
        // SAFETY: valid pointers for every call below.
        unsafe {
            assert_eq!(
                timeline_new(0, &palette, now, &mut h, &mut err),
                TIMELINE_OK
            );
            let rows = [TimelineRow {
                key: s("lane-a"),
                label: s("lane a"),
                tint: rgba(0.3),
                has_tint: true,
            }];
            let groups = [TimelineGroup {
                key: s("exampleapp"),
                label: s("ExampleApp"),
                rows: rows.as_ptr(),
                row_count: 1,
            }];
            assert_eq!(
                timeline_set_groups(h, groups.as_ptr(), 1, &mut err),
                TIMELINE_OK
            );
            let job = TimelineCiJob {
                id: s("j1"),
                lane: s("lane-a"),
                repo: s("ExampleApp"),
                name: s("build"),
                queued_at: now - 3_600_000.0,
                started_at: now - 3_500_000.0,
                completed_at: now - 3_000_000.0,
                result: TIMELINE_RESULT_SUCCEEDED,
                peak_mib: u32::MAX,
                reserved_mib: u32::MAX,
            };
            assert_eq!(timeline_set_ci_jobs(h, &job, 1, &mut err), TIMELINE_OK);
            assert_eq!(
                timeline_key(h, TimelineIntent::OutcomeBack as u8, &mut err),
                TIMELINE_OK
            );
            let id = timeline_selected(h);
            assert_eq!(std::ffi::CStr::from_ptr(id).to_str(), Ok("j1"));
            timeline_string_free(id);
            assert_eq!(timeline_state(h).playhead, now - 3_000_000.0);
            let bad = TimelineCiJob { result: 9, ..job };
            assert_eq!(timeline_set_ci_jobs(h, &bad, 1, &mut err), TIMELINE_INVALID);
            assert!(!err.is_null());
            timeline_string_free(err);
            let mut frame = TimelineFrame::default();
            assert_eq!(
                timeline_frame(h, &mut frame, std::ptr::null_mut()),
                TIMELINE_OK
            );
            assert!(!frame.presented, "a detached handle draws nothing");
            timeline_free(h);
        }
    }
}
