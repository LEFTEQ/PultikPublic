//! Display-list primitives shared by the scene (producer) and the GPU renderer (consumer).
//!
//! Everything is in **view points** with the origin at the top-left of the surface, the space a
//! host hands its pointer events in. The renderer multiplies by the backing scale. Colours
//! are straight (non-premultiplied) sRGB in `0.0..=1.0`; the renderer premultiplies.
//!
//! A [`DisplayList`] is immutable once built and draws in order (painter's algorithm);
//! [`Op::PushClip`]/[`Op::PopClip`] nest axis-aligned clips. Ops between [`Op::PushCamera`]
//! and [`Op::PopCamera`] are in world points, placed by the target's [`Camera`]: a pan or a
//! zoom moves them on the GPU without a new list.

pub mod cells;
pub mod path;

use cells::CellFrame;
pub use path::{Camera, Dash, Follow, LineCap, LineJoin, Path, PathOp, Stroke, Verb};
use std::sync::Arc;

/// A straight-alpha sRGB colour.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    pub const TRANSPARENT: Rgba = Rgba::new(0.0, 0.0, 0.0, 0.0);
    pub const BLACK: Rgba = Rgba::new(0.0, 0.0, 0.0, 1.0);
    pub const WHITE: Rgba = Rgba::new(1.0, 1.0, 1.0, 1.0);

    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    /// An opaque colour from 8-bit channels.
    pub const fn rgb8(r: u8, g: u8, b: u8) -> Self {
        Self::new(r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0, 1.0)
    }

    /// An opaque colour from `0xRRGGBB`.
    pub const fn hex(rgb: u32) -> Self {
        Self::rgb8((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
    }

    /// The same colour with alpha replaced.
    pub const fn with_alpha(self, a: f32) -> Self {
        Self::new(self.r, self.g, self.b, a)
    }

    /// Premultiplied `[r, g, b, a]`, what the GPU blends.
    pub fn premultiplied(self) -> [f32; 4] {
        [self.r * self.a, self.g * self.a, self.b * self.a, self.a]
    }

    /// Linear interpolation, `t` clamped to `0..=1`.
    pub fn lerp(self, other: Rgba, t: f32) -> Rgba {
        let t = t.clamp(0.0, 1.0);
        Rgba::new(
            self.r + (other.r - self.r) * t,
            self.g + (other.g - self.g) * t,
            self.b + (other.b - self.b) * t,
            self.a + (other.a - self.a) * t,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    pub const ZERO: Point = Point::new(0.0, 0.0);

    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }
}

impl std::ops::Add for Point {
    type Output = Point;
    fn add(self, o: Point) -> Point {
        Point::new(self.x + o.x, self.y + o.y)
    }
}

impl std::ops::Sub for Point {
    type Output = Point;
    fn sub(self, o: Point) -> Point {
        Point::new(self.x - o.x, self.y - o.y)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Size {
    pub w: f32,
    pub h: f32,
}

impl Size {
    pub const fn new(w: f32, h: f32) -> Self {
        Self { w, h }
    }
}

/// An axis-aligned rectangle; `w`/`h` are never negative for rects this crate builds.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub const ZERO: Rect = Rect::new(0.0, 0.0, 0.0, 0.0);

    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }

    pub fn from_origin_size(origin: Point, size: Size) -> Self {
        Self::new(origin.x, origin.y, size.w, size.h)
    }

    /// The rect spanning two corners in any order.
    pub fn from_corners(a: Point, b: Point) -> Self {
        Self::new(
            a.x.min(b.x),
            a.y.min(b.y),
            (a.x - b.x).abs(),
            (a.y - b.y).abs(),
        )
    }

    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }
    pub fn size(&self) -> Size {
        Size::new(self.w, self.h)
    }
    pub fn max_x(&self) -> f32 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f32 {
        self.y + self.h
    }
    pub fn center(&self) -> Point {
        Point::new(self.x + self.w * 0.5, self.y + self.h * 0.5)
    }
    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }

    /// Half-open containment: the left/top edges are inside, the right/bottom are not.
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.y >= self.y && p.x < self.max_x() && p.y < self.max_y()
    }

    pub fn intersects(&self, o: &Rect) -> bool {
        self.x < o.max_x() && o.x < self.max_x() && self.y < o.max_y() && o.y < self.max_y()
    }

    /// The overlap, or an empty rect at the nearest corner when they do not overlap.
    pub fn intersect(&self, o: &Rect) -> Rect {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let mx = self.max_x().min(o.max_x());
        let my = self.max_y().min(o.max_y());
        Rect::new(x, y, (mx - x).max(0.0), (my - y).max(0.0))
    }

    pub fn union(&self, o: &Rect) -> Rect {
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        Rect::new(
            x,
            y,
            self.max_x().max(o.max_x()) - x,
            self.max_y().max(o.max_y()) - y,
        )
    }

    /// Shrink by `d` on every side (negative grows); never below zero size.
    pub fn inset(&self, d: f32) -> Rect {
        self.inset_xy(d, d)
    }

    pub fn inset_xy(&self, dx: f32, dy: f32) -> Rect {
        Rect::new(
            self.x + dx,
            self.y + dy,
            (self.w - 2.0 * dx).max(0.0),
            (self.h - 2.0 * dy).max(0.0),
        )
    }

    pub fn translate(&self, d: Point) -> Rect {
        Rect::new(self.x + d.x, self.y + d.y, self.w, self.h)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Border {
    pub width: f32,
    pub color: Rgba,
}

/// A soft drop shadow (or glow, with a zero offset) behind a rounded rect.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Shadow {
    pub color: Rgba,
    /// Blur radius in points.
    pub blur: f32,
    pub offset: Point,
}

/// A rounded rectangle drawn by the SDF pipeline: fill, optional inner border, optional
/// shadow. `radius` is clamped to half the shorter side by the renderer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RoundedRect {
    pub rect: Rect,
    pub radius: f32,
    pub fill: Rgba,
    pub border: Option<Border>,
    pub shadow: Option<Shadow>,
    /// In a camera layer, the camera moves its centre and keeps its size (a point mark among
    /// stretching bars stays round). No effect outside one.
    pub pinned: bool,
}

impl RoundedRect {
    pub fn new(rect: Rect, radius: f32, fill: Rgba) -> Self {
        Self {
            rect,
            radius,
            fill,
            border: None,
            shadow: None,
            pinned: false,
        }
    }
    pub fn pinned(mut self) -> Self {
        self.pinned = true;
        self
    }
    pub fn border(mut self, width: f32, color: Rgba) -> Self {
        self.border = Some(Border { width, color });
        self
    }
    pub fn shadow(mut self, color: Rgba, blur: f32, offset: Point) -> Self {
        self.shadow = Some(Shadow {
            color,
            blur,
            offset,
        });
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Weight {
    #[default]
    Regular,
    Medium,
    Semibold,
    Bold,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Align {
    #[default]
    Start,
    Center,
    End,
}

/// One line of single-style text. `origin` is the TOP-LEFT of the line box (the renderer
/// adds the font's ascent to find the baseline). With `max_width`, text is aligned inside
/// that box and truncated with an ellipsis when it does not fit.
#[derive(Debug, Clone, PartialEq)]
pub struct TextRun {
    pub text: String,
    pub origin: Point,
    /// Point size.
    pub size: f32,
    pub weight: Weight,
    /// The system monospaced (terminal) font instead of the UI font.
    pub mono: bool,
    /// The italic face (slanted when the family has none).
    pub italic: bool,
    pub color: Rgba,
    pub max_width: Option<f32>,
    pub align: Align,
}

impl TextRun {
    pub fn new(text: impl Into<String>, origin: Point, size: f32, color: Rgba) -> Self {
        Self {
            text: text.into(),
            origin,
            size,
            weight: Weight::Regular,
            mono: false,
            italic: false,
            color,
            max_width: None,
            align: Align::Start,
        }
    }
    pub fn italic(mut self) -> Self {
        self.italic = true;
        self
    }
    pub fn weight(mut self, weight: Weight) -> Self {
        self.weight = weight;
        self
    }
    pub fn mono(mut self) -> Self {
        self.mono = true;
        self
    }
    pub fn max_width(mut self, w: f32) -> Self {
        self.max_width = Some(w);
        self
    }
    pub fn align(mut self, align: Align) -> Self {
        self.align = align;
        self
    }
}

/// A screen drawn cell by cell from a shared [`CellFrame`] (a terminal mirror's, never
/// copied per frame). Cell backgrounds go through the cell pipeline; glyphs (the terminal
/// font at `font_size`, shaped per row) and our box/block/powerline sprites through the
/// glyph pipeline. Cell edges snap to device pixels, so sprites and backgrounds tile.
/// Two grids are equal when they draw the same shared frame the same way.
#[derive(Debug, Clone)]
pub struct CellGrid {
    /// Top-left of cell (0, 0).
    pub origin: Point,
    /// One cell: the terminal font's cell at this grid's zoom.
    pub cell: Size,
    /// The terminal font's point size at this grid's zoom.
    pub font_size: f32,
    pub frame: Arc<dyn CellFrame>,
    pub cursor: CursorPaint,
    /// The cursor colour when the program set none (OSC 12); `None` is the foreground.
    pub cursor_color: Option<Rgba>,
    pub raster: Raster,
    pub highlight: Highlight,
}

impl CellGrid {
    /// A grid with no cursor, exact rasters and the default highlight colours.
    pub fn new(origin: Point, cell: Size, font_size: f32, frame: Arc<dyn CellFrame>) -> Self {
        Self {
            origin,
            cell,
            font_size,
            frame,
            cursor: CursorPaint::Hidden,
            cursor_color: None,
            raster: Raster::Exact,
            highlight: Highlight::default(),
        }
    }
}

impl PartialEq for CellGrid {
    fn eq(&self, o: &Self) -> bool {
        self.origin == o.origin
            && self.cell == o.cell
            && self.font_size == o.font_size
            && std::ptr::addr_eq(Arc::as_ptr(&self.frame), Arc::as_ptr(&o.frame))
            && self.cursor == o.cursor
            && self.cursor_color == o.cursor_color
            && self.raster == o.raster
            && self.highlight == o.highlight
    }
}

/// How a grid's cursor is drawn this frame (the frame's own `cursor.visible` still applies).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CursorPaint {
    /// Not drawn: the blink's off phase, or a grid that shows no cursor.
    #[default]
    Hidden,
    /// The focused terminal: the program's shape, solid; the glyph under a block is drawn
    /// in the background colour.
    Focused,
    /// Not focused: a hollow block whatever the shape.
    Unfocused,
}

/// Which raster size a grid's glyphs come from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Raster {
    /// Rasterized at exactly the drawn size (the zoom is settled).
    #[default]
    Exact,
    /// The nearest size already cached, stretched (the zoom is moving).
    Nearest,
}

/// Selection and search highlight colours as `(foreground, background)`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Highlight {
    /// Selected cells; `None` swaps each cell's own colours.
    pub selection: Option<(Rgba, Rgba)>,
    /// Search matches.
    pub search: (Rgba, Rgba),
    /// The current search match (wins over the selection and other matches).
    pub search_current: (Rgba, Rgba),
}

impl Default for Highlight {
    fn default() -> Self {
        Self {
            selection: None,
            search: (Rgba::hex(0x1d2022), Rgba::hex(0xf2d06b)),
            search_current: (Rgba::hex(0x1d2022), Rgba::hex(0xff9632)),
        }
    }
}

/// A code view's visible rows on a monospaced grid in the terminal font: each row's text is
/// shaped from its chars and their columns (code-core's layout) and its spans' faces, cached
/// by content, so a steady view reshapes nothing; colours tint glyphs by column and never
/// split shaping, only a bold or italic span does.
/// Backgrounds draw under the text, carets over it; all are in grid cells. Cell edges snap
/// to device pixels as a [`CellGrid`]'s do.
#[derive(Debug, Clone, PartialEq)]
pub struct CodeBlock {
    /// Top-left of the first row's first cell (a partly scrolled-out row starts above the
    /// view: clip around the block).
    pub origin: Point,
    /// One cell: the terminal font's cell at this block's zoom.
    pub cell: Size,
    /// The terminal font's point size at this block's zoom.
    pub font_size: f32,
    /// Shared with the producer, which refills it in place once the renderer let go.
    pub rows: Arc<CodeRows>,
}

/// What a [`CodeBlock`] draws: rows of text with every char's column, the colour spans over
/// them, and cell rects. One flat buffer per kind, so refilling it allocates nothing.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CodeRows {
    /// Text outside every colour span.
    pub fg: Rgba,
    pub text: String,
    pub cols: Vec<u16>,
    pub rows: Vec<CodeRow>,
    /// Each row's spans, by column, ascending and not overlapping.
    pub spans: Vec<ColorSpan>,
    /// Drawn under the text: the current line, selections, search matches.
    pub backgrounds: Vec<CellSpan>,
    /// Drawn over the text as bars at `start`'s left edge, one line thick (`end` unused).
    pub carets: Vec<CellSpan>,
}

/// One row: ranges into [`CodeRows`]' buffers.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CodeRow {
    /// Its chars in `text`.
    pub text: std::ops::Range<u32>,
    /// Each char's column, then the row's end column, in `cols`: one more than its chars.
    pub cols: std::ops::Range<u32>,
    /// Its colour spans in `spans`.
    pub spans: std::ops::Range<u32>,
}

/// Columns `start..end` of a row drawn in `color`, in face `style`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ColorSpan {
    pub start: u16,
    pub end: u16,
    pub color: Rgba,
    /// The face, a terminal cell's font slot: 0 regular, 1 bold, 2 italic, 3 bold italic.
    pub style: u8,
}

/// Columns `start..end` of row `row` (an index into [`CodeRows::rows`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellSpan {
    pub row: u32,
    pub start: u16,
    pub end: u16,
    pub color: Rgba,
}

impl CodeRows {
    /// Empty every buffer, keeping its capacity.
    pub fn clear(&mut self) {
        self.text.clear();
        self.cols.clear();
        self.rows.clear();
        self.spans.clear();
        self.backgrounds.clear();
        self.carets.clear();
    }

    /// Append a row of `text` with its `cols` (one more entry than `text` has chars); its
    /// colour spans are the ones pushed until the next row.
    pub fn push_row(&mut self, text: &str, cols: &[u16]) {
        let (t, c, s) = (self.text.len(), self.cols.len(), self.spans.len());
        self.text.push_str(text);
        self.cols.extend_from_slice(cols);
        self.rows.push(CodeRow {
            text: t as u32..self.text.len() as u32,
            cols: c as u32..self.cols.len() as u32,
            spans: s as u32..s as u32,
        });
    }

    /// Colour columns `start..end` of the last row.
    pub fn push_span(&mut self, start: u16, end: u16, color: Rgba) {
        self.push_styled_span(start, end, color, 0);
    }

    /// Colour columns `start..end` of the last row and draw them in face `style`
    /// ([`ColorSpan::style`]).
    pub fn push_styled_span(&mut self, start: u16, end: u16, color: Rgba, style: u8) {
        self.spans.push(ColorSpan {
            start,
            end,
            color,
            style,
        });
        if let Some(row) = self.rows.last_mut() {
            row.spans.end = self.spans.len() as u32;
        }
    }

    pub fn row_text(&self, row: &CodeRow) -> &str {
        &self.text[row.text.start as usize..row.text.end as usize]
    }

    pub fn row_cols(&self, row: &CodeRow) -> &[u16] {
        &self.cols[row.cols.start as usize..row.cols.end as usize]
    }

    pub fn row_spans(&self, row: &CodeRow) -> &[ColorSpan] {
        &self.spans[row.spans.start as usize..row.spans.end as usize]
    }
}

/// Identifies an image the renderer was handed out of band (chip thumbnails).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ImageId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Image {
    pub rect: Rect,
    pub radius: f32,
    pub image: ImageId,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    Rect(RoundedRect),
    Text(TextRun),
    Cells(CellGrid),
    Code(CodeBlock),
    Image(Image),
    Path(PathOp),
    /// Intersect the current clip with this rect until the matching [`Op::PopClip`]. Clips
    /// are always in view points, inside a camera layer too.
    PushClip(Rect),
    PopClip,
    /// Until the matching [`Op::PopCamera`], ops are in world points placed by the target's
    /// camera along the axes [`Follow`] names. Layers do not nest.
    PushCamera(Follow),
    PopCamera,
}

impl Op {
    /// This op drawn `k` times its size with its origin at `at`: what a producer laid out
    /// in its own coordinates at scale 1 (a conversation thread) becomes on a zoomed node.
    pub fn placed(&self, at: Point, k: f32) -> Op {
        let point = |p: Point| Point::new(at.x + p.x * k, at.y + p.y * k);
        let rect = |r: Rect| Rect::new(at.x + r.x * k, at.y + r.y * k, r.w * k, r.h * k);
        let size = |s: Size| Size::new(s.w * k, s.h * k);
        match self {
            Op::Rect(r) => Op::Rect(RoundedRect {
                rect: rect(r.rect),
                radius: r.radius * k,
                fill: r.fill,
                border: r.border.map(|b| Border {
                    width: b.width * k,
                    color: b.color,
                }),
                shadow: r.shadow.map(|s| Shadow {
                    color: s.color,
                    blur: s.blur * k,
                    offset: Point::new(s.offset.x * k, s.offset.y * k),
                }),
                pinned: r.pinned,
            }),
            Op::Text(t) => Op::Text(TextRun {
                origin: point(t.origin),
                size: t.size * k,
                max_width: t.max_width.map(|w| w * k),
                ..t.clone()
            }),
            Op::Cells(c) => Op::Cells(CellGrid {
                origin: point(c.origin),
                cell: size(c.cell),
                font_size: c.font_size * k,
                ..c.clone()
            }),
            Op::Code(c) => Op::Code(CodeBlock {
                origin: point(c.origin),
                cell: size(c.cell),
                font_size: c.font_size * k,
                rows: c.rows.clone(),
            }),
            Op::Image(i) => Op::Image(Image {
                rect: rect(i.rect),
                radius: i.radius * k,
                image: i.image,
            }),
            Op::Path(p) => Op::Path(PathOp {
                path: std::sync::Arc::new(p.path.map(point)),
                fill: p.fill,
                stroke: p.stroke.map(|s| Stroke {
                    width: s.width * k,
                    dash: s.dash.map(|d| Dash {
                        on: d.on * k,
                        off: d.off * k,
                        phase: d.phase * k,
                        speed: d.speed * k,
                    }),
                    ..s
                }),
            }),
            Op::PushClip(r) => Op::PushClip(rect(*r)),
            Op::PopClip => Op::PopClip,
            Op::PushCamera(f) => Op::PushCamera(*f),
            Op::PopCamera => Op::PopCamera,
        }
    }
}

/// An immutable, ordered list of draw operations for one surface.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DisplayList {
    /// The colour the surface is cleared to (transparent for the bar).
    pub clear: Rgba,
    pub ops: Vec<Op>,
}

impl DisplayList {
    pub fn new(clear: Rgba) -> Self {
        Self {
            clear,
            ops: Vec::new(),
        }
    }
    pub fn rect(&mut self, r: RoundedRect) {
        self.ops.push(Op::Rect(r));
    }
    pub fn text(&mut self, t: TextRun) {
        if !t.text.is_empty() {
            self.ops.push(Op::Text(t));
        }
    }
    pub fn cells(&mut self, c: CellGrid) {
        self.ops.push(Op::Cells(c));
    }
    pub fn code(&mut self, c: CodeBlock) {
        self.ops.push(Op::Code(c));
    }
    pub fn image(&mut self, i: Image) {
        self.ops.push(Op::Image(i));
    }
    pub fn push_clip(&mut self, r: Rect) {
        self.ops.push(Op::PushClip(r));
    }
    pub fn pop_clip(&mut self) {
        self.ops.push(Op::PopClip);
    }
    pub fn path(&mut self, p: PathOp) {
        if !p.path.is_empty() {
            self.ops.push(Op::Path(p));
        }
    }
    pub fn push_camera(&mut self, follow: Follow) {
        self.ops.push(Op::PushCamera(follow));
    }
    pub fn pop_camera(&mut self) {
        self.ops.push(Op::PopCamera);
    }
    pub fn len(&self) -> usize {
        self.ops.len()
    }
    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }
    /// Append every op of `other` (its clear colour is ignored).
    pub fn extend(&mut self, other: DisplayList) {
        self.ops.extend(other.ops);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_and_premultiply() {
        let c = Rgba::hex(0xff3b57).with_alpha(0.5);
        assert_eq!(c.r, 1.0);
        assert!((c.g - 59.0 / 255.0).abs() < 1e-6);
        assert_eq!(c.premultiplied()[0], 0.5);
    }

    #[test]
    fn rect_geometry() {
        let a = Rect::new(0.0, 0.0, 10.0, 10.0);
        let b = Rect::new(5.0, 5.0, 10.0, 10.0);
        assert!(a.intersects(&b));
        assert_eq!(a.intersect(&b), Rect::new(5.0, 5.0, 5.0, 5.0));
        assert_eq!(a.union(&b), Rect::new(0.0, 0.0, 15.0, 15.0));
        assert!(a.contains(Point::new(0.0, 0.0)));
        assert!(!a.contains(Point::new(10.0, 5.0)));
        assert!(!a.intersects(&Rect::new(10.0, 0.0, 5.0, 5.0)));
    }
}
