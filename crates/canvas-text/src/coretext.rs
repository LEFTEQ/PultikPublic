//! Core Text backend: `CTLine` shaping (bidi, font fallback, caret offsets) and glyph
//! rasterization with `CTFontDrawGlyphs` into CoreGraphics bitmap contexts — coverage into
//! an alpha-only context, colour fonts (Apple Color Emoji) into premultiplied RGBA.
//!
//! The terminal font is resolved once per [`Platform::set_term_font`]: the family's four
//! styles (missing bold or italic synthesized: stroked or skewed at raster time) and the
//! fallback cascade from `CTFontCopyDefaultCascadeListForLanguages`, attached to every style
//! so Core Text never re-enumerates fallback fonts per run.

use crate::atlas::{GlyphKey, RasterGlyph};
use crate::term::{RunGlyph, TermMetrics};
use crate::{FontSpec, Metrics, ShapedGlyph, ShapedLine, Weight};
use objc2_core_foundation::{
    CFArray, CFAttributedString, CFDictionary, CFIndex, CFNumber, CFRange, CFRetained, CFString,
    CFType, CGAffineTransform, CGFloat, CGPoint, CGRect, CGSize, Type,
};
use objc2_core_graphics::{
    CGBitmapContextCreate, CGColorSpace, CGContext, CGImageAlphaInfo, CGTextDrawingMode,
};
use objc2_core_text::{
    CTFont, CTFontDescriptor, CTFontOrientation, CTFontSymbolicTraits, CTFontTableOptions,
    CTFontUIFontType, CTLine, CTRun, kCTFontAttributeName, kCTFontCascadeListAttribute,
    kCTFontFamilyNameAttribute, kCTFontTableOS2, kCTFontTraitsAttribute, kCTFontWeightTrait,
    kCTLigatureAttributeName,
};
use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr::{NonNull, null, null_mut};

/// Resized face copies kept for rasterization before the cache starts over.
const SIZED_MAX: usize = 256;

/// Synthesized styles of a face: drawn stroked (bold) or skewed (italic).
const SYNTH_BOLD: u8 = 1;
const SYNTH_ITALIC: u8 = 2;
/// Synthetic italic slant (x += SKEW * y), about 12°.
const SKEW: CGFloat = 0.21;
/// Synthetic bold stroke width per pixel of size.
const BOLD_STROKE: CGFloat = 0.04;
/// The system monospaced font (`NSFont.monospacedSystemFont`), SF Mono.
const SYSTEM_MONO: &str = ".AppleSystemUIFontMonospaced-Regular";

struct Face {
    /// The face at the size it was first seen; resized copies are made per glyph size.
    font: CFRetained<CTFont>,
    color: bool,
    synth: u8,
}

/// The terminal font's four styles: regular, bold, italic, bold italic.
struct TermFaces {
    size: CGFloat,
    /// Styles missing from the family, synthesized from the closest real face.
    synth: [u8; 4],
    /// Attributed-string attributes per style (the font, with the cascade attached).
    attrs: [CFRetained<CFDictionary<CFString, CFType>>; 4],
    regular: CFRetained<CTFont>,
}

pub(crate) struct Platform {
    faces: Vec<Face>,
    by_name: HashMap<(String, u8), u16>,
    /// Base font per (mono, weight, size key) with its face index.
    base: HashMap<crate::FontKey, (CFRetained<CTFont>, u16)>,
    /// Face resized to a pixel size (glyph-key size), for rasterization; at most
    /// [`SIZED_MAX`] entries, since every settled zoom level adds one per face.
    sized: HashMap<(u16, u32), CFRetained<CTFont>>,
    term: Option<TermFaces>,
    /// Reused per-run buffers for terminal shaping.
    ids: Vec<u16>,
    positions: Vec<CGPoint>,
    advances: Vec<CGSize>,
    indices: Vec<CFIndex>,
}

/// Core Text's `kCTFontWeightTrait` values for our weights.
fn weight_trait(w: Weight) -> f64 {
    match w {
        Weight::Regular => 0.0,
        Weight::Medium => 0.23,
        Weight::Semibold => 0.3,
        Weight::Bold => 0.4,
    }
}

impl Platform {
    pub(crate) fn new() -> Self {
        Self {
            faces: Vec::new(),
            by_name: HashMap::new(),
            base: HashMap::new(),
            sized: HashMap::new(),
            term: None,
            ids: Vec::new(),
            positions: Vec::new(),
            advances: Vec::new(),
            indices: Vec::new(),
        }
    }

    /// The face for `spec` and the synthesis it needs: an italic the family lacks is the
    /// upright face slanted at raster time.
    fn create_base(&mut self, spec: FontSpec) -> (CFRetained<CTFont>, u8) {
        let upright = self.create_upright(spec);
        if !spec.italic {
            return (upright, 0);
        }
        let size = spec.size.max(1.0) as CGFloat;
        let italic = CTFontSymbolicTraits::TraitItalic;
        // SAFETY: a null matrix keeps the font's; the mask selects only the italic trait.
        let real = unsafe { upright.copy_with_symbolic_traits(size, null(), italic, italic) }
            // SAFETY: plain getter.
            .filter(|f| unsafe { f.symbolic_traits() }.contains(italic));
        match real {
            Some(face) => (face, 0),
            None => (upright, SYNTH_ITALIC),
        }
    }

    fn create_upright(&mut self, spec: FontSpec) -> CFRetained<CTFont> {
        let size = spec.size.max(1.0) as CGFloat;
        let font = if spec.mono {
            // Monospaced text (cards, the bar's code) uses the terminal font.
            let regular = self.term_faces().regular.clone();
            // SAFETY: a null matrix and descriptor keep the face.
            unsafe { regular.copy_with_attributes(size, null(), None) }
        } else {
            // SAFETY: plain constructor; a `None` language means the user's languages.
            unsafe { CTFont::new_ui_font_for_language(CTFontUIFontType::System, size, None) }
                .unwrap_or_else(|| {
                    let name = CFString::from_str("Helvetica");
                    // SAFETY: a null matrix means identity.
                    unsafe { CTFont::with_name(&name, size, null()) }
                })
        };
        if spec.weight == Weight::Regular {
            return font;
        }
        let number = CFNumber::new_f64(weight_trait(spec.weight));
        // SAFETY: the statics are Core Text's constant attribute keys.
        let (traits_key, weight_key) = unsafe { (kCTFontTraitsAttribute, kCTFontWeightTrait) };
        let traits = CFDictionary::<CFString, CFType>::from_slices(&[weight_key], &[&number]);
        let attrs = CFDictionary::<CFString, CFType>::from_slices(&[traits_key], &[&traits]);
        // SAFETY: the dictionary holds CFString keys and CF values as Core Text expects.
        unsafe {
            let desc = CTFontDescriptor::with_attributes(attrs.as_ref());
            font.copy_with_attributes(size, null(), Some(&desc))
        }
    }

    fn base_font(&mut self, spec: FontSpec) -> (CFRetained<CTFont>, u16) {
        if let Some((f, id)) = self.base.get(&spec.key()) {
            return (f.clone(), *id);
        }
        let (font, synth) = self.create_base(spec);
        let id = self.face_id(&font, synth);
        self.base.insert(spec.key(), (font.clone(), id));
        (font, id)
    }

    /// The face index of `font` drawn with `synth`, registering it by PostScript name on
    /// first sight.
    fn face_id(&mut self, font: &CTFont, synth: u8) -> u16 {
        // SAFETY: plain getter on a valid font.
        let key = (unsafe { font.post_script_name() }.to_string(), synth);
        if let Some(&id) = self.by_name.get(&key) {
            return id;
        }
        // SAFETY: plain getter.
        let traits = unsafe { font.symbolic_traits() };
        let id = self.faces.len() as u16;
        self.faces.push(Face {
            font: font.retain(),
            color: traits.contains(CTFontSymbolicTraits::TraitColorGlyphs),
            synth,
        });
        self.by_name.insert(key, id);
        id
    }

    fn term_faces(&mut self) -> &TermFaces {
        if self.term.is_none() {
            self.set_term_font(None, crate::DEFAULT_TERM_SIZE);
        }
        match &self.term {
            Some(t) => t,
            None => unreachable!("set_term_font always resolves a font"),
        }
    }

    /// Resolve the terminal font: `family` (`None` = the system monospaced font) at `size`
    /// points, its four styles and the fallback cascade. Returns its metrics.
    pub(crate) fn set_term_font(&mut self, family: Option<&str>, size: f32) -> TermMetrics {
        let size = size.max(1.0) as CGFloat;
        let regular = resolve_family(family, size);
        // The fallback cascade (CJK, symbols, emoji) for the user's languages, resolved once.
        // SAFETY: a `None` list means the user's preferred languages.
        let cascade = unsafe { regular.default_cascade_list_for_languages(None) };
        let cascade_desc = cascade.map(|list| {
            // SAFETY: Core Text's constant attribute key.
            let key = unsafe { kCTFontCascadeListAttribute };
            let list: &CFType = list.as_ref();
            let attrs = CFDictionary::<CFString, CFType>::from_slices(&[key], &[list]);
            // SAFETY: a CFString-keyed dictionary of CF values.
            unsafe { CTFontDescriptor::with_attributes(attrs.as_ref()) }
        });
        let real = |traits: CTFontSymbolicTraits| -> Option<CFRetained<CTFont>> {
            // SAFETY: a null matrix keeps the font's; the mask selects the traits we ask for.
            let f = unsafe { regular.copy_with_symbolic_traits(size, null(), traits, traits) }?;
            // SAFETY: plain getter.
            unsafe { f.symbolic_traits() }.contains(traits).then_some(f)
        };
        let bold = real(CTFontSymbolicTraits::TraitBold);
        let italic = real(CTFontSymbolicTraits::TraitItalic);
        let bold_italic = real(CTFontSymbolicTraits::TraitBold | CTFontSymbolicTraits::TraitItalic);
        // Each style from its own face, else the closest real one plus synthesis.
        let styles: [(CFRetained<CTFont>, u8); 4] = [
            (regular.clone(), 0),
            bold.clone()
                .map_or((regular.clone(), SYNTH_BOLD), |f| (f, 0)),
            italic
                .clone()
                .map_or((regular.clone(), SYNTH_ITALIC), |f| (f, 0)),
            match (bold_italic, bold, italic) {
                (Some(f), _, _) => (f, 0),
                (None, Some(b), _) => (b, SYNTH_ITALIC),
                (None, None, Some(i)) => (i, SYNTH_BOLD),
                _ => (regular.clone(), SYNTH_BOLD | SYNTH_ITALIC),
            },
        ];
        // SAFETY: Core Text's constant attribute keys.
        let (font_key, ligature_key) = unsafe { (kCTFontAttributeName, kCTLigatureAttributeName) };
        // Only the ligatures a script requires: a cell holds one character, and an optional
        // ligature across cells would be drawn inside the first cell (ligatures are tier 2).
        let essential_only = CFNumber::new_i32(0);
        let attrs = styles.each_ref().map(|(font, _)| {
            // SAFETY: a null matrix keeps the face; the descriptor only adds the cascade.
            let font = match &cascade_desc {
                Some(d) => unsafe { font.copy_with_attributes(size, null(), Some(d)) },
                None => font.clone(),
            };
            let value: &CFType = font.as_ref();
            CFDictionary::<CFString, CFType>::from_slices(
                &[font_key, ligature_key],
                &[value, essential_only.as_ref()],
            )
        });
        let metrics = term_metrics(&regular, size);
        // SAFETY: plain getters.
        let (ps, family_name) = unsafe { (regular.post_script_name(), regular.family_name()) };
        tracing::info!(
            requested = ?family,
            font = %ps,
            family = %family_name,
            size,
            synthesized = ?styles.each_ref().map(|s| s.1),
            "terminal font"
        );
        // Monospaced UI text follows the terminal font.
        self.base.retain(|k, _| !k.0);
        self.term = Some(TermFaces {
            size,
            synth: styles.map(|s| s.1),
            attrs,
            regular,
        });
        metrics
    }

    /// Shape one run of terminal text in style `style` (0 regular, 1 bold, 2 italic, 3
    /// bold italic), appending its glyphs in ems.
    pub(crate) fn shape_term_run(&mut self, text: &str, style: usize, out: &mut Vec<RunGlyph>) {
        let term = self.term_faces();
        let (attrs, synth, size) = (
            term.attrs[style & 3].clone(),
            term.synth[style & 3],
            term.size,
        );
        let string = CFString::from_str(text);
        // SAFETY: a valid string and a dictionary of CFString → CF values.
        let Some(attributed) =
            (unsafe { CFAttributedString::new(None, Some(&string), Some(attrs.as_ref())) })
        else {
            tracing::error!("CFAttributedStringCreate returned null");
            return;
        };
        // SAFETY: a valid attributed string.
        let line = unsafe { CTLine::with_attributed_string(&attributed) };
        // SAFETY: Core Text's constant attribute key.
        let font_key = unsafe { kCTFontAttributeName };
        // SAFETY: `CTLineGetGlyphRuns` returns an array of CTRun.
        let runs: CFRetained<CFArray<CTRun>> =
            unsafe { CFRetained::cast_unchecked(line.glyph_runs()) };
        for run in runs.iter() {
            // SAFETY: run attributes are a CFString-keyed dictionary.
            let run_attrs: CFRetained<CFDictionary<CFString, CFType>> =
                unsafe { CFRetained::cast_unchecked(run.attributes()) };
            let Some(font) = run_attrs
                .get(font_key)
                .and_then(|v| v.downcast::<CTFont>().ok())
            else {
                continue;
            };
            // A synthesized style applies to fallback faces in the run too.
            let face = self.face_id(&font, synth);
            let color = self.faces[face as usize].color;
            // SAFETY: plain getter.
            let n = unsafe { run.glyph_count() }.max(0) as usize;
            if n == 0 {
                continue;
            }
            self.ids.resize(n, 0);
            self.positions.resize(n, CGPoint { x: 0.0, y: 0.0 });
            self.advances.resize(n, CGSize::default());
            self.indices.resize(n, 0);
            let all = CFRange {
                location: 0,
                length: 0,
            };
            // SAFETY: every buffer holds exactly `glyph_count` elements; a zero-length range
            // means the whole run.
            unsafe {
                run.glyphs(all, NonNull::from(&mut self.ids[0]));
                run.positions(all, NonNull::from(&mut self.positions[0]));
                run.advances(all, NonNull::from(&mut self.advances[0]));
                run.string_indices(all, NonNull::from(&mut self.indices[0]));
            }
            for i in 0..n {
                out.push(RunGlyph {
                    index: self.indices[i].max(0) as usize,
                    font: face,
                    glyph: self.ids[i] as u32,
                    x: (self.positions[i].x / size) as f32,
                    y: (-self.positions[i].y / size) as f32,
                    advance: (self.advances[i].width / size) as f32,
                    color,
                });
            }
        }
    }

    pub(crate) fn metrics(&mut self, spec: FontSpec) -> Metrics {
        let (font, _) = self.base_font(spec);
        let zero = self.shape("0", spec);
        // SAFETY: plain getters.
        unsafe {
            Metrics {
                ascent: font.ascent() as f32,
                descent: font.descent() as f32,
                leading: font.leading() as f32,
                advance: zero.width,
            }
        }
    }

    pub(crate) fn shape(&mut self, text: &str, spec: FontSpec) -> ShapedLine {
        let (font, base_face) = self.base_font(spec);
        // SAFETY: plain getter.
        let base_name = unsafe { font.post_script_name() }.to_string();
        let string = CFString::from_str(text);
        // SAFETY: Core Text's constant attribute key.
        let font_key = unsafe { kCTFontAttributeName };
        let font_ref: &CFType = font.as_ref();
        let attrs = CFDictionary::<CFString, CFType>::from_slices(&[font_key], &[font_ref]);
        // SAFETY: a valid string and a dictionary of CFString → CF values.
        let Some(attributed) =
            (unsafe { CFAttributedString::new(None, Some(&string), Some(attrs.as_ref())) })
        else {
            tracing::error!("CFAttributedStringCreate returned null");
            return ShapedLine::default();
        };
        // SAFETY: a valid attributed string.
        let line = unsafe { CTLine::with_attributed_string(&attributed) };
        let (mut ascent, mut descent, mut leading): (CGFloat, CGFloat, CGFloat) = (0.0, 0.0, 0.0);
        // SAFETY: the out pointers are valid locals.
        let width = unsafe { line.typographic_bounds(&mut ascent, &mut descent, &mut leading) };

        let mut glyphs = Vec::new();
        // SAFETY: `CTLineGetGlyphRuns` returns an array of CTRun.
        let runs: CFRetained<CFArray<CTRun>> =
            unsafe { CFRetained::cast_unchecked(line.glyph_runs()) };
        for run in runs.iter() {
            // SAFETY: run attributes are a CFString-keyed dictionary.
            let run_attrs: CFRetained<CFDictionary<CFString, CFType>> =
                unsafe { CFRetained::cast_unchecked(run.attributes()) };
            // A run in the base font keeps the base face (a synthesized italic stays slanted);
            // fallback fonts get faces of their own.
            let face = run_attrs
                .get(font_key)
                .and_then(|v| v.downcast::<CTFont>().ok())
                // SAFETY: plain getter.
                .filter(|f| unsafe { f.post_script_name() }.to_string() != base_name)
                .map_or(base_face, |f| self.face_id(&f, 0));
            let color = self.faces[face as usize].color;
            // SAFETY: plain getter.
            let n = unsafe { run.glyph_count() }.max(0) as usize;
            if n == 0 {
                continue;
            }
            let mut ids = vec![0u16; n];
            let mut pos = vec![CGPoint { x: 0.0, y: 0.0 }; n];
            let all = CFRange {
                location: 0,
                length: 0,
            };
            // SAFETY: the buffers hold exactly `glyph_count` elements; a zero-length range
            // means the whole run.
            unsafe {
                run.glyphs(all, NonNull::from(&mut ids[0]));
                run.positions(all, NonNull::from(&mut pos[0]));
            }
            glyphs.extend(ids.iter().zip(&pos).map(|(&g, p)| ShapedGlyph {
                font: face,
                glyph: g as u32,
                x: p.x as f32,
                y: -p.y as f32,
                color,
            }));
        }

        let mut carets = Vec::with_capacity(text.chars().count() + 1);
        let mut utf16 = 0isize;
        // SAFETY: indices are UTF-16 offsets within the line's string; a null secondary
        // offset pointer is allowed.
        carets.push(unsafe { line.offset_for_string_index(0, null_mut()) } as f32);
        for c in text.chars() {
            utf16 += c.len_utf16() as isize;
            carets.push(unsafe { line.offset_for_string_index(utf16, null_mut()) } as f32);
        }

        ShapedLine {
            glyphs,
            width: width as f32,
            ascent: ascent as f32,
            descent: descent as f32,
            carets,
        }
    }

    /// The face at a pixel size; a synthetic italic face comes back skewed.
    fn sized(&mut self, face: u16, size_q: u32) -> Option<CFRetained<CTFont>> {
        let key = (face, size_q);
        if let Some(f) = self.sized.get(&key) {
            return Some(f.clone());
        }
        let face = self.faces.get(face as usize)?;
        let skew = CGAffineTransform {
            a: 1.0,
            b: 0.0,
            c: SKEW,
            d: 1.0,
            tx: 0.0,
            ty: 0.0,
        };
        let matrix: *const CGAffineTransform = if face.synth & SYNTH_ITALIC != 0 {
            &skew
        } else {
            null()
        };
        let px = size_q as CGFloat / GlyphKey::SIZE_STEPS as CGFloat;
        // SAFETY: `matrix` is null (identity) or points at a local; no descriptor keeps the face.
        let f = unsafe { face.font.copy_with_attributes(px, matrix, None) };
        if self.sized.len() >= SIZED_MAX {
            // Copies are cheap to remake; the sizes in use come back on their next glyph.
            self.sized.clear();
        }
        self.sized.insert(key, f.clone());
        Some(f)
    }

    pub(crate) fn rasterize(&mut self, key: &GlyphKey) -> RasterGlyph {
        let Some((color, synth)) = self
            .faces
            .get(key.font as usize)
            .map(|f| (f.color, f.synth))
        else {
            tracing::warn!(?key, "rasterize: unknown face");
            return RasterGlyph::empty();
        };
        let Some(font) = self.sized(key.font, key.size_q) else {
            return RasterGlyph::empty();
        };
        let stroke = if synth & SYNTH_BOLD != 0 {
            (key.size_px() as CGFloat * BOLD_STROKE).max(0.5)
        } else {
            0.0
        };
        let mut glyph = key.glyph as u16;
        let mut bounds = CGRect::default();
        // SAFETY: one glyph in, one rect out.
        unsafe {
            font.bounding_rects_for_glyphs(
                CTFontOrientation::Default,
                NonNull::from(&mut glyph),
                &mut bounds,
                1,
            );
        }
        if bounds.size.width <= 0.0 || bounds.size.height <= 0.0 {
            return RasterGlyph::empty();
        }
        // A synthetic bold stroke grows the ink by half its width on every side.
        let bounds = CGRect {
            origin: CGPoint {
                x: bounds.origin.x - stroke,
                y: bounds.origin.y - stroke,
            },
            size: CGSize {
                width: bounds.size.width + 2.0 * stroke,
                height: bounds.size.height + 2.0 * stroke,
            },
        };
        let sub = key.subpixel as f64 * 0.25;
        let left = (bounds.origin.x + sub).floor() as i32 - 1;
        let bottom = bounds.origin.y.floor() as i32 - 1;
        let right = (bounds.origin.x + bounds.size.width + sub).ceil() as i32 + 1;
        let top = (bounds.origin.y + bounds.size.height).ceil() as i32 + 1;
        let (w, h) = ((right - left) as usize, (top - bottom) as usize);
        let bpp = if color { 4 } else { 1 };
        let mut data = vec![0u8; w * h * bpp];
        let (space, info) = if color {
            (
                CGColorSpace::new_device_rgb(),
                CGImageAlphaInfo::PremultipliedLast.0,
            )
        } else {
            (None, CGImageAlphaInfo::Only.0)
        };
        // SAFETY: `data` outlives the context (dropped at the end of this block) and holds
        // `h` rows of `w * bpp` bytes.
        let Some(ctx) = (unsafe {
            CGBitmapContextCreate(
                data.as_mut_ptr() as *mut c_void,
                w,
                h,
                8,
                w * bpp,
                space.as_deref(),
                info,
            )
        }) else {
            tracing::error!(?key, w, h, "CGBitmapContextCreate failed");
            return RasterGlyph::empty();
        };
        draw_glyph(
            &ctx,
            &font,
            glyph,
            -left as f64 + sub,
            -bottom as f64,
            stroke,
        );
        drop(ctx);
        RasterGlyph {
            width: w as u32,
            height: h as u32,
            left,
            top,
            color,
            data,
        }
    }
}

/// The system monospaced font, else Menlo (the user's fixed-pitch font).
fn system_mono(size: CGFloat) -> CFRetained<CTFont> {
    let name = CFString::from_str(SYSTEM_MONO);
    // SAFETY: a null matrix means identity.
    let font = unsafe { CTFont::with_name(&name, size, null()) };
    // SAFETY: plain getter.
    if unsafe { font.post_script_name() }.to_string() == SYSTEM_MONO {
        return font;
    }
    // SAFETY: plain constructor; `None` means the user's preferred languages.
    unsafe { CTFont::new_ui_font_for_language(CTFontUIFontType::UserFixedPitch, size, None) }
        .unwrap_or(font)
}

/// The configured terminal family at `size`, matched by family name, then by PostScript or
/// full name; an unknown name falls back to the system monospaced font.
fn resolve_family(family: Option<&str>, size: CGFloat) -> CFRetained<CTFont> {
    let Some(want) = family.map(str::trim).filter(|f| !f.is_empty()) else {
        return system_mono(size);
    };
    let name = CFString::from_str(want);
    // SAFETY: Core Text's constant attribute key.
    let family_key = unsafe { kCTFontFamilyNameAttribute };
    let value: &CFType = name.as_ref();
    let attrs = CFDictionary::<CFString, CFType>::from_slices(&[family_key], &[value]);
    // SAFETY: a CFString-keyed dictionary; a null matrix means identity.
    let by_family = unsafe {
        let desc = CTFontDescriptor::with_attributes(attrs.as_ref());
        CTFont::with_font_descriptor(&desc, size, null())
    };
    // SAFETY: a null matrix means identity.
    let by_name = unsafe { CTFont::with_name(&name, size, null()) };
    for font in [by_family, by_name] {
        // SAFETY: plain getters.
        let (fam, ps) = unsafe { (font.family_name(), font.post_script_name()) };
        if fam.to_string().eq_ignore_ascii_case(want) || ps.to_string().eq_ignore_ascii_case(want) {
            return font;
        }
    }
    tracing::warn!(
        family = want,
        "terminal font not found; using the system monospaced font"
    );
    system_mono(size)
}

/// The terminal metrics of `font` at `size`, in ems.
fn term_metrics(font: &CTFont, size: CGFloat) -> TermMetrics {
    // The widest printable ASCII glyph is the cell advance.
    let mut chars: Vec<u16> = (0x20u16..0x7F).collect();
    let mut glyphs = vec![0u16; chars.len()];
    let mut advances = vec![CGSize::default(); chars.len()];
    // SAFETY: both buffers hold `chars.len()` elements.
    unsafe {
        font.glyphs_for_characters(
            NonNull::from(&mut chars[0]),
            NonNull::from(&mut glyphs[0]),
            chars.len() as CFIndex,
        );
        font.advances_for_glyphs(
            CTFontOrientation::Horizontal,
            NonNull::from(&mut glyphs[0]),
            advances.as_mut_ptr(),
            glyphs.len() as CFIndex,
        );
    }
    let advance = advances
        .iter()
        .zip(&glyphs)
        .filter(|(_, g)| **g != 0)
        .map(|(a, _)| a.width)
        .fold(0.0, CGFloat::max);
    // SAFETY: plain getters.
    let (ascent, descent, leading, ul_pos, ul_thick, x_height, upm) = unsafe {
        (
            font.ascent(),
            font.descent(),
            font.leading(),
            font.underline_position(),
            font.underline_thickness(),
            font.x_height(),
            font.units_per_em().max(1) as CGFloat,
        )
    };
    let em = |v: CGFloat| (v / size) as f32;
    let underline_thickness = if ul_thick > 0.0 {
        ul_thick
    } else {
        size / 14.0
    };
    // The strikeout from the OS/2 table when it sits plausibly within the x-height, else
    // centred on half the x-height with the underline's thickness.
    // SAFETY: plain getter; returns a copy of the table.
    let os2 = unsafe { font.table(kCTFontTableOS2, CTFontTableOptions::NoOptions) }
        .map(|d| d.to_vec())
        .filter(|d| d.len() >= 30);
    let strike = os2.and_then(|d| {
        let size_units = i16::from_be_bytes([d[26], d[27]]) as CGFloat;
        let pos_units = i16::from_be_bytes([d[28], d[29]]) as CGFloat;
        let (thick, pos) = (size_units / upm * size, pos_units / upm * size);
        (thick > 0.0 && pos >= 0.3 * x_height && pos <= 0.8 * x_height).then_some((pos, thick))
    });
    let (strike_position, strike_thickness) = strike.unwrap_or((
        x_height * 0.5 + underline_thickness * 0.5,
        underline_thickness,
    ));
    TermMetrics {
        ascent: em(ascent),
        descent: em(descent),
        leading: em(leading),
        advance: em(if advance > 0.0 { advance } else { size * 0.6 }),
        underline_position: em(-ul_pos),
        underline_thickness: em(underline_thickness),
        strike_position: em(strike_position),
        strike_thickness: em(strike_thickness),
    }
}

fn draw_glyph(ctx: &CGContext, font: &CTFont, glyph: u16, x: f64, y: f64, stroke: CGFloat) {
    CGContext::set_should_antialias(Some(ctx), true);
    CGContext::set_allows_font_subpixel_positioning(Some(ctx), true);
    CGContext::set_should_subpixel_position_fonts(Some(ctx), true);
    CGContext::set_allows_font_subpixel_quantization(Some(ctx), false);
    CGContext::set_should_smooth_fonts(Some(ctx), false);
    CGContext::set_gray_fill_color(Some(ctx), 1.0, 1.0);
    if stroke > 0.0 {
        // Synthetic bold: fill and stroke the outline.
        CGContext::set_text_drawing_mode(Some(ctx), CGTextDrawingMode::FillStroke);
        CGContext::set_line_width(Some(ctx), stroke);
        CGContext::set_gray_stroke_color(Some(ctx), 1.0, 1.0);
    }
    let mut glyph = glyph;
    let mut pos = CGPoint { x, y };
    // SAFETY: one glyph and one position, both valid locals.
    unsafe {
        font.draw_glyphs(NonNull::from(&mut glyph), NonNull::from(&mut pos), 1, ctx);
    }
}
