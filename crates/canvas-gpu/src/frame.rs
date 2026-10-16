//! CPU half of a frame: a [`DisplayList`] becomes instance arrays for the three instanced
//! pipelines and path triangles for the fourth, plus an ordered batch list (painter's order
//! is kept by switching pipelines in sequence; clips become scissor rects; a camera layer's
//! batches are marked `world` and placed by the target's camera on the GPU). No GPU is touched here, so it is unit-testable and its cost
//! is what CI gates (D12).

use crate::tess::{Geometry, Tessellator};
use bytemuck::{Pod, Zeroable};
use canvas_draw::cells::{Cell, CellFrame, CursorShape, flags};
use canvas_draw::{
    Align, CellGrid, CodeBlock, ColorSpan, CursorPaint, DisplayList, Follow, Highlight, Image, Op,
    PathOp, Point, Raster, Rect, Rgba, RoundedRect, TextRun,
};
use canvas_text::{
    AtlasEntry, AtlasKey, FontSpec, GlyphKey, PAGE_SIZE, PageKind, SpriteKey, TextSystem, sprite,
};
use std::ops::Range;

/// Opacity of faint (SGR 2) text.
const FAINT_ALPHA: f32 = 0.5;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct RectInstance {
    pub quad: [f32; 4],
    pub shape: [f32; 4],
    pub fill: [f32; 4],
    pub border_color: [f32; 4],
    /// radius, border width, softness, pinned (1: a camera moves its centre, keeps its size).
    pub params: [f32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct GlyphInstance {
    pub quad: [f32; 4],
    pub uv: [f32; 4],
    pub color: [f32; 4],
    /// Atlas layer, and flags: [`GLYPH_COLOR`], [`GLYPH_STRETCH`].
    pub page: [u32; 2],
    /// In a camera layer, the pen in world pixels (`quad`'s origin is then its offset).
    pub anchor: [f32; 2],
}

/// A colour glyph or an image, drawn from the RGBA atlas.
pub const GLYPH_COLOR: u32 = 1;
/// An image in a camera layer: the camera stretches its quad instead of moving its pen.
pub const GLYPH_STRETCH: u32 = 2;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct CellInstance {
    pub quad: [f32; 4],
    pub color: [f32; 4],
}

/// One path triangle vertex in pixels (world pixels in a camera layer).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct PathVertex {
    pub pos: [f32; 2],
    /// Distance along the stroke in pixels (0 in a fill).
    pub advance: f32,
    /// Premultiplied RGBA8.
    pub color: u32,
    /// on, off, phase, speed in pixels; `on <= 0` is solid.
    pub dash: [f32; 4],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pipeline {
    Rect,
    Glyph,
    Cell,
    /// Indexed triangles of [`Frame::path_vertices`], drawn only in a 4× MSAA pass.
    Path,
}

/// A contiguous instance range (an index range for [`Pipeline::Path`]) drawn with one
/// pipeline under one scissor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    pub pipeline: Pipeline,
    pub instances: Range<u32>,
    /// `[x, y, w, h]` in pixels; `None` = the whole target.
    pub scissor: Option<[u32; 4]>,
    /// The camera axes it follows ([`Follow::NONE`] outside a camera layer).
    pub follow: Follow,
}

/// Everything one frame draws.
#[derive(Debug, Default)]
pub struct Frame {
    pub rects: Vec<RectInstance>,
    pub glyphs: Vec<GlyphInstance>,
    pub cells: Vec<CellInstance>,
    pub path_vertices: Vec<PathVertex>,
    pub path_indices: Vec<u32>,
    pub batches: Vec<Batch>,
    pub clear: [f64; 4],
    /// The atlas was cleared while building: entries resolved earlier are stale.
    pub atlas_reset: bool,
    /// A dash flows: the frame changes with the clock, so its host keeps redrawing it.
    pub animated: bool,
    /// The clip stack's buffer, kept so a steady rebuild allocates nothing.
    clip_stack: Vec<Rect>,
    /// Paths' geometry, kept across builds.
    tess: Tessellator,
}

/// Target geometry: size in pixels and the backing scale.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Viewport {
    pub width_px: u32,
    pub height_px: u32,
    pub scale: f32,
}

struct Builder<'a> {
    frame: &'a mut Frame,
    text: &'a mut TextSystem,
    vp: Viewport,
    clips: Vec<Rect>,
    generation: u64,
    /// Whether a full atlas may be cleared to place a glyph.
    evict: bool,
    /// The camera layer being built ([`Follow::NONE`] outside one).
    follow: Follow,
    /// The text run being drawn: its pen in points (a camera layer's glyph anchor).
    run: Point,
}

impl Frame {
    /// Build a frame. If the glyph atlas overflows mid-build it is cleared and the frame is
    /// rebuilt once, without clearing again, so every glyph instance refers to the current
    /// atlas. A working set larger than the atlas leaves the glyphs that no longer fit out
    /// of that rebuilt frame rather than drawing them from slots reused under them.
    pub fn build(dl: &DisplayList, text: &mut TextSystem, vp: Viewport) -> Frame {
        let mut frame = Frame::default();
        frame.rebuild(dl, text, vp);
        frame
    }

    /// [`build`](Self::build) into this frame, reusing its buffers: a steady UI allocates
    /// nothing per frame.
    pub fn rebuild(&mut self, dl: &DisplayList, text: &mut TextSystem, vp: Viewport) {
        self.build_once(dl, text, vp, true);
        if self.atlas_reset {
            self.build_once(dl, text, vp, false);
            self.atlas_reset = true;
        }
    }

    fn build_once(&mut self, dl: &DisplayList, text: &mut TextSystem, vp: Viewport, evict: bool) {
        self.rects.clear();
        self.glyphs.clear();
        self.cells.clear();
        self.path_vertices.clear();
        self.path_indices.clear();
        self.batches.clear();
        self.clear = premul64(dl.clear);
        self.atlas_reset = false;
        self.animated = false;
        self.tess.begin_build();
        let generation = text.atlas().generation();
        let mut clips = std::mem::take(&mut self.clip_stack);
        clips.clear();
        let mut b = Builder {
            frame: self,
            text,
            vp,
            clips,
            generation,
            evict,
            follow: Follow::NONE,
            run: Point::ZERO,
        };
        for op in &dl.ops {
            match op {
                Op::Rect(r) => b.rect(r),
                Op::Text(t) => b.text_run(t),
                Op::Cells(c) => b.cells(c),
                Op::Code(c) => b.code(c),
                Op::Image(i) => b.image(i),
                Op::Path(p) => b.path(p),
                Op::PushClip(r) => {
                    let c = b.clips.last().map_or(*r, |top| top.intersect(r));
                    b.clips.push(c);
                }
                Op::PopClip => {
                    b.clips.pop();
                }
                Op::PushCamera(f) => b.follow = *f,
                Op::PopCamera => b.follow = Follow::NONE,
            }
        }
        b.frame.atlas_reset = b.text.atlas().generation() != b.generation;
        b.frame.clip_stack = std::mem::take(&mut b.clips);
    }

    pub fn instance_count(&self) -> usize {
        self.rects.len() + self.glyphs.len() + self.cells.len()
    }

    /// The frame draws paths, so its pass is multisampled.
    pub fn has_paths(&self) -> bool {
        !self.path_indices.is_empty()
    }

    /// Paths tessellated since this frame was created (cache misses).
    pub fn tessellations(&self) -> u64 {
        self.tess.misses
    }
}

/// Premultiplied RGBA8 in a path vertex's byte order.
fn premul8(c: Rgba) -> u32 {
    let [r, g, b, a] = c
        .premultiplied()
        .map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8);
    u32::from_le_bytes([r, g, b, a])
}

fn premul(c: Rgba) -> [f32; 4] {
    c.premultiplied()
}

fn premul64(c: Rgba) -> [f64; 4] {
    c.premultiplied().map(f64::from)
}

fn rgb(c: canvas_draw::cells::Rgb, a: f32) -> Rgba {
    Rgba::rgb8(c.0, c.1, c.2).with_alpha(a)
}

/// Pixel `x` as a whole pixel plus a quarter-pixel subpixel offset (`0..4`).
fn quarter_pixel(x: f32) -> (f32, u8) {
    let ix = x.floor();
    match ((x - ix) * 4.0).round() as u8 {
        4 => (ix + 1.0, 0),
        sub => (ix, sub),
    }
}

/// A grid's cell edges in device pixels: the origin snapped to a pixel and every edge
/// rounded, so cells tile with no gaps and sprites fill them exactly.
struct Grid {
    ox: f32,
    oy: f32,
    cw: f32,
    ch: f32,
}

impl Grid {
    fn x(&self, col: usize) -> f32 {
        (self.ox + col as f32 * self.cw).round()
    }
    fn y(&self, row: usize) -> f32 {
        (self.oy + row as f32 * self.ch).round()
    }
    /// `[x, y, w, h]` of `span` cells from (`col`, `row`).
    fn rect(&self, col: usize, row: usize, span: usize) -> [f32; 4] {
        let (x0, y0) = (self.x(col), self.y(row));
        [x0, y0, self.x(col + span) - x0, self.y(row + 1) - y0]
    }
}

/// A cell's foreground and painted background (`None`: the default, already painted) after
/// the current search match, the selection and other matches, in that order of precedence.
fn cell_colors(cell: &Cell, f: &dyn CellFrame, hl: &Highlight) -> (Rgba, Option<Rgba>) {
    if cell.flags & flags::MATCH_CURRENT != 0 {
        return (hl.search_current.0, Some(hl.search_current.1));
    }
    if cell.flags & flags::SELECTED != 0 {
        return match hl.selection {
            Some((fg, bg)) => (fg, Some(bg)),
            None => (rgb(cell.bg, 1.0), Some(rgb(cell.fg, 1.0))),
        };
    }
    if cell.flags & flags::MATCH != 0 {
        return (hl.search.0, Some(hl.search.1));
    }
    let bg = (cell.bg != f.default_bg()).then(|| rgb(cell.bg, 1.0));
    (rgb(cell.fg, 1.0), bg)
}

/// The colour a cell's glyph is drawn in: its foreground (faint at reduced opacity), or its
/// background under a solid block cursor.
fn glyph_color(
    cell: &Cell,
    col: usize,
    row: usize,
    f: &dyn CellFrame,
    hl: &Highlight,
    block: Option<&CursorDraw>,
) -> Rgba {
    let (fg, bg) = cell_colors(cell, f, hl);
    if block.is_some_and(|c| c.row == row && (c.col..c.col + c.span).contains(&col)) {
        return bg.unwrap_or_else(|| rgb(f.default_bg(), 1.0));
    }
    if cell.flags & flags::FAINT != 0 {
        fg.with_alpha(fg.a * FAINT_ALPHA)
    } else {
        fg
    }
}

/// The colour of column `col`: the span holding it, else `fg`. `k` keeps where the last
/// lookup stopped, so glyphs in column order walk a row's spans once.
fn span_color(spans: &[ColorSpan], k: &mut usize, col: u16, fg: Rgba) -> Rgba {
    if *k > 0 && col < spans[*k - 1].end {
        // A glyph left of the last one (right-to-left text): look from the start.
        *k = 0;
    }
    while spans.get(*k).is_some_and(|s| s.end <= col) {
        *k += 1;
    }
    match spans.get(*k) {
        Some(s) if s.start <= col => s.color,
        _ => fg,
    }
}

/// Where and how a grid's cursor draws this frame.
#[derive(Debug, Clone, Copy)]
struct CursorDraw {
    col: usize,
    row: usize,
    /// 2 on a wide char.
    span: usize,
    color: Rgba,
    shape: CursorShape,
    hollow: bool,
}

fn cursor_draw(g: &CellGrid) -> Option<CursorDraw> {
    let f = &*g.frame;
    let cursor = f.cursor();
    if g.cursor == CursorPaint::Hidden || !cursor.visible {
        return None;
    }
    let row = cursor.row as usize;
    let mut col = cursor.col as usize;
    let cells = (row < f.row_count()).then(|| f.row(row))?;
    let cell = cells.get(col)?;
    let mut span = 1;
    if cell.flags & flags::WIDE_SPACER != 0 && col > 0 {
        col -= 1;
        span = 2;
    } else if cell.flags & flags::WIDE != 0 && col + 1 < cells.len() {
        span = 2;
    }
    let color = f
        .cursor_color()
        .map(|c| rgb(c, 1.0))
        .or(g.cursor_color)
        .unwrap_or_else(|| rgb(f.default_fg(), 1.0));
    Some(CursorDraw {
        col,
        row,
        span,
        color,
        shape: cursor.shape,
        hollow: g.cursor == CursorPaint::Unfocused,
    })
}

impl Builder<'_> {
    fn s(&self) -> f32 {
        self.vp.scale
    }

    /// Inside a camera layer: glyphs anchor at their run, images stretch.
    fn in_camera(&self) -> bool {
        self.follow != Follow::NONE
    }

    /// The current scissor in pixels; `Some([.., 0, 0])` when the clip is empty.
    fn scissor(&self) -> Option<[u32; 4]> {
        let clip = self.clips.last()?;
        let s = self.s();
        let x0 = (clip.x * s).floor().clamp(0.0, self.vp.width_px as f32);
        let y0 = (clip.y * s).floor().clamp(0.0, self.vp.height_px as f32);
        let x1 = (clip.max_x() * s)
            .ceil()
            .clamp(0.0, self.vp.width_px as f32);
        let y1 = (clip.max_y() * s)
            .ceil()
            .clamp(0.0, self.vp.height_px as f32);
        Some([
            x0 as u32,
            y0 as u32,
            (x1 - x0).max(0.0) as u32,
            (y1 - y0).max(0.0) as u32,
        ])
    }

    fn clipped_out(&self) -> bool {
        matches!(self.scissor(), Some([_, _, w, h]) if w == 0 || h == 0)
    }

    /// Extend the last batch or start a new one for one more instance of `pipeline`.
    fn push_batch(&mut self, pipeline: Pipeline, index: u32) {
        self.push_batch_range(pipeline, index..index + 1);
    }

    /// Extend the last batch or start a new one for the instances (indices) `r`.
    fn push_batch_range(&mut self, pipeline: Pipeline, r: Range<u32>) {
        let scissor = self.scissor();
        let follow = self.follow;
        match self.frame.batches.last_mut() {
            Some(b)
                if b.pipeline == pipeline
                    && b.scissor == scissor
                    && b.follow == follow
                    && b.instances.end == r.start =>
            {
                b.instances.end = r.end;
            }
            _ => self.frame.batches.push(Batch {
                pipeline,
                instances: r,
                scissor,
                follow,
            }),
        }
    }

    /// A path's fill, then its stroke, from the tessellation cache.
    fn path(&mut self, p: &PathOp) {
        if self.clipped_out() {
            return;
        }
        let s = self.s();
        if let Some(fill) = p.fill.filter(|c| c.a > 0.0) {
            let g = self.frame.tess.fill(&p.path, s);
            self.push_geometry(&g, fill, [0.0; 4]);
        }
        if let Some(st) = p.stroke.filter(|st| st.color.a > 0.0 && st.width > 0.0) {
            let g = self.frame.tess.stroke(&p.path, &st, s);
            let dash = st.dash.filter(|d| d.on > 0.0).map_or([0.0; 4], |d| {
                [d.on * s, d.off.max(0.0) * s, d.phase * s, d.speed * s]
            });
            self.frame.animated |= dash[0] > 0.0 && dash[3] != 0.0;
            self.push_geometry(&g, st.color, dash);
        }
    }

    fn push_geometry(&mut self, g: &Geometry, color: Rgba, dash: [f32; 4]) {
        if g.indices.is_empty() {
            return;
        }
        let base = self.frame.path_vertices.len() as u32;
        let color = premul8(color);
        self.frame
            .path_vertices
            .extend(g.vertices.iter().map(|v| PathVertex {
                pos: v.pos,
                advance: v.advance,
                color,
                dash,
            }));
        let start = self.frame.path_indices.len() as u32;
        self.frame
            .path_indices
            .extend(g.indices.iter().map(|i| i + base));
        let end = self.frame.path_indices.len() as u32;
        self.push_batch_range(Pipeline::Path, start..end);
    }

    fn rect(&mut self, r: &RoundedRect) {
        if self.clipped_out() {
            return;
        }
        let s = self.s();
        let px = |r: Rect| [r.x * s, r.y * s, r.w * s, r.h * s];
        if let Some(sh) = r.shadow {
            let shape = r.rect.translate(sh.offset);
            let blur = sh.blur * s;
            let quad = px(shape);
            let quad = [
                quad[0] - 2.0 * blur,
                quad[1] - 2.0 * blur,
                quad[2] + 4.0 * blur,
                quad[3] + 4.0 * blur,
            ];
            self.push_rect(RectInstance {
                quad,
                shape: px(shape),
                fill: premul(sh.color),
                border_color: [0.0; 4],
                params: [
                    r.radius * s,
                    0.0,
                    blur.max(0.5),
                    f32::from(u8::from(r.pinned)),
                ],
            });
        }
        let (bw, bc) = r
            .border
            .map_or((0.0, [0.0; 4]), |b| (b.width * s, premul(b.color)));
        if r.fill.a <= 0.0 && bw <= 0.0 {
            return;
        }
        let shape = px(r.rect);
        // One pixel of slack for the anti-aliased edge.
        let quad = [
            shape[0] - 1.0,
            shape[1] - 1.0,
            shape[2] + 2.0,
            shape[3] + 2.0,
        ];
        self.push_rect(RectInstance {
            quad,
            shape,
            fill: premul(r.fill),
            border_color: bc,
            params: [r.radius * s, bw, 0.0, f32::from(u8::from(r.pinned))],
        });
    }

    fn push_rect(&mut self, inst: RectInstance) {
        let i = self.frame.rects.len() as u32;
        self.frame.rects.push(inst);
        self.push_batch(Pipeline::Rect, i);
    }

    fn push_cell(&mut self, quad: [f32; 4], color: Rgba) {
        let i = self.frame.cells.len() as u32;
        self.frame.cells.push(CellInstance {
            quad,
            color: premul(color),
        });
        self.push_batch(Pipeline::Cell, i);
    }

    /// An image the text system was handed (`TextSystem::set_image`), stretched over its
    /// rect from the colour atlas; one it does not have draws as a placeholder tile.
    fn image(&mut self, i: &Image) {
        if self.clipped_out() {
            return;
        }
        match self.text.entry(AtlasKey::Image(i.image.0), self.evict) {
            Some(e) if e.kind == PageKind::Color => {
                let s = self.s();
                let (x, y) = ((i.rect.x * s).round(), (i.rect.y * s).round());
                let quad = [
                    x,
                    y,
                    (i.rect.max_x() * s).round() - x,
                    (i.rect.max_y() * s).round() - y,
                ];
                if self.in_camera() {
                    self.push_glyph_at(e, quad, [0.0; 2], Rgba::WHITE, true, GLYPH_STRETCH);
                } else {
                    self.push_glyph(e, quad, Rgba::WHITE, true);
                }
            }
            _ => self.rect(&RoundedRect::new(
                i.rect,
                i.radius,
                Rgba::new(1.0, 1.0, 1.0, 0.08),
            )),
        }
    }

    fn text_run(&mut self, t: &TextRun) {
        if self.clipped_out() || t.color.a <= 0.0 {
            return;
        }
        let spec = FontSpec {
            mono: t.mono,
            weight: t.weight,
            size: t.size,
            italic: t.italic,
        };
        let shaped = match t.max_width {
            Some(w) => self.text.shape_truncated(&t.text, spec, w),
            None => self.text.shape(&t.text, spec),
        };
        let slack = t.max_width.map_or(0.0, |w| (w - shaped.width).max(0.0));
        let x = t.origin.x
            + match t.align {
                Align::Start => 0.0,
                Align::Center => slack * 0.5,
                Align::End => slack,
            };
        let baseline = t.origin.y + shaped.ascent;
        // In a camera layer the run moves as one: its glyphs keep their places in it.
        self.run = Point::new(x, baseline);
        for g in &shaped.glyphs {
            self.glyph(
                g.font,
                g.glyph,
                g.color,
                x + g.x,
                baseline + g.y,
                t.size,
                t.color,
            );
        }
    }

    /// One glyph with its pen at (`x`, `baseline`) in points.
    #[allow(clippy::too_many_arguments)]
    fn glyph(
        &mut self,
        font: u16,
        glyph: u32,
        color: bool,
        x: f32,
        baseline: f32,
        size: f32,
        tint: Rgba,
    ) {
        let s = self.s();
        // In a camera layer the run's pen is the anchor the camera moves (snapped to a pixel
        // there), and the glyph sits at its offset from it.
        let run = if self.in_camera() {
            self.run
        } else {
            Point::ZERO
        };
        let (ix, sub) = quarter_pixel((x - run.x) * s);
        let key = GlyphKey {
            font,
            glyph,
            size_q: GlyphKey::ui_size(size, s),
            subpixel: sub,
        };
        let Some(e) = self.text.entry(key.into(), self.evict) else {
            return;
        };
        if self.in_camera() {
            let by = ((baseline - run.y) * s).round();
            let quad = [
                ix + e.left as f32,
                by - e.top as f32,
                e.w as f32,
                e.h as f32,
            ];
            self.push_glyph_at(e, quad, [run.x * s, run.y * s], tint, color, 0);
            return;
        }
        let by = (baseline * s).round();
        let quad = [
            ix + e.left as f32,
            by - e.top as f32,
            e.w as f32,
            e.h as f32,
        ];
        self.push_glyph(e, quad, tint, color);
    }

    /// Draw atlas entry `e` stretched over `quad` (pixels): coverage tinted by `tint`, or a
    /// colour glyph at `tint`'s opacity. In a camera layer the camera moves its origin and
    /// keeps its size.
    fn push_glyph(&mut self, e: AtlasEntry, quad: [f32; 4], tint: Rgba, color: bool) {
        if self.in_camera() {
            let [x, y, w, h] = quad;
            self.push_glyph_at(e, [0.0, 0.0, w, h], [x, y], tint, color, 0);
        } else {
            self.push_glyph_at(e, quad, [0.0; 2], tint, color, 0);
        }
    }

    /// [`push_glyph`](Self::push_glyph) with an explicit pen `anchor` (`quad`'s origin is its
    /// offset) and extra `flags` ([`GLYPH_STRETCH`]).
    fn push_glyph_at(
        &mut self,
        e: AtlasEntry,
        quad: [f32; 4],
        anchor: [f32; 2],
        tint: Rgba,
        color: bool,
        flags: u32,
    ) {
        let page = PAGE_SIZE as f32;
        let tint = if color || e.kind == PageKind::Color {
            [0.0, 0.0, 0.0, tint.a]
        } else {
            premul(tint)
        };
        let i = self.frame.glyphs.len() as u32;
        self.frame.glyphs.push(GlyphInstance {
            quad,
            uv: [
                e.x as f32 / page,
                e.y as f32 / page,
                (e.x + e.w) as f32 / page,
                (e.y + e.h) as f32 / page,
            ],
            color: tint,
            page: [
                e.page as u32,
                flags
                    | if e.kind == PageKind::Color {
                        GLYPH_COLOR
                    } else {
                        0
                    },
            ],
            anchor,
        });
        self.push_batch(Pipeline::Glyph, i);
    }

    /// A terminal grid: backgrounds, a solid block cursor, glyphs and sprites, then
    /// underline/strike and the other cursor shapes. Cell edges snap to device pixels, so
    /// backgrounds and sprites tile without seams at any zoom.
    fn cells(&mut self, g: &CellGrid) {
        if self.clipped_out() || g.cell.w <= 0.0 || g.cell.h <= 0.0 {
            return;
        }
        let s = self.s();
        let f: &dyn CellFrame = &*g.frame;
        let grid = Grid {
            ox: (g.origin.x * s).round(),
            oy: (g.origin.y * s).round(),
            cw: g.cell.w * s,
            ch: g.cell.h * s,
        };
        let font_px = g.font_size * s;
        let metrics = self.text.term_metrics();
        let raster_px = self.text.term_raster_px(font_px, g.raster == Raster::Exact);
        let hl = &g.highlight;
        let cursor = cursor_draw(g);
        let block = cursor.filter(|c| !c.hollow && c.shape == CursorShape::Block);

        // Backgrounds (the node frame already painted the default), one quad per run of a
        // colour; a wide char's spacer continues its run.
        for (r, row) in (0..f.row_count()).map(|r| (r, f.row(r))) {
            let (y0, y1) = (grid.y(r), grid.y(r + 1));
            let mut run: Option<(usize, Rgba)> = None;
            let mut last = None;
            for c in 0..=row.len() {
                let bg = match row.get(c) {
                    Some(cell) if cell.flags & flags::WIDE_SPACER != 0 => last,
                    Some(cell) => cell_colors(cell, f, hl).1,
                    None => None,
                };
                last = bg;
                if run.map(|(_, color)| color) != bg {
                    if let Some((start, color)) = run {
                        let x0 = grid.x(start);
                        self.push_cell([x0, y0, grid.x(c) - x0, y1 - y0], color);
                    }
                    run = bg.map(|color| (c, color));
                }
            }
        }
        if let Some(c) = block {
            self.push_cell(grid.rect(c.col, c.row, c.span), c.color);
        }

        // Glyphs from the row's cached shaping, then our sprites.
        let advance_px = metrics.advance * font_px;
        for (r, row) in (0..f.row_count()).map(|r| (r, f.row(r))) {
            let (y0, y1) = (grid.y(r), grid.y(r + 1));
            let layout = metrics.layout(font_px, y1 - y0);
            let baseline = y0 + layout.baseline;
            let shaped = self.text.shape_row(row);
            for gl in &shaped.glyphs {
                let col = gl.col as usize;
                let Some(cell) = row.get(col) else {
                    continue;
                };
                if cell.flags & flags::INVISIBLE != 0 {
                    continue;
                }
                let tint = glyph_color(cell, col, r, f, hl, block.as_ref());
                let pen = grid.ox
                    + col as f32 * grid.cw
                    + gl.span as f32 * (grid.cw - advance_px) * 0.5
                    + gl.x * font_px;
                self.term_glyph(
                    (gl.font, gl.glyph, gl.color),
                    pen,
                    baseline + gl.y * font_px,
                    font_px * gl.scale,
                    raster_px * gl.scale,
                    tint,
                );
            }
            for (c, cell) in row.iter().enumerate() {
                if cell.flags & (flags::INVISIBLE | flags::WIDE_SPACER) != 0 {
                    continue;
                }
                let Some(ch) = sprite::cell_sprite(&cell.text) else {
                    continue;
                };
                let span = if cell.flags & flags::WIDE != 0 { 2 } else { 1 };
                let tint = glyph_color(cell, c, r, f, hl, block.as_ref());
                self.sprite(ch, grid.rect(c, r, span), layout.line, tint);
            }
        }

        // Underline and strike, one quad per run of a colour. A blank cell keeps its
        // decoration: an underlined run of spaces (an input field) stays one line.
        for (r, row) in (0..f.row_count()).map(|r| (r, f.row(r))) {
            let (y0, y1) = (grid.y(r), grid.y(r + 1));
            let layout = metrics.layout(font_px, y1 - y0);
            let lines = [
                (
                    flags::UNDERLINE,
                    layout.underline_top,
                    layout.underline_thickness,
                ),
                (flags::STRIKE, layout.strike_top, layout.strike_thickness),
            ];
            for (flag, top, thickness) in lines {
                let mut run: Option<(usize, Rgba)> = None;
                let mut last = None;
                for c in 0..=row.len() {
                    let color = match row.get(c) {
                        Some(cell) if cell.flags & flags::WIDE_SPACER != 0 => last,
                        Some(cell)
                            if cell.flags & flag != 0 && cell.flags & flags::INVISIBLE == 0 =>
                        {
                            Some(glyph_color(cell, c, r, f, hl, None))
                        }
                        _ => None,
                    };
                    last = color;
                    if run.map(|(_, color)| color) != color {
                        if let Some((start, color)) = run {
                            let x0 = grid.x(start);
                            self.push_cell([x0, y0 + top, grid.x(c) - x0, thickness], color);
                        }
                        run = color.map(|color| (c, color));
                    }
                }
            }
        }

        // Bar, underline and hollow cursors draw over the text.
        if let Some(c) = cursor.filter(|c| c.hollow || c.shape != CursorShape::Block) {
            let [x, y, w, h] = grid.rect(c.col, c.row, c.span);
            let layout = metrics.layout(font_px, h);
            let t = layout.line.min(w).min(h);
            if c.hollow {
                for quad in [
                    [x, y, w, t],
                    [x, y + h - t, w, t],
                    [x, y, t, h],
                    [x + w - t, y, t, h],
                ] {
                    self.push_cell(quad, c.color);
                }
            } else if c.shape == CursorShape::Bar {
                self.push_cell([x, y, t, h], c.color);
            } else {
                let top = layout.underline_top.min(h - t);
                self.push_cell([x, y + top, w, t], c.color);
            }
        }
    }

    /// A code block: backgrounds, each row's glyphs from its cached shaping tinted by its
    /// colour spans, then carets. Cells snap to device pixels as a terminal grid's do, and
    /// glyphs are placed exactly as terminal glyphs are.
    fn code(&mut self, g: &CodeBlock) {
        if self.clipped_out() || g.cell.w <= 0.0 || g.cell.h <= 0.0 {
            return;
        }
        let s = self.s();
        let grid = Grid {
            ox: (g.origin.x * s).round(),
            oy: (g.origin.y * s).round(),
            cw: g.cell.w * s,
            ch: g.cell.h * s,
        };
        let font_px = g.font_size * s;
        let metrics = self.text.term_metrics();
        let raster_px = self.text.term_raster_px(font_px, true);
        let rows = &*g.rows;
        let span = |c: &canvas_draw::CellSpan| {
            let (r, x0) = (c.row as usize, grid.x(c.start as usize));
            let y0 = grid.y(r);
            [x0, y0, grid.x(c.end as usize) - x0, grid.y(r + 1) - y0]
        };
        for b in &rows.backgrounds {
            self.push_cell(span(b), b.color);
        }
        let advance_px = metrics.advance * font_px;
        for (r, row) in rows.rows.iter().enumerate() {
            let (y0, y1) = (grid.y(r), grid.y(r + 1));
            let baseline = y0 + metrics.layout(font_px, y1 - y0).baseline;
            let spans = rows.row_spans(row);
            let shaped = self
                .text
                .shape_code_row(rows.row_text(row), rows.row_cols(row), spans);
            let mut k = 0;
            for gl in &shaped.glyphs {
                let tint = span_color(spans, &mut k, gl.col, rows.fg);
                let pen = grid.ox
                    + gl.col as f32 * grid.cw
                    + gl.span as f32 * (grid.cw - advance_px) * 0.5
                    + gl.x * font_px;
                self.term_glyph(
                    (gl.font, gl.glyph, gl.color),
                    pen,
                    baseline + gl.y * font_px,
                    font_px * gl.scale,
                    raster_px * gl.scale,
                    tint,
                );
            }
        }
        let line = metrics.layout(font_px, grid.ch).line;
        for c in &rows.carets {
            let [x, y, _, h] = span(c);
            self.push_cell([x, y, line, h], c.color);
        }
    }

    /// One terminal glyph `(font, glyph, colour?)` with its pen at (`pen_x`, `baseline`) in
    /// device pixels, drawn at `px` from a raster made at `raster_px` (stretched while the
    /// zoom moves, pixel-exact once it settles).
    fn term_glyph(
        &mut self,
        (font, glyph, color): (u16, u32, bool),
        pen_x: f32,
        baseline: f32,
        px: f32,
        raster_px: f32,
        tint: Rgba,
    ) {
        let k = px / raster_px;
        let (x, subpixel) = if (k - 1.0).abs() < 1e-3 {
            quarter_pixel(pen_x)
        } else {
            (pen_x, 0)
        };
        let key = GlyphKey {
            font,
            glyph,
            size_q: GlyphKey::px_size(raster_px),
            subpixel,
        };
        let Some(e) = self.text.entry(key.into(), self.evict) else {
            return;
        };
        let y = baseline.round();
        let quad = [
            x + e.left as f32 * k,
            y - e.top as f32 * k,
            e.w as f32 * k,
            e.h as f32 * k,
        ];
        self.push_glyph(e, quad, tint, color);
    }

    /// One of our sprites filling `quad` (a whole-pixel cell rect).
    fn sprite(&mut self, ch: char, quad: [f32; 4], thickness: f32, tint: Rgba) {
        let [_, _, w, h] = quad;
        if w < 1.0 || h < 1.0 {
            return;
        }
        let key = SpriteKey {
            ch,
            w: w as u16,
            h: h as u16,
            thickness: thickness as u16,
        };
        if let Some(e) = self.text.entry(key.into(), self.evict) {
            self.push_glyph(e, quad, tint, false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use canvas_draw::Point;

    fn vp() -> Viewport {
        Viewport {
            width_px: 800,
            height_px: 600,
            scale: 2.0,
        }
    }

    #[test]
    fn painter_order_survives_batching() {
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.rect(RoundedRect::new(
            Rect::new(0.0, 0.0, 10.0, 10.0),
            2.0,
            Rgba::WHITE,
        ));
        dl.rect(RoundedRect::new(
            Rect::new(20.0, 0.0, 10.0, 10.0),
            2.0,
            Rgba::WHITE,
        ));
        dl.text(TextRun::new("hi", Point::new(0.0, 20.0), 13.0, Rgba::WHITE));
        dl.rect(RoundedRect::new(
            Rect::new(0.0, 40.0, 10.0, 10.0),
            2.0,
            Rgba::WHITE,
        ));
        dl.push_clip(Rect::new(0.0, 0.0, 5.0, 5.0));
        dl.rect(RoundedRect::new(
            Rect::new(0.0, 0.0, 10.0, 10.0),
            0.0,
            Rgba::WHITE,
        ));
        dl.pop_clip();
        let mut ts = TextSystem::new();
        let f = Frame::build(&dl, &mut ts, vp());
        let kinds: Vec<Pipeline> = f.batches.iter().map(|b| b.pipeline).collect();
        assert_eq!(kinds[0], Pipeline::Rect);
        assert_eq!(*kinds.last().unwrap(), Pipeline::Rect);
        assert_eq!(f.batches.last().unwrap().scissor, Some([0, 0, 10, 10]));
        assert_eq!(f.rects.len(), 4);
        // Text splits the rect batch only where it has ink: canvas-text's non-macOS
        // fallback shapes without ink (until parley, M8), so there the first three rects
        // are one batch and only the clip starts another.
        #[cfg(target_os = "macos")]
        {
            assert_eq!(f.batches[0].instances, 0..2, "adjacent rects share a batch");
            assert_eq!(
                kinds,
                vec![
                    Pipeline::Rect,
                    Pipeline::Glyph,
                    Pipeline::Rect,
                    Pipeline::Rect
                ]
            );
        }
        #[cfg(not(target_os = "macos"))]
        {
            assert!(f.glyphs.is_empty(), "the fallback text backend has no ink");
            assert_eq!(f.batches[0].instances, 0..3, "adjacent rects share a batch");
            assert_eq!(kinds, vec![Pipeline::Rect, Pipeline::Rect]);
        }
    }

    #[test]
    fn an_image_draws_from_the_colour_atlas_once_handed_over() {
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.image(canvas_draw::Image {
            rect: Rect::new(10.0, 10.0, 16.0, 8.0),
            radius: 3.0,
            image: canvas_draw::ImageId(7),
        });
        let mut ts = TextSystem::new();
        let f = Frame::build(&dl, &mut ts, vp());
        assert_eq!(
            (f.rects.len(), f.glyphs.len()),
            (1, 0),
            "a placeholder tile"
        );
        ts.set_image(7, 4, 2, vec![255; 4 * 2 * 4]);
        let f = Frame::build(&dl, &mut ts, vp());
        assert_eq!((f.rects.len(), f.glyphs.len()), (0, 1));
        let g = f.glyphs[0];
        assert_eq!(
            g.quad,
            [20.0, 20.0, 32.0, 16.0],
            "stretched over its rect at 2×"
        );
        assert_eq!(g.page[1], 1, "a colour page");
    }

    #[test]
    fn an_overflowing_glyph_set_never_draws_from_reused_atlas_slots() {
        // Glyphs this big take a page each: ten of them overflow the four alpha pages.
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.text(TextRun::new(
            "ABCDEFGHKM",
            Point::new(0.0, 0.0),
            480.0,
            Rgba::WHITE,
        ));
        let mut ts = TextSystem::new();
        let f = Frame::build(&dl, &mut ts, vp());
        #[cfg(target_os = "macos")]
        assert!(f.atlas_reset, "the glyph set must overflow the atlas");
        let overlap = |a: &GlyphInstance, b: &GlyphInstance| {
            a.page == b.page
                && a.uv[0] < b.uv[2]
                && b.uv[0] < a.uv[2]
                && a.uv[1] < b.uv[3]
                && b.uv[1] < a.uv[3]
        };
        for (i, a) in f.glyphs.iter().enumerate() {
            for b in &f.glyphs[i + 1..] {
                assert!(!overlap(a, b), "{a:?} and {b:?} share atlas texels");
            }
        }
    }

    #[test]
    fn blank_cells_keep_their_underline_and_strike() {
        use canvas_draw::cells::{Cell, Cursor, CursorShape, Rgb, Screen, flags};
        use canvas_draw::{CellGrid, Size};
        let cell = |text: &str, flags: u16| Cell {
            text: text.into(),
            fg: Rgb(200, 200, 200),
            bg: Rgb(0, 0, 0),
            flags,
        };
        let row = vec![
            cell("a", flags::UNDERLINE),
            cell(" ", flags::UNDERLINE),
            cell("", flags::UNDERLINE | flags::STRIKE),
            cell(" ", flags::UNDERLINE | flags::INVISIBLE),
            cell("", flags::UNDERLINE | flags::WIDE_SPACER),
        ];
        let frame = Screen {
            default_fg: Rgb(200, 200, 200),
            default_bg: Rgb(0, 0, 0),
            cursor: Cursor {
                col: 0,
                row: 0,
                shape: CursorShape::Block,
                visible: false,
                blinking: false,
            },
            cursor_color: None,
            rows: vec![row],
        };
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.cells(CellGrid::new(
            Point::new(0.0, 0.0),
            Size::new(8.0, 16.0),
            13.0,
            std::sync::Arc::new(frame),
        ));
        let f = Frame::build(&dl, &mut TextSystem::new(), vp());
        // One underline quad under cells 0–2 (a run of one colour) and the strike through
        // cell 2; nothing for the invisible cell or the wide spacer after it.
        assert_eq!(f.cells.len(), 2, "{:?}", f.cells);
        let (under, strike) = (f.cells[0].quad, f.cells[1].quad);
        assert_eq!((under[0], under[2]), (0.0, 48.0));
        assert_eq!((strike[0], strike[2]), (32.0, 16.0));
        assert!(strike[1] < under[1], "the strike sits above the underline");
    }

    fn grid(cells: Vec<canvas_draw::cells::Cell>, cursor: canvas_draw::cells::Cursor) -> CellGrid {
        use canvas_draw::cells::{Rgb, Screen};
        let frame = Screen {
            default_fg: Rgb(200, 200, 200),
            default_bg: Rgb(0, 0, 0),
            cursor,
            cursor_color: None,
            rows: vec![cells],
        };
        CellGrid::new(
            Point::new(0.0, 0.0),
            canvas_draw::Size::new(8.0, 16.0),
            13.0,
            std::sync::Arc::new(frame),
        )
    }

    fn cell(text: &str, fg: u8, bg: u8, flags: u16) -> canvas_draw::cells::Cell {
        canvas_draw::cells::Cell {
            text: text.into(),
            fg: canvas_draw::cells::Rgb(fg, fg, fg),
            bg: canvas_draw::cells::Rgb(bg, bg, bg),
            flags,
        }
    }

    fn hidden_cursor() -> canvas_draw::cells::Cursor {
        canvas_draw::cells::Cursor {
            col: 0,
            row: 0,
            shape: canvas_draw::cells::CursorShape::Block,
            visible: false,
            blinking: false,
        }
    }

    #[test]
    fn selection_swaps_colours_and_search_matches_stand_out() {
        use canvas_draw::cells::flags::{MATCH, MATCH_CURRENT, SELECTED};
        let g = grid(
            vec![
                cell("a", 200, 0, SELECTED),
                cell("b", 200, 0, MATCH),
                cell("c", 200, 0, MATCH_CURRENT | SELECTED),
                cell("d", 200, 0, 0),
            ],
            hidden_cursor(),
        );
        let hl = g.highlight;
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.cells(g);
        let f = Frame::build(&dl, &mut TextSystem::new(), vp());
        let bgs: Vec<([f32; 4], [f32; 2])> = f
            .cells
            .iter()
            .map(|c| (c.color, [c.quad[0], c.quad[2]]))
            .collect();
        let grey = Rgba::rgb8(200, 200, 200).premultiplied();
        assert_eq!(
            bgs,
            vec![
                (grey, [0.0, 16.0]),
                (hl.search.1.premultiplied(), [16.0, 16.0]),
                (hl.search_current.1.premultiplied(), [32.0, 16.0]),
            ],
            "the selection takes the text colour as its background; the current match wins"
        );
        #[cfg(target_os = "macos")]
        assert_eq!(
            f.glyphs[0].color,
            Rgba::BLACK.premultiplied(),
            "selected text takes the background colour"
        );
    }

    #[test]
    fn cursor_shapes_follow_focus() {
        use canvas_draw::CursorPaint;
        use canvas_draw::cells::{Cursor, CursorShape};
        let at = |shape| Cursor {
            col: 1,
            row: 0,
            shape,
            visible: true,
            blinking: true,
        };
        let draw = |shape, paint| {
            let mut g = grid(vec![cell("a", 200, 0, 0), cell("b", 200, 0, 0)], at(shape));
            g.cursor = paint;
            let mut dl = DisplayList::new(Rgba::BLACK);
            dl.cells(g);
            Frame::build(&dl, &mut TextSystem::new(), vp())
        };
        let block = draw(CursorShape::Block, CursorPaint::Focused);
        assert_eq!(block.cells.len(), 1);
        assert_eq!(
            block.cells[0].quad,
            [16.0, 0.0, 16.0, 32.0],
            "a solid block"
        );
        assert_eq!(
            block.batches[0].pipeline,
            Pipeline::Cell,
            "drawn under its glyph"
        );
        #[cfg(target_os = "macos")]
        assert_eq!(
            block.glyphs[1].color,
            Rgba::BLACK.premultiplied(),
            "the glyph under a block is in the background colour"
        );
        let bar = draw(CursorShape::Bar, CursorPaint::Focused);
        assert!(bar.cells[0].quad[2] < 4.0, "a thin bar: {:?}", bar.cells[0]);
        let hollow = draw(CursorShape::Bar, CursorPaint::Unfocused);
        assert_eq!(
            hollow.cells.len(),
            4,
            "unfocused: a hollow block, whatever the shape"
        );
        assert!(
            draw(CursorShape::Block, CursorPaint::Hidden)
                .cells
                .is_empty()
        );
    }

    #[test]
    fn cell_edges_snap_so_backgrounds_tile_at_any_zoom() {
        let mut g = grid(
            (0..7).map(|i| cell("", 200, 10 + i * 20, 0)).collect(),
            hidden_cursor(),
        );
        g.origin = Point::new(3.3, 1.7);
        g.cell = canvas_draw::Size::new(5.37, 11.1);
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.cells(g);
        let f = Frame::build(&dl, &mut TextSystem::new(), vp());
        assert_eq!(f.cells.len(), 7);
        for pair in f.cells.windows(2) {
            let (a, b) = (pair[0].quad, pair[1].quad);
            assert_eq!(
                a[0] + a[2],
                b[0],
                "no gap or overlap between {a:?} and {b:?}"
            );
            assert!(a.iter().all(|v| v.fract() == 0.0), "whole pixels: {a:?}");
        }
    }

    #[test]
    fn shadows_precede_their_shape_and_empty_clips_draw_nothing() {
        let mut dl = DisplayList::new(Rgba::TRANSPARENT);
        dl.rect(
            RoundedRect::new(Rect::new(10.0, 10.0, 40.0, 20.0), 6.0, Rgba::WHITE).shadow(
                Rgba::BLACK.with_alpha(0.5),
                8.0,
                Point::new(0.0, 2.0),
            ),
        );
        dl.push_clip(Rect::new(100.0, 100.0, 0.0, 0.0));
        dl.rect(RoundedRect::new(
            Rect::new(100.0, 100.0, 5.0, 5.0),
            0.0,
            Rgba::WHITE,
        ));
        dl.pop_clip();
        let mut ts = TextSystem::new();
        let f = Frame::build(&dl, &mut ts, vp());
        assert_eq!(f.rects.len(), 2);
        assert_eq!(f.rects[0].params[2], 16.0, "shadow softness in pixels");
        assert_eq!(f.rects[1].params[2], 0.0);
        assert_eq!(f.rects[1].shape, [20.0, 20.0, 80.0, 40.0]);
    }

    #[test]
    fn code_glyphs_sit_on_their_columns_in_their_span_colours() {
        use canvas_draw::{CellSpan, CodeBlock, CodeRows, Size};
        let red = Rgba::hex(0xff0000);
        let mut rows = CodeRows {
            fg: Rgba::WHITE,
            ..CodeRows::default()
        };
        // "a", a tab to column 4, "b" in red; then an empty row with the caret.
        rows.push_row("a\tb", &[0, 1, 4, 5]);
        rows.push_span(4, 5, red);
        rows.push_row("", &[0]);
        let shade = Rgba::BLACK.with_alpha(0.5);
        rows.backgrounds.push(CellSpan {
            row: 0,
            start: 0,
            end: 6,
            color: shade,
        });
        rows.carets.push(CellSpan {
            row: 1,
            start: 2,
            end: 2,
            color: Rgba::WHITE,
        });
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.code(CodeBlock {
            origin: Point::new(0.0, 0.0),
            cell: Size::new(8.0, 16.0),
            font_size: 13.0,
            rows: std::sync::Arc::new(rows),
        });
        let f = Frame::build(&dl, &mut TextSystem::new(), vp());
        assert_eq!(f.cells.len(), 2, "{:?}", f.cells);
        assert_eq!(
            f.cells[0].quad,
            [0.0, 0.0, 96.0, 32.0],
            "six cells of row 0"
        );
        assert_eq!(
            (f.cells[1].quad[0], f.cells[1].quad[1]),
            (32.0, 32.0),
            "a bar at row 1, column 2"
        );
        // The fallback shaper of non-macOS builds has no ink.
        #[cfg(target_os = "macos")]
        {
            assert_eq!(f.glyphs.len(), 2, "the tab has no glyph");
            assert_eq!(f.glyphs[0].color, premul(Rgba::WHITE));
            assert_eq!(f.glyphs[1].color, premul(red));
            let x = f.glyphs[1].quad[0];
            assert!((64.0..80.0).contains(&x), "b in column 4: {x}");
            let kinds: Vec<Pipeline> = f.batches.iter().map(|b| b.pipeline).collect();
            assert_eq!(kinds, vec![Pipeline::Cell, Pipeline::Glyph, Pipeline::Cell]);
        }
    }
}
