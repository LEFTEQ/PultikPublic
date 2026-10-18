//! The diff's C ABI (vt-7887): Pultík's Files changed and its definition card, drawn by
//! `canvas_text::diff_view` — the diff view the editor islands draw with too — on the shared device.
//! Swift hands it the change set (the files code-core's `DiffDocument` is built from), each file
//! side's highlights as they land, the decor (marks, the comment's anchor, the ringed file) and
//! the gestures; the engine owns the rows, wrapping, scrolling (a key's jump eases), the sticky
//! header, selection, hit tests and drawing. Points are the view's, from its top-left.

use super::{
    CanvasFrameReport, CanvasRgba, CanvasStatus, CanvasStr, Failure, Surface, call, owned, slice,
};
use canvas_draw::{DisplayList, Point, Rgba, Size};
use canvas_gpu::FrameOutcome;
use canvas_text::code_view::CodeColors;
use canvas_text::diff_view::{DiffDecor, DiffHit, DiffMetrics, DiffMode, DiffView};
use code_core::diff::{ChangedFile, DiffDocument, FileNote, FileStatus, Side};
use code_core::syntax::{LineTokens, TokenRun};
use std::collections::HashSet;
use std::ffi::{c_char, c_void};
use std::ops::RangeInclusive;
use std::time::{Duration, Instant};
use theme::SyntaxRole;

pub const CANVAS_DIFF_STATUS_ADDED: u8 = 0;
pub const CANVAS_DIFF_STATUS_REMOVED: u8 = 1;
pub const CANVAS_DIFF_STATUS_MODIFIED: u8 = 2;
pub const CANVAS_DIFF_STATUS_RENAMED: u8 = 3;
pub const CANVAS_DIFF_STATUS_COPIED: u8 = 4;
pub const CANVAS_DIFF_STATUS_CHANGED: u8 = 5;
pub const CANVAS_DIFF_STATUS_UNCHANGED: u8 = 6;

pub const CANVAS_DIFF_SIDE_OLD: u8 = 0;
pub const CANVAS_DIFF_SIDE_NEW: u8 = 1;

pub const CANVAS_DIFF_HIT_NONE: u8 = 0;
pub const CANVAS_DIFF_HIT_HEADER: u8 = 1;
pub const CANVAS_DIFF_HIT_GUTTER: u8 = 2;
pub const CANVAS_DIFF_HIT_CODE: u8 = 3;
pub const CANVAS_DIFF_HIT_NOTE: u8 = 4;

/// How the change is laid out: one column, or the old side beside the new (GitHub's split).
pub const CANVAS_DIFF_MODE_INLINE: u8 = 0;
pub const CANVAS_DIFF_MODE_SPLIT: u8 = 1;

/// A key's scroll: three lines, a page (less a little overlap) or to an edge.
pub const CANVAS_DIFF_STEP_LINE: u8 = 0;
pub const CANVAS_DIFF_STEP_PAGE: u8 = 1;
pub const CANVAS_DIFF_STEP_EDGE: u8 = 2;

/// How long a key's jump eases (the CoreText canvas's 0.14 s).
pub(crate) const GLIDE: Duration = Duration::from_millis(140);
/// The line height Pultík's code reads at, whatever the font's own: 18 pt (D9, docs/specs/2026-10-15-pr-workbench-decisions.md).
pub(crate) const LINE_HEIGHT: f32 = 18.0;

/// One file of the change set: what its rows and header need.
#[repr(C)]
pub struct CanvasDiffFile {
    pub path: CanvasStr,
    /// Empty when the file kept its name.
    pub previous_path: CanvasStr,
    /// Ignored unless `has_patch`: a binary file, one the source would not diff, or one past
    /// the patch budget has none.
    pub patch: CanvasStr,
    pub has_patch: bool,
    /// The patch was cut at its source's line limit or dropped past its byte budget.
    pub trimmed: bool,
    /// A CANVAS_DIFF_STATUS_*.
    pub status: u8,
    pub additions: u32,
    pub deletions: u32,
    /// The side's highlights are of its whole blob (its line numbers), not the patch's text.
    pub has_old_blob: bool,
    pub has_new_blob: bool,
}

/// One highlighted run: `start` and `length` in UTF-16 units from its line's start, `kind`
/// code-core's (`CODE_CORE_*` token kinds: 0 plain, then each syntax role + 1).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CanvasDiffRun {
    pub start: u32,
    pub length: u32,
    pub kind: u8,
}

/// A gutter mark: a line (an index into its file's lines) with a pending comment or a thread.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CanvasDiffMark {
    pub file: u32,
    pub index: u32,
}

/// What a point is over: a CANVAS_DIFF_HIT_* `kind`, its file, and the line's index (gutter
/// and code hits).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CanvasDiffHit {
    pub kind: u8,
    pub file: u32,
    pub index: u32,
}

/// Where the view is: the files at its top and bottom edges (-1: none; what the host
/// highlights first), its scroll and height in points, its
/// rows and drawn lines, and the files with highlights on at least one side.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CanvasDiffState {
    pub top_file: i64,
    pub bottom_file: i64,
    pub top: f64,
    pub height: f64,
    pub rows: u32,
    pub lines: u32,
    pub highlighted: u32,
    pub has_selection: bool,
    pub wraps: bool,
    /// Side by side (CANVAS_DIFF_MODE_SPLIT); a selection is inline only.
    pub split: bool,
}

/// An eased jump in flight.
struct Glide {
    from: f64,
    to: f64,
    start: Instant,
}

/// One diff on screen.
pub struct CanvasDiff {
    view: DiffView,
    colors: CodeColors,
    accent: Rgba,
    focused: Option<usize>,
    marks: Vec<(usize, usize)>,
    anchor: Option<(usize, RangeInclusive<usize>)>,
    font_size: f32,
    renderer: Option<Surface>,
    dl: DisplayList,
    glide: Option<Glide>,
    /// Something drawn changed since the last frame.
    dirty: bool,
    /// The shared atlas's generation at the last build.
    built_at: u64,
}

/// # Safety
/// `h` is null (refused) or a live diff handle used by this thread alone.
unsafe fn diff<'a>(h: *mut CanvasDiff) -> Result<&'a mut CanvasDiff, Failure> {
    // SAFETY: per this function's contract.
    unsafe { h.as_mut() }.ok_or(Failure::Invalid("a null diff handle"))
}

pub(crate) fn colors(id: &str) -> Result<CodeColors, Failure> {
    let theme = theme::by_id(id).ok_or(Failure::Invalid("an unknown code theme"))?;
    Ok(CodeColors::new(theme))
}

fn status(code: u8) -> Result<FileStatus, Failure> {
    Ok(match code {
        CANVAS_DIFF_STATUS_ADDED => FileStatus::Added,
        CANVAS_DIFF_STATUS_REMOVED => FileStatus::Removed,
        CANVAS_DIFF_STATUS_MODIFIED => FileStatus::Modified,
        CANVAS_DIFF_STATUS_RENAMED => FileStatus::Renamed,
        CANVAS_DIFF_STATUS_COPIED => FileStatus::Copied,
        CANVAS_DIFF_STATUS_CHANGED => FileStatus::Changed,
        CANVAS_DIFF_STATUS_UNCHANGED => FileStatus::Unchanged,
        _ => return Err(Failure::Invalid("an unknown file status")),
    })
}

/// Why a file shows a note, in Pultík's words.
fn words(note: FileNote) -> String {
    match note {
        FileNote::PastBudget => "Past the patch budget — ⌘↵ opens it on the host".into(),
        FileNote::NoDiff => "No diff — binary, renamed or empty".into(),
        FileNote::Folded { lines, generated } => format!(
            "{lines} lines, {} — click the header or ↵ to show",
            if generated { "generated" } else { "long" }
        ),
        FileNote::CutHere => "Diff cut here — ⌘↵ opens the rest on the host".into(),
        FileNote::HostListsFirst { files } => {
            format!("The host lists the first {files} files — ⌘↵ opens the rest")
        }
    }
}

/// The code cell at the shared text system's mono font and `font_size`: its advance (whole
/// device pixels at `scale`), Pultík's line height.
pub(crate) fn metrics(
    text: &mut canvas_text::TextSystem,
    font_size: f32,
    scale: f64,
) -> DiffMetrics {
    text.set_term_font(None, font_size);
    let scale = scale.max(1.0) as f32;
    let (w, _) = text.term_metrics().cell_px(font_size * scale);
    DiffMetrics::for_cell(Size::new(w as f32 / scale, LINE_HEIGHT), font_size)
}

/// Byte `units` UTF-16 units into `line`, at a char boundary.
pub(crate) fn byte_of(line: &str, units: u32) -> u32 {
    let mut seen = 0;
    for (at, c) in line.char_indices() {
        if seen >= units {
            return at as u32;
        }
        seen += c.len_utf16() as u32;
    }
    line.len() as u32
}

impl CanvasDiff {
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
        let y = g.from + (g.to - g.from) * eased;
        self.view.set_top(y);
        self.dirty = true;
        if t >= 1.0 {
            self.glide = None;
        }
        t < 1.0
    }
}

/// A new, empty diff at `font_size` points in code theme `theme` (a `themes.json` id), with
/// the host's `accent`. Free it with canvas_diff_free.
///
/// # Safety
/// `theme` is valid for the call; `out` is valid; `error` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_new(
    theme: CanvasStr,
    accent: CanvasRgba,
    font_size: f32,
    out: *mut *mut CanvasDiff,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        // SAFETY: per this function's contract.
        let colors = colors(&unsafe { theme.text() }?)?;
        let metrics = DiffMetrics::for_cell(Size::new(font_size * 0.6, LINE_HEIGHT), font_size);
        let empty = DiffDocument::new(Vec::new(), false, &HashSet::new());
        let h = Box::new(CanvasDiff {
            view: DiffView::new(empty, metrics, true),
            dl: DisplayList::new(colors.background()),
            colors,
            accent: accent.into(),
            focused: None,
            marks: Vec::new(),
            anchor: None,
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

/// Free a diff (detaching it first).
///
/// # Safety
/// `h` is null or a handle from canvas_diff_new, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_free(h: *mut CanvasDiff) {
    if !h.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Draw into `layer` (a `CAMetalLayer *`), `width` × `height` points at `scale`, on the shared
/// device.
///
/// # Safety
/// `h` is a live diff; `layer` is a valid CAMetalLayer that outlives the attachment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_attach(
    h: *mut CanvasDiff,
    layer: *mut c_void,
    width: f64,
    height: f64,
    scale: f64,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { diff(h) }?;
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

/// Stop drawing into the layer; the change, the scroll and the shared device stay.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_detach(h: *mut CanvasDiff) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.renderer = None;
        h.glide = None;
        h.dirty = true;
    }
}

/// The surface is now `width` × `height` points at `scale`: a new width wraps again, keeping the
/// line at the top.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_resize(
    h: *mut CanvasDiff,
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

/// The change set: `count` files (`truncated` when the host stopped listing before the last),
/// with the folds of the `toggled_count` paths in `toggled` flipped from their default. The
/// reader's place and every highlight survive a call that lists the same files (a fold).
///
/// # Safety
/// `files` and `toggled` are null with a zero count, or valid for theirs, for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_files(
    h: *mut CanvasDiff,
    files: *const CanvasDiffFile,
    count: usize,
    truncated: bool,
    toggled: *const CanvasStr,
    toggled_count: usize,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, files, toggled) = unsafe {
            (
                diff(h)?,
                slice(files, count)?,
                slice(toggled, toggled_count)?,
            )
        };
        let mut changed = Vec::with_capacity(files.len());
        for f in files {
            // SAFETY: per this function's contract.
            let (path, previous, patch) =
                unsafe { (f.path.text()?, f.previous_path.text()?, f.patch.text()?) };
            changed.push(ChangedFile {
                path: path.to_string(),
                previous_path: (!previous.is_empty()).then(|| previous.to_string()),
                status: status(f.status)?,
                additions: f.additions,
                deletions: f.deletions,
                patch: f.has_patch.then(|| patch.to_string()),
                trimmed: f.trimmed,
                // Only their presence is read: highlights then follow the blob's line numbers.
                old_blob: f.has_old_blob.then(String::new),
                new_blob: f.has_new_blob.then(String::new),
            });
        }
        let mut flipped = HashSet::new();
        for t in toggled {
            // SAFETY: per this function's contract.
            flipped.insert(unsafe { t.text() }?.to_string());
        }
        h.view
            .set_document(DiffDocument::new(changed, truncated, &flipped));
        h.dirty = true;
        Ok(())
    })
}

/// One side (CANVAS_DIFF_SIDE_*) of file `file`'s highlights: `line_count + 1` entries of
/// `line_starts` index each source line's runs in `runs` (code-core's `CodeCoreTokens`, as
/// Swift's `LineTokens` holds them). Lines the diff does not draw are dropped.
///
/// # Safety
/// `runs` and `line_starts` are null with a zero count, or valid for theirs, for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_tokens(
    h: *mut CanvasDiff,
    file: u32,
    side: u8,
    runs: *const CanvasDiffRun,
    run_count: usize,
    line_starts: *const u32,
    line_start_count: usize,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, runs, starts) = unsafe {
            (
                diff(h)?,
                slice(runs, run_count)?,
                slice(line_starts, line_start_count)?,
            )
        };
        let side = match side {
            CANVAS_DIFF_SIDE_OLD => Side::Old,
            CANVAS_DIFF_SIDE_NEW => Side::New,
            _ => return Err(Failure::Invalid("an unknown side")),
        };
        let f = h
            .view
            .document()
            .files
            .get(file as usize)
            .ok_or(Failure::Invalid("a file past the change set"))?;
        // Each drawn line's text, by its source line: the runs' units are counted in it.
        let mut texts: Vec<Option<&str>> = vec![None; starts.len().saturating_sub(1)];
        for index in 0..f.lines.len() {
            if let Some(n) = f.source_line(index, side)
                && let Some(slot) = texts.get_mut(n as usize)
            {
                *slot = Some(&f.lines[index].text);
            }
        }
        let lines = texts.iter().enumerate().map(|(n, text)| {
            let (a, b) = (starts[n] as usize, starts[n + 1] as usize);
            let line_runs = runs.get(a.min(b)..b.min(runs.len())).unwrap_or(&[]);
            text.map(|text| {
                line_runs
                    .iter()
                    .filter_map(|r| {
                        let role = SyntaxRole::ALL.get(usize::from(r.kind).checked_sub(1)?)?;
                        let start = byte_of(text, r.start);
                        let end = byte_of(text, r.start + r.length);
                        (end > start).then_some(TokenRun {
                            start,
                            len: end - start,
                            role: *role,
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
        });
        let tokens = LineTokens::from_lines(lines);
        h.view.set_tokens(file as usize, side, tokens);
        h.dirty = true;
        Ok(())
    })
}

/// Wrap long lines under the gutter (the line at the top stays there).
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_wraps(h: *mut CanvasDiff, wraps: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.set_wraps(wraps);
        h.dirty = true;
    }
}

/// Lay the change out inline or side by side (a CANVAS_DIFF_MODE_*): the line at the top stays
/// there, and a selection is dropped (side by side has none).
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_mode(h: *mut CanvasDiff, mode: u8) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.set_mode(match mode {
            CANVAS_DIFF_MODE_SPLIT => DiffMode::Split,
            _ => DiffMode::Inline,
        });
        h.dirty = true;
    }
}

/// Draw in code theme `theme` with the host's `accent`: runs are roles, so nothing re-highlights.
///
/// # Safety
/// `h` is a live diff; `theme` is valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_theme(
    h: *mut CanvasDiff,
    theme: CanvasStr,
    accent: CanvasRgba,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, id) = unsafe { (diff(h)?, theme.text()?) };
        h.colors = colors(&id)?;
        h.dl.clear = h.colors.background();
        h.accent = accent.into();
        h.dirty = true;
        Ok(())
    })
}

/// What sits over the code: the ringed file (`focused` < 0: none), `mark_count` gutter marks,
/// and the lines of `anchor_file` (< 0: none) from `anchor_first` to `anchor_last` a comment is
/// being written about.
///
/// # Safety
/// `marks` is null with a zero count, or valid for it, for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_set_decor(
    h: *mut CanvasDiff,
    focused: i64,
    marks: *const CanvasDiffMark,
    mark_count: usize,
    anchor_file: i64,
    anchor_first: u32,
    anchor_last: u32,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, marks) = unsafe { (diff(h)?, slice(marks, mark_count)?) };
        h.focused = usize::try_from(focused).ok();
        h.marks = marks
            .iter()
            .map(|m| (m.file as usize, m.index as usize))
            .collect();
        h.marks.sort_unstable();
        h.anchor = usize::try_from(anchor_file).ok().map(|f| {
            (
                f,
                anchor_first as usize..=anchor_last.max(anchor_first) as usize,
            )
        });
        h.dirty = true;
        Ok(())
    })
}

/// Two fingers moved the content by (`dx`, `dy`) points: positive scrolls toward the end. It
/// stops a key's jump.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_scroll(h: *mut CanvasDiff, dx: f64, dy: f64) {
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
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_step(h: *mut CanvasDiff, step: u8, sign: i8, animated: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        let from = h.glide.as_ref().map_or(h.view.top(), |g| g.to);
        let line = f64::from(h.view.metrics().cell.h);
        let page = (f64::from(h.view.size().h) - 48.0).max(line * 3.0);
        let s = f64::from(sign.signum());
        let y = match step {
            CANVAS_DIFF_STEP_LINE => from + s * line * 3.0,
            CANVAS_DIFF_STEP_PAGE => from + s * page,
            _ if sign > 0 => h.view.max_top(),
            _ => 0.0,
        };
        h.glide_to(y, animated);
    }
}

/// File `file`'s header at the top (⇥'s ring, the tree's click), eased unless not `animated`.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_reveal_file(h: *mut CanvasDiff, file: u32, animated: bool) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() }
        && let Some(y) = h.view.header_top(file as usize)
    {
        h.glide_to(y, animated);
    }
}

/// File `file`'s new-side line `line` (1-based) a third of the way down, eased unless not
/// `animated` (Reduce Motion); its index in
/// the file's lines (for the host's anchor), or -1 when the diff does not draw it (the file's
/// header comes to the top instead).
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_reveal_line(
    h: *mut CanvasDiff,
    file: u32,
    line: u32,
    animated: bool,
) -> i64 {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_mut() }) else {
        return -1;
    };
    let file = file as usize;
    match h.view.line_top(file, line) {
        Some(y) => {
            let third = f64::from(h.view.size().h) / 3.0;
            h.glide_to(y - third, animated);
            h.view.document().files[file]
                .lines
                .iter()
                .position(|l| l.new == Some(line))
                .map_or(-1, |i| i as i64)
        }
        None => {
            if let Some(y) = h.view.header_top(file) {
                h.glide_to(y, animated);
            }
            -1
        }
    }
}

/// What view point (`x`, `y`) is over.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_hit(h: *mut CanvasDiff, x: f64, y: f64) -> CanvasDiffHit {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return CanvasDiffHit::default();
    };
    let at = |kind, file: usize, index: usize| CanvasDiffHit {
        kind,
        file: file as u32,
        index: index as u32,
    };
    match h.view.hit(Point::new(x as f32, y as f32)) {
        DiffHit::Header { file } => at(CANVAS_DIFF_HIT_HEADER, file, 0),
        DiffHit::Gutter { file, index } => at(CANVAS_DIFF_HIT_GUTTER, file, index),
        DiffHit::Code { file, index, .. } => at(CANVAS_DIFF_HIT_CODE, file, index),
        DiffHit::Note { file } => at(CANVAS_DIFF_HIT_NOTE, file, 0),
        DiffHit::None => CanvasDiffHit::default(),
    }
}

/// A press at (`x`, `y`) starts a selection there.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_select_begin(h: *mut CanvasDiff, x: f64, y: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.select_begin(Point::new(x as f32, y as f32));
        h.dirty = true;
    }
}

/// A drag to (`x`, `y`) moves the selection's head.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_select_extend(h: *mut CanvasDiff, x: f64, y: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.select_extend(Point::new(x as f32, y as f32));
        h.dirty = true;
    }
}

/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_select_clear(h: *mut CanvasDiff) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.view.clear_selection();
        h.dirty = true;
    }
}

/// ⌘C: the selected lines' own text, tabs as written; null with no selection. Free it with
/// canvas_string_free.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_selected_text(h: *mut CanvasDiff) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }
        .and_then(|h| h.view.selected_text())
        .map_or(std::ptr::null_mut(), |t| owned(&t))
}

/// The identifier under (`x`, `y`), and its file into `file`: what a hover peeks and ⌘-click
/// follows; null off one. Free it with canvas_string_free.
///
/// # Safety
/// `h` is null or a live diff; `file` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_word_at(
    h: *mut CanvasDiff,
    x: f64,
    y: f64,
    file: *mut u32,
) -> *mut c_char {
    // SAFETY: per this function's contract.
    let Some((f, word)) =
        (unsafe { h.as_ref() }).and_then(|h| h.view.word_at(Point::new(x as f32, y as f32)))
    else {
        return std::ptr::null_mut();
    };
    if !file.is_null() {
        // SAFETY: per this function's contract.
        unsafe { file.write(f as u32) };
    }
    owned(&word)
}

/// The rows in view as text, one per line (the panel driver's reading). Free it with
/// canvas_string_free.
///
/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_visible_text(h: *mut CanvasDiff) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }.map_or(std::ptr::null_mut(), |h| owned(&h.view.visible_text()))
}

/// # Safety
/// `h` is null or a live diff.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_state(h: *mut CanvasDiff) -> CanvasDiffState {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_ref() }) else {
        return CanvasDiffState::default();
    };
    let doc = h.view.document();
    let highlighted = (0..doc.files.len())
        .filter(|&f| h.view.has_tokens(f, Side::Old) || h.view.has_tokens(f, Side::New))
        .count();
    let lines = doc
        .rows
        .iter()
        .filter(|r| matches!(r, code_core::diff::DocRow::Line { .. }))
        .count();
    CanvasDiffState {
        top_file: h.view.top_file().map_or(-1, |f| f as i64),
        bottom_file: h.view.bottom_file().map_or(-1, |f| f as i64),
        top: h.view.top(),
        height: h.view.height(),
        rows: h.view.rows().len() as u32,
        lines: lines as u32,
        highlighted: highlighted as u32,
        has_selection: h.view.has_selection(),
        wraps: h.view.wraps(),
        split: h.view.mode() == DiffMode::Split,
    }
}

/// Draw a frame if anything changed (or a key's jump is in flight). Call it from the display
/// link while it reports `animating`, and after any input.
///
/// # Safety
/// `h` is a live diff; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canvas_diff_frame(
    h: *mut CanvasDiff,
    out: *mut CanvasFrameReport,
    error: *mut *mut c_char,
) -> CanvasStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { diff(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let mut frame = CanvasFrameReport::default();
        let gliding = h.advance_glide();
        if let Some(mut r) = h.renderer.take() {
            let result = r.with(|gpu, target, text| -> Result<(), Failure> {
                if h.dirty || h.built_at != text.atlas().generation() {
                    let decor = DiffDecor {
                        accent: h.accent,
                        focused: h.focused,
                        marks: &h.marks,
                        anchor: h.anchor.clone(),
                        indicator: true,
                    };
                    let mut ops = std::mem::take(&mut h.dl.ops);
                    // The last frame's blocks go back to the view before it fills them again.
                    ops.clear();
                    h.view.paint(&h.colors, &decor, &words, &mut ops);
                    h.dl.ops = ops;
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

    fn file<'a>(path: &'a str, patch: &'a str) -> CanvasDiffFile {
        CanvasDiffFile {
            path: s(path),
            previous_path: s(""),
            patch: s(patch),
            has_patch: true,
            trimmed: false,
            status: CANVAS_DIFF_STATUS_MODIFIED,
            additions: 1,
            deletions: 1,
            has_old_blob: false,
            has_new_blob: false,
        }
    }

    /// A diff of `files` in an 800 × 120 pt view, not attached (no GPU).
    fn diff(files: &[CanvasDiffFile]) -> *mut CanvasDiff {
        let mut h = std::ptr::null_mut();
        let accent = CanvasRgba {
            r: 1.0,
            g: 0.6,
            b: 0.0,
            a: 1.0,
        };
        // SAFETY: valid arguments for the calls.
        unsafe {
            let id = theme::DEFAULT_ID;
            let status = canvas_diff_new(s(id), accent, 12.0, &mut h, std::ptr::null_mut());
            assert_eq!(status, crate::CANVAS_OK);
            let status = canvas_diff_set_files(
                h,
                files.as_ptr(),
                files.len(),
                false,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
            );
            assert_eq!(status, crate::CANVAS_OK);
            canvas_diff_resize(h, 800.0, 120.0, 2.0);
        }
        h
    }

    /// Row `row`'s middle, `col` columns into the code.
    fn at(h: *mut CanvasDiff, row: usize, col: f64) -> (f64, f64) {
        // SAFETY: a live handle.
        let v = unsafe { &(*h).view };
        let (top, height) = v.frame(row);
        let x = f64::from(v.code_x()) + col * f64::from(v.metrics().cell.w);
        (x, top - v.top() + height / 2.0)
    }

    const PATCH: &str = "@@ -1,3 +1,3 @@\n a\n-\tb = 1;\n+\tb = 2;\n d";

    #[test]
    fn a_change_hits_its_header_gutter_and_code_and_copies_a_selection_as_written() {
        let h = diff(&[file("a.rs", PATCH), file("b.rs", PATCH)]);
        // SAFETY: a live handle, freed at the end.
        unsafe {
            let header = canvas_diff_hit(h, 300.0, 5.0);
            assert_eq!((header.kind, header.file), (CANVAS_DIFF_HIT_HEADER, 0));
            // Rows: the header, the hunk header, then lines 1 (" a"), 2 ("-b"), 3 ("+b").
            let (_, y) = at(h, 3, 0.0);
            let gutter = canvas_diff_hit(h, 10.0, y);
            assert_eq!(
                (gutter.kind, gutter.file, gutter.index),
                (CANVAS_DIFF_HIT_GUTTER, 0, 2)
            );
            let (x, y) = at(h, 2, 0.0);
            assert_eq!(canvas_diff_hit(h, x + 30.0, y).kind, CANVAS_DIFF_HIT_CODE);
            canvas_diff_select_begin(h, x, y);
            let (x, y) = at(h, 4, 4.0);
            canvas_diff_select_extend(h, x, y);
            assert!(canvas_diff_state(h).has_selection);
            let text = canvas_diff_selected_text(h);
            assert_eq!(CStr::from_ptr(text).to_str(), Ok("a\n\tb = 1;\n\t"));
            crate::canvas_string_free(text);
            canvas_diff_free(h);
        }
    }

    #[test]
    fn utf16_runs_land_on_their_bytes_and_unknown_kinds_are_plain() {
        assert_eq!(byte_of("名前 = 1", 3), 7);
        assert_eq!(byte_of("名前 = 1", 99), "名前 = 1".len() as u32);
        let patch = "@@ -1 +1 @@\n-名前 = 1\n+name = 1";
        let h = diff(&[file("a.rs", patch)]);
        // The old side's one source line: "=" at UTF-16 unit 3 as a keyword (role + 1).
        let runs = [
            CanvasDiffRun {
                start: 3,
                length: 1,
                kind: SyntaxRole::Keyword as u8 + 1,
            },
            CanvasDiffRun {
                start: 0,
                length: 2,
                kind: 0,
            },
        ];
        let starts = [0, 2];
        // SAFETY: a live handle and valid arrays, freed at the end.
        unsafe {
            let status = canvas_diff_set_tokens(
                h,
                0,
                CANVAS_DIFF_SIDE_OLD,
                runs.as_ptr(),
                runs.len(),
                starts.as_ptr(),
                starts.len(),
                std::ptr::null_mut(),
            );
            assert_eq!(status, crate::CANVAS_OK);
            assert_eq!(canvas_diff_state(h).highlighted, 1);
            canvas_diff_free(h);
        }
    }

    #[test]
    fn reveal_names_the_lines_index_and_a_file_comes_to_the_top() {
        let h = diff(&[file("a.rs", PATCH), file("b.rs", PATCH)]);
        // SAFETY: a live handle, freed at the end.
        unsafe {
            // New-side line 3 is " d": index 4 (the removed line has no new number).
            assert_eq!(canvas_diff_reveal_line(h, 1, 3, true), 4);
            assert_eq!(canvas_diff_reveal_line(h, 1, 99, false), -1);
            canvas_diff_reveal_file(h, 1, false);
            assert_eq!(canvas_diff_state(h).top_file, 1);
            // Side by side pairs the lines: the same change, fewer rows.
            let inline = canvas_diff_state(h).rows;
            canvas_diff_set_mode(h, CANVAS_DIFF_MODE_SPLIT);
            let state = canvas_diff_state(h);
            assert!(state.split && state.rows < inline);
            // A key's jump eases toward its target.
            canvas_diff_step(h, CANVAS_DIFF_STEP_EDGE, -1, true);
            assert!((*h).glide.as_ref().is_some_and(|g| g.to == 0.0));
            canvas_diff_free(h);
        }
    }
}
