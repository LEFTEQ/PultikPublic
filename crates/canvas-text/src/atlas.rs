//! Glyph atlas: 1024² pages packed with etagere. Alpha (coverage) glyphs go to R8 pages and
//! colour glyphs (emoji) to RGBA pages. Pages remember the rect written since the last
//! upload, so the GPU uploads only what changed.

use crate::sprite::SpriteKey;
use etagere::{AtlasAllocator, size2};
use std::collections::HashMap;

/// Page edge in pixels.
pub const PAGE_SIZE: u32 = 1024;
/// Pages per kind; the GPU allocates texture arrays of this many layers.
pub const MAX_ALPHA_PAGES: usize = 4;
pub const MAX_COLOR_PAGES: usize = 2;
/// Empty texels kept around every glyph so linear sampling never bleeds.
const PAD: i32 = 1;

/// What identifies one rasterized glyph image.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlyphKey {
    /// Index of the font face in the [`crate::TextSystem`]'s registry.
    pub font: u16,
    pub glyph: u32,
    /// The size rasterized at, in device pixels (point size × backing scale), in
    /// 1/[`GlyphKey::SIZE_STEPS`] px.
    pub size_q: u32,
    /// Horizontal subpixel offset in quarter pixels, `0..4`.
    pub subpixel: u8,
}

impl GlyphKey {
    /// Steps per pixel of [`GlyphKey::size_q`].
    pub const SIZE_STEPS: f32 = 16.0;

    /// UI text: the point size bucketed to half points, times the backing scale bucketed
    /// to quarters, so nearby sizes share rasters.
    pub fn ui_size(size_pt: f32, scale: f32) -> u32 {
        let half_points = (size_pt * 2.0).round().max(1.0);
        let quarter_scale = (scale * 4.0).round().max(1.0);
        Self::px_size(half_points * 0.5 * quarter_scale * 0.25)
    }

    /// An exact pixel size (terminals rasterize at the size they draw).
    pub fn px_size(px: f32) -> u32 {
        (px * Self::SIZE_STEPS).round().clamp(1.0, u32::MAX as f32) as u32
    }

    /// The pixel size this key is rasterized at.
    pub fn size_px(&self) -> f32 {
        self.size_q as f32 / Self::SIZE_STEPS
    }
}

/// Everything the atlas caches: font glyphs, our procedural sprites and images handed to
/// the [`crate::TextSystem`] (chip thumbnails, `canvas_draw::ImageId`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AtlasKey {
    Glyph(GlyphKey),
    Sprite(SpriteKey),
    Image(u64),
}

impl From<GlyphKey> for AtlasKey {
    fn from(k: GlyphKey) -> Self {
        AtlasKey::Glyph(k)
    }
}

impl From<SpriteKey> for AtlasKey {
    fn from(k: SpriteKey) -> Self {
        AtlasKey::Sprite(k)
    }
}

/// A rasterized glyph: tightly cropped pixels plus the offset of their top-left corner from
/// the pen position on the baseline (x right, y up).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RasterGlyph {
    pub width: u32,
    pub height: u32,
    pub left: i32,
    pub top: i32,
    /// Colour (RGBA, premultiplied) rather than coverage.
    pub color: bool,
    /// `width * height` bytes (alpha) or `width * height * 4` (RGBA), top row first.
    pub data: Vec<u8>,
}

impl RasterGlyph {
    /// A glyph with no ink (space).
    pub fn empty() -> Self {
        Self {
            width: 0,
            height: 0,
            left: 0,
            top: 0,
            color: false,
            data: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageKind {
    Alpha,
    Color,
}

/// Where a glyph lives in the atlas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AtlasEntry {
    pub kind: PageKind,
    pub page: u16,
    pub x: u16,
    pub y: u16,
    pub w: u16,
    pub h: u16,
    pub left: i16,
    pub top: i16,
}

/// A rect of a page written since the last [`Atlas::take_uploads`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dirty {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl Dirty {
    fn union(self, o: Dirty) -> Dirty {
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        Dirty {
            x,
            y,
            w: (self.x + self.w).max(o.x + o.w) - x,
            h: (self.y + self.h).max(o.y + o.h) - y,
        }
    }
}

pub struct Page {
    pub kind: PageKind,
    /// `PAGE_SIZE²` texels, 1 (alpha) or 4 (RGBA) bytes each.
    pub data: Vec<u8>,
    pub dirty: Option<Dirty>,
    alloc: AtlasAllocator,
}

impl Page {
    fn new(kind: PageKind) -> Self {
        let bpp = Self::bpp_of(kind);
        Self {
            kind,
            data: vec![0; (PAGE_SIZE * PAGE_SIZE) as usize * bpp],
            dirty: None,
            alloc: AtlasAllocator::new(size2(PAGE_SIZE as i32, PAGE_SIZE as i32)),
        }
    }
    fn bpp_of(kind: PageKind) -> usize {
        match kind {
            PageKind::Alpha => 1,
            PageKind::Color => 4,
        }
    }
    pub fn bytes_per_pixel(&self) -> usize {
        Self::bpp_of(self.kind)
    }
}

/// One upload the GPU must perform: `page` of `kind`, rect `dirty`, from `page.data`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Upload {
    pub kind: PageKind,
    pub page: u16,
    pub rect: Dirty,
}

/// The glyph cache: key → atlas slot (or `None` for ink-less glyphs).
#[derive(Default)]
pub struct Atlas {
    alpha: Vec<Page>,
    color: Vec<Page>,
    entries: HashMap<AtlasKey, Option<AtlasEntry>>,
    /// Where each image's slot was allocated, so [`Atlas::forget`] can free it.
    images: HashMap<AtlasKey, (PageKind, usize, etagere::AllocId)>,
    generation: u64,
}

impl Atlas {
    pub fn new() -> Self {
        Self::default()
    }

    /// Free `key`'s slot (an image handed over again: a live page's next frame), so its next
    /// draw places it afresh instead of the atlas filling up and clearing every glyph. Its
    /// texels are zeroed, pad and all, so no neighbour samples them.
    pub fn forget(&mut self, key: impl Into<AtlasKey>) {
        let key = key.into();
        self.entries.remove(&key);
        let Some((kind, index, id)) = self.images.remove(&key) else {
            return;
        };
        let pages = match kind {
            PageKind::Alpha => &mut self.alpha,
            PageKind::Color => &mut self.color,
        };
        let Some(page) = pages.get_mut(index) else {
            return;
        };
        let rect = page.alloc.get(id);
        page.alloc.deallocate(id);
        let bpp = page.bytes_per_pixel();
        let (x0, y0) = (rect.min.x.max(0) as usize, rect.min.y.max(0) as usize);
        let (x1, y1) = (
            (rect.max.x as usize).min(PAGE_SIZE as usize),
            (rect.max.y as usize).min(PAGE_SIZE as usize),
        );
        for y in y0..y1 {
            let row = (y * PAGE_SIZE as usize + x0) * bpp;
            page.data[row..row + (x1 - x0) * bpp].fill(0);
        }
        let d = Dirty {
            x: x0 as u32,
            y: y0 as u32,
            w: (x1 - x0) as u32,
            h: (y1 - y0) as u32,
        };
        if d.w > 0 && d.h > 0 {
            page.dirty = Some(page.dirty.map_or(d, |old| old.union(d)));
        }
    }

    /// Bumped whenever the atlas is cleared: entries resolved before are invalid.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn get(&self, key: impl Into<AtlasKey>) -> Option<Option<AtlasEntry>> {
        self.entries.get(&key.into()).copied()
    }

    /// Store a rasterized glyph. When every page of its kind is full the whole atlas is
    /// cleared (generation bump) and the glyph inserted into the fresh pages.
    pub fn insert(&mut self, key: impl Into<AtlasKey>, glyph: &RasterGlyph) -> Option<AtlasEntry> {
        self.insert_with(key.into(), glyph, true)
    }

    /// [`insert`](Self::insert) that never clears: when every page of the glyph's kind is
    /// full it is `None`, and not remembered, so a later frame can place it again.
    pub fn insert_without_eviction(
        &mut self,
        key: impl Into<AtlasKey>,
        glyph: &RasterGlyph,
    ) -> Option<AtlasEntry> {
        self.insert_with(key.into(), glyph, false)
    }

    fn insert_with(
        &mut self,
        key: AtlasKey,
        glyph: &RasterGlyph,
        evict: bool,
    ) -> Option<AtlasEntry> {
        if glyph.width == 0 || glyph.height == 0 {
            self.entries.insert(key, None);
            return None;
        }
        if glyph.width + 2 * PAD as u32 > PAGE_SIZE || glyph.height + 2 * PAD as u32 > PAGE_SIZE {
            tracing::warn!(
                ?key,
                glyph.width,
                glyph.height,
                "glyph larger than an atlas page"
            );
            self.entries.insert(key, None);
            return None;
        }
        let kind = if glyph.color {
            PageKind::Color
        } else {
            PageKind::Alpha
        };
        let (entry, id) = match self.place(kind, glyph) {
            Some(e) => e,
            None if evict => {
                self.clear();
                self.place(kind, glyph)?
            }
            None => return None,
        };
        if matches!(key, AtlasKey::Image(_)) {
            self.images.insert(key, (kind, usize::from(entry.page), id));
        }
        self.entries.insert(key, Some(entry));
        Some(entry)
    }

    fn place(
        &mut self,
        kind: PageKind,
        glyph: &RasterGlyph,
    ) -> Option<(AtlasEntry, etagere::AllocId)> {
        let (pages, max) = match kind {
            PageKind::Alpha => (&mut self.alpha, MAX_ALPHA_PAGES),
            PageKind::Color => (&mut self.color, MAX_COLOR_PAGES),
        };
        let size = size2(glyph.width as i32 + 2 * PAD, glyph.height as i32 + 2 * PAD);
        let mut found = None;
        for (i, p) in pages.iter_mut().enumerate() {
            if let Some(a) = p.alloc.allocate(size) {
                found = Some((i, a));
                break;
            }
        }
        if found.is_none() && pages.len() < max {
            let mut p = Page::new(kind);
            let a = p.alloc.allocate(size)?;
            pages.push(p);
            found = Some((pages.len() - 1, a));
        }
        let (index, alloc) = found?;
        let page = &mut pages[index];
        let x = (alloc.rectangle.min.x + PAD) as u32;
        let y = (alloc.rectangle.min.y + PAD) as u32;
        let bpp = page.bytes_per_pixel();
        let row = glyph.width as usize * bpp;
        for r in 0..glyph.height as usize {
            let dst = ((y as usize + r) * PAGE_SIZE as usize + x as usize) * bpp;
            page.data[dst..dst + row].copy_from_slice(&glyph.data[r * row..(r + 1) * row]);
        }
        let d = Dirty {
            x,
            y,
            w: glyph.width,
            h: glyph.height,
        };
        page.dirty = Some(page.dirty.map_or(d, |old| old.union(d)));
        let entry = AtlasEntry {
            kind,
            page: index as u16,
            x: x as u16,
            y: y as u16,
            w: glyph.width as u16,
            h: glyph.height as u16,
            left: glyph.left as i16,
            top: glyph.top as i16,
        };
        Some((entry, alloc.id))
    }

    /// Forget every glyph; pages are zeroed and fully re-uploaded.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.images.clear();
        self.generation += 1;
        for p in self.alpha.iter_mut().chain(self.color.iter_mut()) {
            p.alloc.clear();
            p.data.fill(0);
            p.dirty = Some(Dirty {
                x: 0,
                y: 0,
                w: PAGE_SIZE,
                h: PAGE_SIZE,
            });
        }
    }

    pub fn page(&self, kind: PageKind, index: u16) -> Option<&Page> {
        match kind {
            PageKind::Alpha => self.alpha.get(index as usize),
            PageKind::Color => self.color.get(index as usize),
        }
    }

    /// The rects written since the last call; the caller uploads them from [`Self::page`].
    pub fn take_uploads(&mut self) -> Vec<Upload> {
        let mut out = Vec::new();
        for (kind, pages) in [
            (PageKind::Alpha, &mut self.alpha),
            (PageKind::Color, &mut self.color),
        ] {
            for (i, p) in pages.iter_mut().enumerate() {
                if let Some(rect) = p.dirty.take() {
                    out.push(Upload {
                        kind,
                        page: i as u16,
                        rect,
                    });
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn glyph(w: u32, h: u32) -> RasterGlyph {
        RasterGlyph {
            width: w,
            height: h,
            left: 0,
            top: h as i32,
            color: false,
            data: vec![255; (w * h) as usize],
        }
    }

    fn key(g: u32) -> GlyphKey {
        GlyphKey {
            font: 0,
            glyph: g,
            size_q: GlyphKey::ui_size(13.0, 2.0),
            subpixel: 0,
        }
    }

    #[test]
    fn uploads_only_what_changed() {
        let mut a = Atlas::new();
        let e = a.insert(key(1), &glyph(10, 12)).unwrap();
        let ups = a.take_uploads();
        assert_eq!(ups.len(), 1);
        assert_eq!((ups[0].rect.w, ups[0].rect.h), (10, 12));
        assert!(
            a.take_uploads().is_empty(),
            "nothing new, nothing to upload"
        );
        assert_eq!(a.get(key(1)), Some(Some(e)));
        let page = a.page(PageKind::Alpha, 0).unwrap();
        assert_eq!(
            page.data[e.y as usize * PAGE_SIZE as usize + e.x as usize],
            255
        );
    }

    #[test]
    fn a_full_atlas_clears_and_bumps_the_generation() {
        let mut a = Atlas::new();
        let big = glyph(1000, 1000);
        for g in 0..MAX_ALPHA_PAGES as u32 {
            a.insert(key(g), &big).unwrap();
        }
        assert_eq!(a.generation(), 0);
        a.insert(key(99), &big).unwrap();
        assert_eq!(a.generation(), 1);
        assert_eq!(a.get(key(0)), None);
        assert!(a.get(key(99)).is_some());
    }

    #[test]
    fn insert_without_eviction_leaves_a_full_atlas_alone() {
        let mut a = Atlas::new();
        let big = glyph(1000, 1000);
        for g in 0..MAX_ALPHA_PAGES as u32 {
            a.insert(key(g), &big).unwrap();
        }
        assert_eq!(a.insert_without_eviction(key(99), &big), None);
        assert_eq!(a.generation(), 0);
        assert!(a.get(key(0)).is_some());
        assert_eq!(a.get(key(99)), None, "not remembered as inkless");
    }
}
