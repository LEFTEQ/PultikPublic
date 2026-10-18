//! Text shaping and glyph rasterization (Core Text on macOS) into an atlas.
//!
//! - [`TextSystem`]: fonts, shaping with a cache, glyph rasterization into the [`Atlas`].
//!   On macOS shaping is Core Text `CTLine` (bidi, fallback fonts, caret offsets from the
//!   system); elsewhere a fixed-advance fallback keeps the crate building and testable.
//!   [`ShapedLine`]'s carets and [`nearest`] are what an editor's line layout builds its
//!   caret, hit-test and range geometry from.
//! - Cell text ([`term`]): the monospaced font, its [`TermMetrics`], and
//!   [`TextSystem::shape_row`], run shaping of a [`canvas_draw::cells`] row cached per row
//!   content.
//! - Code text (`code.rs`): [`TextSystem::shape_code_row`], a code row from its text,
//!   columns and spans' faces through the same run shaping, cached per row content.
//! - Code views ([`code_view`]): an editor viewport's rows coloured by code-core's syntax
//!   spans and a `crates/theme` theme, and a diff inline or side by side, as the code op's
//!   rows.
//! - [`sprite`]: our own box-drawing, block and powerline glyphs, rasterized at the exact
//!   cell size into the same atlas.
//!
//! Sizes are in points; the renderer multiplies by the backing scale.

pub mod atlas;
mod code;
pub mod code_view;
pub mod diff_view;
pub mod editor_view;
pub mod sprite;
pub mod term;

#[cfg(target_os = "macos")]
#[path = "coretext.rs"]
mod platform;
#[cfg(not(target_os = "macos"))]
#[path = "fallback.rs"]
mod platform;

pub use atlas::{
    Atlas, AtlasEntry, AtlasKey, Dirty, GlyphKey, MAX_ALPHA_PAGES, MAX_COLOR_PAGES, PAGE_SIZE,
    PageKind, RasterGlyph, Upload,
};
pub use canvas_draw::Weight;
pub use sprite::SpriteKey;
pub use term::{CellGlyph, CellLayout, ShapedRow, TermMetrics};

use canvas_draw::cells::Cell;
use std::collections::HashMap;
use std::sync::Arc;

/// The terminal font size when `[terminal] font_size` is not set (points at zoom 1).
pub const DEFAULT_TERM_SIZE: f32 = 13.0;

/// Which font, at what weight and point size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FontSpec {
    /// The terminal font (system monospaced / the user's fixed-pitch font) instead of the
    /// system UI font.
    pub mono: bool,
    pub weight: Weight,
    pub size: f32,
    /// The family's italic face (synthesized by slanting when it has none).
    pub italic: bool,
}

impl FontSpec {
    pub fn ui(size: f32) -> Self {
        Self {
            mono: false,
            weight: Weight::Regular,
            size,
            italic: false,
        }
    }
    pub fn mono(size: f32) -> Self {
        Self {
            mono: true,
            weight: Weight::Regular,
            size,
            italic: false,
        }
    }
    pub fn weight(mut self, weight: Weight) -> Self {
        self.weight = weight;
        self
    }
    pub fn italic(mut self, italic: bool) -> Self {
        self.italic = italic;
        self
    }
    /// Hashable identity: size quantized to 1/64 pt.
    fn key(&self) -> FontKey {
        (
            self.mono,
            self.weight,
            (self.size * 64.0).round() as u32,
            self.italic,
        )
    }
}

/// Vertical metrics of a font at a size, in points.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Metrics {
    pub ascent: f32,
    pub descent: f32,
    pub leading: f32,
    /// Advance of `0`: the cell width of a monospaced font.
    pub advance: f32,
}

impl Metrics {
    pub fn line_height(&self) -> f32 {
        self.ascent + self.descent + self.leading
    }
}

/// One positioned glyph of a shaped line, relative to the line's pen origin on the baseline
/// (x right, y down).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShapedGlyph {
    /// Face index (fallback fonts get their own).
    pub font: u16,
    pub glyph: u32,
    pub x: f32,
    pub y: f32,
    /// From a colour font (emoji): rasterized into an RGBA page and not tinted.
    pub color: bool,
}

/// A shaped single line of single-style text.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ShapedLine {
    pub glyphs: Vec<ShapedGlyph>,
    pub width: f32,
    pub ascent: f32,
    pub descent: f32,
    /// Primary caret x for every char boundary `0..=chars` (from `CTLine` on macOS, so
    /// right-to-left runs place carets correctly).
    pub carets: Vec<f32>,
}

impl ShapedLine {
    /// The char boundary nearest to `x`.
    pub fn index_at(&self, x: f32) -> usize {
        nearest(&self.carets, x)
    }
}

/// The index of the caret in `carets` nearest to `x` (0 when there is none).
pub fn nearest(carets: &[f32], x: f32) -> usize {
    carets
        .iter()
        .enumerate()
        .min_by(|a, b| (a.1 - x).abs().total_cmp(&(b.1 - x).abs()))
        .map_or(0, |(i, _)| i)
}

/// Hashable font identity: (mono, weight, size in 1/64 pt, italic).
type FontKey = (bool, Weight, u32, bool);

const SHAPE_CACHE_MAX: usize = 8192;
/// Images kept for the atlas (chip thumbnails, at most 256 KiB each).
const IMAGES_MAX: usize = 64;
/// Shaped terminal rows kept (a few hundred screens' worth).
const ROW_CACHE_MAX: usize = 8192;
/// Terminal raster sizes remembered for drawing while the zoom moves.
const RASTER_SIZES_MAX: usize = 6;
/// While zooming, a cached raster is stretched at most this much before a new one is made.
const MAX_STRETCH: f32 = 1.5;
const ELLIPSIS: &str = "…";

/// The terminal font in use.
#[derive(Debug, Clone, PartialEq)]
struct TermFont {
    family: Option<String>,
    size: f32,
    metrics: TermMetrics,
}

/// Fonts, shaping and the glyph atlas. Main-thread only (Core Text fonts are not `Send`).
pub struct TextSystem {
    platform: platform::Platform,
    atlas: Atlas,
    /// Shaped lines by font, then text: a hit borrows the text, so redrawing the same
    /// labels allocates nothing.
    shapes: HashMap<FontKey, HashMap<String, Arc<ShapedLine>>>,
    term: Option<TermFont>,
    /// Shaped terminal rows by [`term::row_key`].
    rows: HashMap<(u64, u32), Arc<ShapedRow>>,
    row_scratch: term::Scratch,
    /// Shaped code rows by [`code::row_key`].
    code_rows: HashMap<(u64, u32), Arc<ShapedRow>>,
    code_scratch: code::Scratch,
    /// Terminal raster sizes (glyph-key sizes) recently drawn, most recent first, and the
    /// atlas generation they were rasterized in.
    raster_sizes: Vec<u32>,
    raster_generation: u64,
    /// Images handed over by [`TextSystem::set_image`], by id.
    images: HashMap<u64, Arc<RasterGlyph>>,
}

impl Default for TextSystem {
    fn default() -> Self {
        Self::new()
    }
}

impl TextSystem {
    pub fn new() -> Self {
        Self {
            platform: platform::Platform::new(),
            atlas: Atlas::new(),
            shapes: HashMap::new(),
            term: None,
            rows: HashMap::new(),
            row_scratch: term::Scratch::default(),
            code_rows: HashMap::new(),
            code_scratch: code::Scratch::default(),
            raster_sizes: Vec::new(),
            raster_generation: 0,
            images: HashMap::new(),
        }
    }

    /// Use `family` (`None` = the system monospaced font, SF Mono) at `size` points (zoom 1)
    /// for terminals and monospaced text. A no-op when nothing changed; otherwise cached
    /// shapes are dropped.
    pub fn set_term_font(&mut self, family: Option<&str>, size: f32) {
        let size = if size.is_finite() && size > 0.0 {
            size
        } else {
            DEFAULT_TERM_SIZE
        };
        if let Some(t) = &self.term
            && t.family.as_deref() == family
            && t.size == size
        {
            return;
        }
        let metrics = self.platform.set_term_font(family, size);
        self.term = Some(TermFont {
            family: family.map(str::to_owned),
            size,
            metrics,
        });
        self.rows.clear();
        self.code_rows.clear();
        self.shapes.clear();
    }

    fn term_font(&mut self) -> &TermFont {
        if self.term.is_none() {
            self.set_term_font(None, DEFAULT_TERM_SIZE);
        }
        match &self.term {
            Some(t) => t,
            None => unreachable!("set_term_font always sets a font"),
        }
    }

    /// The terminal font's point size at zoom 1.
    pub fn term_font_size(&mut self) -> f32 {
        self.term_font().size
    }

    /// The terminal font's metrics in ems.
    pub fn term_metrics(&mut self) -> TermMetrics {
        self.term_font().metrics
    }

    /// The glyphs of one terminal row, shaped in runs and pinned to cells. Cached by the
    /// row's text and styles: an unchanged row costs one hash and no allocation.
    pub fn shape_row(&mut self, cells: &[Cell]) -> Arc<ShapedRow> {
        let advance = self.term_metrics().advance;
        let key = term::row_key(cells);
        if let Some(hit) = self.rows.get(&key) {
            return hit.clone();
        }
        if self.rows.len() >= ROW_CACHE_MAX {
            self.rows.clear();
        }
        let platform = &mut self.platform;
        let shaped = Arc::new(term::shape_row(
            cells,
            advance,
            &mut self.row_scratch,
            |text, style, out| platform.shape_term_run(text, style, out),
        ));
        self.rows.insert(key, shaped.clone());
        shaped
    }

    /// The glyphs of one code row in the terminal font, pinned to columns: `text` is the
    /// row's chars, `cols` each char's column and then the row's end column (code-core's
    /// `Layout::text` and `Layout::cols`), `spans` its colour spans, whose bold or italic
    /// faces pick the font. Cached by all three (a span's colour aside): an unchanged row
    /// costs one hash and no allocation.
    pub fn shape_code_row(
        &mut self,
        text: &str,
        cols: &[u16],
        spans: &[canvas_draw::ColorSpan],
    ) -> Arc<ShapedRow> {
        let advance = self.term_metrics().advance;
        let key = code::row_key(text, cols, spans);
        if let Some(hit) = self.code_rows.get(&key) {
            return hit.clone();
        }
        if self.code_rows.len() >= ROW_CACHE_MAX {
            self.code_rows.clear();
        }
        let platform = &mut self.platform;
        let shaped = Arc::new(code::shape_row(
            text,
            cols,
            spans,
            advance,
            &mut self.code_scratch,
            &mut self.row_scratch,
            |text, style, out| platform.shape_term_run(text, style, out),
        ));
        self.code_rows.insert(key, shaped.clone());
        shaped
    }

    /// The pixel size to rasterize terminal glyphs at for an `exact` pixel size. Settled, it
    /// is `exact`. While the zoom moves it is the recently drawn size nearest to `exact`
    /// (the caller stretches those rasters), or a new size on a quarter-octave ladder when
    /// none is within 1.5×, so a zoom animation rasterizes a handful of sizes, not one per
    /// frame.
    pub fn term_raster_px(&mut self, exact: f32, settled: bool) -> f32 {
        if self.atlas.generation() != self.raster_generation {
            self.raster_generation = self.atlas.generation();
            self.raster_sizes.clear();
        }
        let exact_q = GlyphKey::px_size(exact);
        let stretch = |q: u32| (q as f32 / exact_q as f32).ln().abs();
        let pick = if settled {
            exact_q
        } else {
            match self
                .raster_sizes
                .iter()
                .copied()
                .min_by(|a, b| stretch(*a).total_cmp(&stretch(*b)))
            {
                Some(q) if stretch(q) <= MAX_STRETCH.ln() => q,
                _ => GlyphKey::px_size(2f32.powf((exact.max(1.0).log2() * 4.0).round() / 4.0)),
            }
        };
        if let Some(i) = self.raster_sizes.iter().position(|&q| q == pick) {
            self.raster_sizes.remove(i);
        }
        self.raster_sizes.insert(0, pick);
        self.raster_sizes.truncate(RASTER_SIZES_MAX);
        pick as f32 / GlyphKey::SIZE_STEPS
    }

    pub fn metrics(&mut self, spec: FontSpec) -> Metrics {
        self.platform.metrics(spec)
    }

    /// Shape `text` as one line (no wrapping). Cached by text and font.
    pub fn shape(&mut self, text: &str, spec: FontSpec) -> Arc<ShapedLine> {
        let font = spec.key();
        if let Some(hit) = self.shapes.get(&font).and_then(|lines| lines.get(text)) {
            return hit.clone();
        }
        if self.shapes.values().map(HashMap::len).sum::<usize>() >= SHAPE_CACHE_MAX {
            self.shapes.clear();
        }
        let shaped = Arc::new(self.platform.shape(text, spec));
        self.shapes
            .entry(font)
            .or_default()
            .insert(text.to_owned(), shaped.clone());
        shaped
    }

    /// `text` shaped to fit `max_width`, cut at a char boundary and ended with an ellipsis
    /// when it does not fit.
    pub fn shape_truncated(
        &mut self,
        text: &str,
        spec: FontSpec,
        max_width: f32,
    ) -> Arc<ShapedLine> {
        let full = self.shape(text, spec);
        if full.width <= max_width + 0.01 {
            return full;
        }
        let ell = self.shape(ELLIPSIS, spec).width;
        let room = (max_width - ell).max(0.0);
        // Largest char prefix whose caret fits; carets of RTL text are not monotonic, so
        // scan rather than binary-search.
        let cut = full
            .carets
            .iter()
            .enumerate()
            .filter(|(_, x)| **x <= room)
            .map(|(i, _)| i)
            .max()
            .unwrap_or(0);
        let mut s: String = text.chars().take(cut).collect();
        s.truncate(s.trim_end().len());
        s.push_str(ELLIPSIS);
        self.shape(&s, spec)
    }

    /// The atlas slot for a glyph, rasterizing it on first use. `None` for ink-less glyphs.
    pub fn glyph(&mut self, key: GlyphKey) -> Option<AtlasEntry> {
        self.entry(AtlasKey::Glyph(key), true)
    }

    /// [`glyph`](Self::glyph) that never clears the atlas: `None` when the glyph is not
    /// cached and no page has room for it.
    pub fn glyph_without_eviction(&mut self, key: GlyphKey) -> Option<AtlasEntry> {
        self.entry(AtlasKey::Glyph(key), false)
    }

    /// The atlas slot for a glyph or sprite, rasterizing it on first use. With `evict`, a
    /// full atlas is cleared to make room; without, such a miss is `None`.
    pub fn entry(&mut self, key: AtlasKey, evict: bool) -> Option<AtlasEntry> {
        if let Some(hit) = self.atlas.get(key) {
            return hit;
        }
        let raster = match &key {
            AtlasKey::Glyph(g) => self.platform.rasterize(g),
            AtlasKey::Sprite(s) => sprite::rasterize(*s).unwrap_or_else(RasterGlyph::empty),
            AtlasKey::Image(id) => match self.images.get(id) {
                Some(image) => RasterGlyph::clone(image),
                None => return None,
            },
        };
        if evict {
            self.atlas.insert(key, &raster)
        } else {
            self.atlas.insert_without_eviction(key, &raster)
        }
    }

    /// Hand the renderer an image (premultiplied RGBA, `width * height * 4` bytes, at most
    /// a page) to draw as `canvas_draw::ImageId(id)`; it enters the atlas when first drawn
    /// and again after the atlas is cleared. Handing an id over again replaces its image and
    /// frees its old slot (a live page's next frame), so a live image never fills the atlas.
    pub fn set_image(&mut self, id: u64, width: u32, height: u32, rgba: Vec<u8>) {
        let fits = width > 0 && height > 0 && width <= PAGE_SIZE && height <= PAGE_SIZE;
        if !fits || rgba.len() != (width * height * 4) as usize {
            tracing::warn!(id, width, height, bytes = rgba.len(), "image not taken");
            return;
        }
        if self.images.contains_key(&id) {
            self.atlas.forget(AtlasKey::Image(id));
        }
        if self.images.len() >= IMAGES_MAX {
            // Whoever draws one again hands it over again (`has_image`).
            self.images.clear();
        }
        self.images.insert(
            id,
            Arc::new(RasterGlyph {
                width,
                height,
                left: 0,
                top: 0,
                color: true,
                data: rgba,
            }),
        );
    }

    /// Whether [`set_image`](Self::set_image) was given `id`.
    pub fn has_image(&self, id: u64) -> bool {
        self.images.contains_key(&id)
    }

    pub fn atlas(&self) -> &Atlas {
        &self.atlas
    }
    pub fn atlas_mut(&mut self) -> &mut Atlas {
        &mut self.atlas
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_image_handed_over_again_replaces_its_slot_and_never_clears_the_atlas() {
        let mut ts = TextSystem::new();
        let generation = ts.atlas().generation();
        // A live page: a near-page frame a hundred times over, under one id.
        for shade in 0..100u8 {
            ts.set_image(9, 1000, 700, vec![shade; 1000 * 700 * 4]);
            let entry = ts.entry(AtlasKey::Image(9), true).expect("placed");
            let page = ts.atlas().page(entry.kind, entry.page).unwrap();
            let at = (usize::from(entry.y) * PAGE_SIZE as usize + usize::from(entry.x)) * 4;
            assert_eq!(page.data[at], shade, "the newest frame's texels");
        }
        assert_eq!(
            ts.atlas().generation(),
            generation,
            "no frame cleared the atlas"
        );
    }

    #[test]
    fn shaping_gives_a_caret_per_boundary() {
        let mut ts = TextSystem::new();
        let line = ts.shape("héllo", FontSpec::ui(14.0));
        assert_eq!(line.carets.len(), 6);
        assert!(line.width > 0.0);
        assert!(line.carets.windows(2).all(|w| w[1] >= w[0]));
        assert_eq!(line.index_at(-5.0), 0);
        assert_eq!(line.index_at(line.width + 5.0), 5);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn italic_text_gets_a_face_of_its_own() {
        let mut ts = TextSystem::new();
        for base in [FontSpec::ui(14.0), FontSpec::mono(13.0)] {
            let upright = ts.shape("Slant", base);
            let italic = ts.shape("Slant", base.italic(true));
            assert_ne!(upright.glyphs[0].font, italic.glyphs[0].font, "{base:?}");
            let key = GlyphKey {
                font: italic.glyphs[0].font,
                glyph: italic.glyphs[0].glyph,
                size_q: GlyphKey::ui_size(14.0, 2.0),
                subpixel: 0,
            };
            assert!(ts.glyph(key).is_some(), "it rasterizes");
        }
    }

    #[test]
    fn truncation_fits_and_ends_with_an_ellipsis() {
        let mut ts = TextSystem::new();
        let spec = FontSpec::ui(13.0);
        let full = ts.shape("a fairly long agent title that will not fit", spec);
        let cut = ts.shape_truncated("a fairly long agent title that will not fit", spec, 80.0);
        assert!(cut.width <= 80.5, "{}", cut.width);
        assert!(cut.width < full.width);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn glyphs_rasterize_into_the_atlas() {
        let mut ts = TextSystem::new();
        let spec = FontSpec::ui(14.0);
        let line = ts.shape("A😀", spec);
        assert_eq!(line.glyphs.len(), 2);
        let key = |g: &ShapedGlyph| GlyphKey {
            font: g.font,
            glyph: g.glyph,
            size_q: GlyphKey::ui_size(14.0, 2.0),
            subpixel: 0,
        };
        let a = ts.glyph(key(&line.glyphs[0])).expect("A has ink");
        assert_eq!(a.kind, PageKind::Alpha);
        assert!(a.w > 4 && a.h > 10, "{a:?}");
        let e = ts.glyph(key(&line.glyphs[1])).expect("emoji has ink");
        assert_eq!(e.kind, PageKind::Color, "emoji go to the RGBA page");
        assert_eq!(ts.atlas_mut().take_uploads().len(), 2);
    }

    fn cells(text: &str) -> Vec<Cell> {
        text.chars()
            .map(|c| Cell {
                text: c.to_string(),
                ..Cell::default()
            })
            .collect()
    }

    #[test]
    fn unchanged_rows_are_not_reshaped() {
        let mut ts = TextSystem::new();
        let a = ts.shape_row(&cells("hello"));
        let mut recoloured = cells("hello");
        recoloured[0].fg = canvas_draw::cells::Rgb(9, 9, 9);
        assert!(Arc::ptr_eq(&a, &ts.shape_row(&recoloured)), "a cache hit");
        assert!(!Arc::ptr_eq(&a, &ts.shape_row(&cells("hellp"))));
        assert_eq!(a.glyphs.len(), 5);
        ts.set_term_font(Some("Menlo"), 14.0);
        assert!(
            !Arc::ptr_eq(&a, &ts.shape_row(&cells("hello"))),
            "a new font reshapes"
        );
    }

    #[test]
    fn zooming_reuses_the_nearest_raster_until_it_settles() {
        let mut ts = TextSystem::new();
        assert_eq!(ts.term_raster_px(26.0, true), 26.0);
        assert_eq!(ts.term_raster_px(30.0, false), 26.0, "within 1.5×: stretch");
        let far = ts.term_raster_px(52.0, false);
        assert!(
            far != 26.0 && (far / 52.0 - 1.0).abs() < 0.1,
            "a ladder size: {far}"
        );
        assert_eq!(ts.term_raster_px(50.0, false), far, "reused while moving");
        assert_eq!(ts.term_raster_px(50.0, true), 50.0, "exact once settled");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn monaco_13_at_2x_matches_a_native_terminal_cell() {
        let mut ts = TextSystem::new();
        ts.set_term_font(Some("Monaco"), 13.0);
        let m = ts.term_metrics();
        assert!((m.advance * 13.0 - 7.801).abs() < 0.01, "{m:?}");
        assert_eq!(m.cell_px(26.0), (16, 35));
        let l = m.layout(26.0, 35.0);
        assert_eq!((l.baseline, l.underline_top, l.line), (27.0, 28.0, 2.0));
        // Monaco ships no bold: it is synthesized, so bold text still shapes and has ink.
        let mut bold = cells("B");
        bold[0].flags = canvas_draw::cells::flags::BOLD;
        let b = ts.shape_row(&bold).glyphs[0];
        let r = ts.shape_row(&cells("B")).glyphs[0];
        assert_ne!(b.font, r.font, "a synthetic bold face");
        let ink = |ts: &mut TextSystem, font| {
            ts.glyph(GlyphKey {
                font,
                glyph: r.glyph,
                size_q: GlyphKey::px_size(26.0),
                subpixel: 0,
            })
            .map(|e| e.w)
        };
        assert!(ink(&mut ts, b.font) > ink(&mut ts, r.font), "bold is wider");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn cjk_and_emoji_fall_back_and_fit_their_cells() {
        use canvas_draw::cells::flags::{WIDE, WIDE_SPACER};
        let mut ts = TextSystem::new();
        ts.set_term_font(Some("Monaco"), 13.0);
        let wide = |s: &str| {
            vec![
                Cell {
                    text: s.into(),
                    flags: WIDE,
                    ..Cell::default()
                },
                Cell {
                    flags: WIDE_SPACER,
                    ..Cell::default()
                },
            ]
        };
        let cjk = ts.shape_row(&wide("日")).glyphs.clone();
        assert_eq!(cjk.len(), 1);
        assert_ne!(
            cjk[0].font,
            ts.shape_row(&cells("a")).glyphs[0].font,
            "a fallback face"
        );
        assert!(
            !cjk[0].color && cjk[0].x > 0.0,
            "centred in its two cells: {cjk:?}"
        );
        let emoji = ts.shape_row(&wide("😀")).glyphs.clone();
        assert!(emoji[0].color && emoji[0].scale < 1.0, "fitted: {emoji:?}");
        // A ZWJ family and a VS16 heart are one glyph each.
        assert_eq!(ts.shape_row(&wide("👨‍👩‍👧")).glyphs.len(), 1);
        assert_eq!(ts.shape_row(&wide("❤️")).glyphs.len(), 1);
    }
}
