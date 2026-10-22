//! Browser text is shaped and rasterized by Canvas2D, then uploaded to the same
//! coverage atlas as native text. A glyph here is a shaped run, not a Unicode scalar:
//! ligatures, combining marks and contextual scripts must not be rasterized separately.

use crate::atlas::{GlyphKey, RasterGlyph};
use crate::term::{RunGlyph, TermMetrics};
use crate::{FontSpec, Metrics, ShapedGlyph, ShapedLine, Weight};
use std::collections::HashMap;
use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, ContextAttributes2d, HtmlCanvasElement};

#[derive(Clone, PartialEq)]
struct Face {
    family: String,
    weight: Weight,
    italic: bool,
}

impl Face {
    fn css(&self, px: f32) -> String {
        let weight = match self.weight {
            Weight::Regular => 400,
            Weight::Medium => 500,
            Weight::Semibold => 600,
            Weight::Bold => 700,
        };
        let style = if self.italic { "italic" } else { "normal" };
        format!("{style} {weight} {px}px {}", self.family)
    }
}

pub(crate) struct Platform {
    canvas: HtmlCanvasElement,
    context: CanvasRenderingContext2d,
    selected: Option<(u16, f32)>,
    faces: Vec<Face>,
    runs: Vec<String>,
    run_ids: HashMap<String, u32>,
    mono: String,
}

impl Platform {
    pub(crate) fn new() -> Self {
        let document = web_sys::window()
            .and_then(|w| w.document())
            .expect("canvas text requires a browser document on the main thread");
        let canvas: HtmlCanvasElement = document
            .create_element("canvas")
            .expect("create text canvas")
            .dyn_into()
            .expect("canvas element");
        let options = ContextAttributes2d::new();
        options.set_will_read_frequently(true);
        let context = canvas
            .get_context_with_context_options("2d", &options)
            .expect("query Canvas2D")
            .expect("Canvas2D is required for text rasterization")
            .dyn_into()
            .expect("Canvas2D context");
        Self {
            canvas,
            context,
            selected: None,
            faces: Vec::new(),
            runs: Vec::new(),
            run_ids: HashMap::new(),
            mono: "monospace".into(),
        }
    }

    fn face(&mut self, spec: FontSpec) -> u16 {
        let face = Face {
            family: if spec.mono {
                self.mono.clone()
            } else {
                "sans-serif".into()
            },
            weight: spec.weight,
            italic: spec.italic,
        };
        if let Some(i) = self.faces.iter().position(|f| *f == face) {
            return i as u16;
        }
        let id = u16::try_from(self.faces.len()).expect("browser font registry exhausted");
        self.faces.push(face);
        id
    }

    fn select(&mut self, font: u16, px: f32) {
        if self.selected == Some((font, px)) {
            return;
        }
        self.context.set_font(&self.faces[font as usize].css(px));
        self.context.set_text_baseline("alphabetic");
        self.context.set_text_align("left");
        self.context.set_fill_style_str("white");
        self.selected = Some((font, px));
    }

    pub(crate) fn metrics(&mut self, spec: FontSpec) -> Metrics {
        let font = self.face(spec);
        self.select(font, spec.size);
        let m = self.context.measure_text("Mg").expect("measure font");
        Metrics {
            ascent: m.font_bounding_box_ascent() as f32,
            descent: m.font_bounding_box_descent() as f32,
            leading: 0.0,
            advance: self
                .context
                .measure_text("0")
                .expect("measure zero")
                .width() as f32,
        }
    }

    pub(crate) fn set_term_font(&mut self, family: Option<&str>, _size: f32) -> TermMetrics {
        self.mono = family.map_or_else(|| "monospace".into(), |s| format!("{:?}, monospace", s));
        let m = self.metrics(FontSpec::mono(100.0));
        TermMetrics {
            ascent: m.ascent / 100.0,
            descent: m.descent / 100.0,
            leading: 0.0,
            advance: m.advance / 100.0,
            underline_position: 0.1,
            underline_thickness: 0.06,
            strike_position: 0.3,
            strike_thickness: 0.06,
        }
    }

    pub(crate) fn shape(&mut self, text: &str, spec: FontSpec) -> ShapedLine {
        let font = self.face(spec);
        self.select(font, spec.size);
        let width = self
            .context
            .measure_text(text)
            .expect("measure run")
            .width() as f32;
        let metrics = self.metrics(spec);
        let glyph = match self.run_ids.get(text) {
            Some(&id) => id,
            None => {
                let id = u32::try_from(self.runs.len()).expect("browser run registry exhausted");
                self.runs.push(text.into());
                self.run_ids.insert(text.into(), id);
                id
            }
        };
        let mut carets = vec![0.0];
        for (i, c) in text.char_indices() {
            carets.push(
                self.context
                    .measure_text(&text[..i + c.len_utf8()])
                    .expect("measure caret prefix")
                    .width() as f32,
            );
        }
        ShapedLine {
            glyphs: vec![ShapedGlyph {
                font,
                glyph,
                x: 0.0,
                y: 0.0,
                color: false,
            }],
            width,
            ascent: metrics.ascent,
            descent: metrics.descent,
            carets,
        }
    }

    pub(crate) fn shape_term_run(&mut self, text: &str, style: usize, out: &mut Vec<RunGlyph>) {
        let spec = FontSpec::mono(100.0)
            .weight(if style & 1 != 0 {
                Weight::Bold
            } else {
                Weight::Regular
            })
            .italic(style & 2 != 0);
        use unicode_segmentation::UnicodeSegmentation;
        let mut index = 0;
        // Cell and code consumers recolour and pin clusters independently. Keep each
        // grapheme intact, but do not merge an entire row into its first cell.
        for cluster in text.graphemes(true) {
            let line = self.shape(cluster, spec);
            for g in line.glyphs {
                out.push(RunGlyph {
                    index,
                    font: g.font,
                    glyph: g.glyph,
                    x: 0.0,
                    y: 0.0,
                    advance: line.width / 100.0,
                    color: false,
                });
            }
            index += cluster.encode_utf16().count();
        }
    }

    pub(crate) fn rasterize(&mut self, key: &GlyphKey) -> RasterGlyph {
        self.select(key.font, key.size_px());
        let m = self
            .context
            .measure_text(&self.runs[key.glyph as usize])
            .expect("measure ink bounds");
        let sub = f64::from(key.subpixel) * 0.25;
        let left = (sub - m.actual_bounding_box_left()).floor() as i32 - 1;
        let right = (sub + m.actual_bounding_box_right()).ceil() as i32 + 1;
        let top = m.actual_bounding_box_ascent().ceil() as i32 + 1;
        let bottom = -m.actual_bounding_box_descent().ceil() as i32 - 1;
        let (width, height) = ((right - left).max(0) as u32, (top - bottom).max(0) as u32);
        if width == 0 || height == 0 {
            return RasterGlyph::empty();
        }
        if width > crate::PAGE_SIZE - 2 || height > crate::PAGE_SIZE - 2 {
            tracing::warn!(
                width,
                height,
                "browser text run exceeds atlas page; truncate the label"
            );
            return RasterGlyph::empty();
        }
        if width > self.canvas.width() {
            self.canvas.set_width(width);
            self.selected = None;
        }
        if height > self.canvas.height() {
            self.canvas.set_height(height);
            self.selected = None;
        }
        self.select(key.font, key.size_px());
        self.context
            .clear_rect(0.0, 0.0, f64::from(width), f64::from(height));
        self.context
            .fill_text(
                &self.runs[key.glyph as usize],
                -f64::from(left) + sub,
                f64::from(top),
            )
            .expect("rasterize text run");
        let rgba = self
            .context
            .get_image_data(0.0, 0.0, f64::from(width), f64::from(height))
            .expect("read text coverage")
            .data();
        RasterGlyph {
            width,
            height,
            left,
            top,
            color: false,
            data: rgba.0.chunks_exact(4).map(|p| p[3]).collect(),
        }
    }
}
