//! Our own procedural sprites: box drawing (U+2500–257F), block elements (U+2580–259F) and
//! powerline separators (U+E0B0–E0BF), drawn from geometry instead of any font's glyphs.
//!
//! Each sprite is rasterized at the exact cell size in device pixels and fills the cell, so
//! neighbouring cells join without seams: a straight stroke always lands on the same pixel
//! rows (or columns) in every glyph that has an arm on that side. Pure Rust, every platform.

use crate::atlas::RasterGlyph;

/// Whether `c` is drawn by [`rasterize`] rather than taken from a font.
pub fn is_sprite(c: char) -> bool {
    matches!(c as u32, 0x2500..=0x259F | 0xE0B0..=0xE0BF)
}

/// The sprite a terminal cell shows: its text is exactly one sprite char.
pub fn cell_sprite(text: &str) -> Option<char> {
    let mut chars = text.chars();
    let c = chars.next()?;
    (chars.next().is_none() && is_sprite(c)).then_some(c)
}

/// Identifies one sprite raster: the char at a cell size and line thickness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SpriteKey {
    pub ch: char,
    /// The cell in device pixels.
    pub w: u16,
    pub h: u16,
    /// Light line thickness in device pixels (the font's underline thickness); heavy lines
    /// are twice it, double lines two light lines one light line apart.
    pub thickness: u16,
}

/// The sprite as a cell-filling coverage bitmap (`w * h` bytes, top row first; `left` 0 and
/// `top` 0 mean the bitmap's corner is the cell's). `None` when `key.ch` is not a sprite or
/// the cell is empty.
pub fn rasterize(key: SpriteKey) -> Option<RasterGlyph> {
    if !is_sprite(key.ch) || key.w == 0 || key.h == 0 {
        return None;
    }
    let mut c = Canvas::new(key.w as i32, key.h as i32, key.thickness as i32);
    let cp = key.ch as u32;
    match cp {
        0x2580..=0x259F => c.block(cp),
        0xE0B0..=0xE0BF => c.powerline(cp),
        0x2504..=0x250B | 0x254C..=0x254F => c.dashed(cp),
        0x256D..=0x2570 => c.arc(cp),
        0x2571..=0x2573 => c.diagonal(cp),
        _ => {
            let arms = box_arms(cp)?;
            c.lines(arms);
        }
    }
    Some(RasterGlyph {
        width: key.w as u32,
        height: key.h as u32,
        left: 0,
        top: 0,
        color: false,
        data: c.px,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Line {
    None,
    Light,
    Heavy,
    Double,
}

impl Line {
    fn single(self) -> bool {
        matches!(self, Line::Light | Line::Heavy)
    }
}

/// Arms of the plain box-drawing chars as `[up, right, down, left]`: `.` none, `l` light,
/// `h` heavy, `d` double. Dashes, arcs and diagonals (`-`) are drawn by their own code.
const ARMS: [&str; 128] = [
    ".l.l", ".h.h", "l.l.", "h.h.", "-", "-", "-", "-", // 2500
    "-", "-", "-", "-", ".ll.", ".hl.", ".lh.", ".hh.", // 2508
    "..ll", "..lh", "..hl", "..hh", "ll..", "lh..", "hl..", "hh..", // 2510
    "l..l", "l..h", "h..l", "h..h", "lll.", "lhl.", "hll.", "llh.", // 2518
    "hlh.", "hhl.", "lhh.", "hhh.", "l.ll", "l.lh", "h.ll", "l.hl", // 2520
    "h.hl", "h.lh", "l.hh", "h.hh", ".lll", ".llh", ".hll", ".hlh", // 2528
    ".lhl", ".lhh", ".hhl", ".hhh", "ll.l", "ll.h", "lh.l", "lh.h", // 2530
    "hl.l", "hl.h", "hh.l", "hh.h", "llll", "lllh", "lhll", "lhlh", // 2538
    "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh", // 2540
    "lhhh", "hlhh", "hhhl", "hhhh", "-", "-", "-", "-", // 2548
    ".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd", // 2550
    "ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.", // 2558
    "ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d", // 2560
    "dl.l", "dd.d", "ldld", "dldl", "dddd", "-", "-", "-", // 2568
    "-", "-", "-", "-", "...l", "l...", ".l..", "..l.", // 2570
    "...h", "h...", ".h..", "..h.", ".h.l", "l.h.", ".l.h", "h.l.", // 2578
];

fn box_arms(cp: u32) -> Option<[Line; 4]> {
    let code = ARMS.get(cp.checked_sub(0x2500)? as usize)?.as_bytes();
    if code.len() != 4 {
        return None;
    }
    let line = |b: u8| match b {
        b'l' => Line::Light,
        b'h' => Line::Heavy,
        b'd' => Line::Double,
        _ => Line::None,
    };
    Some([line(code[0]), line(code[1]), line(code[2]), line(code[3])])
}

/// A half-open pixel range `[0, 1)`.
type Span = (i32, i32);

/// `thick` pixels centred in `len` (the same split for every glyph of a cell size, so
/// strokes line up across cells).
fn centered(len: i32, thick: i32) -> Span {
    let thick = thick.clamp(1, len.max(1));
    let a = (len - thick) / 2;
    (a, a + thick)
}

/// The two lines of a double stroke: light lines one light line apart, centred, with at
/// least a pixel to spare on each side so neighbouring double lines stay apart.
fn double(len: i32, t: i32) -> (Span, Span) {
    let t = t.min((len - 2) / 3).max(1);
    let a = (len - 3 * t) / 2;
    ((a, a + t), (a + 2 * t, a + 3 * t))
}

/// Subsamples per pixel edge for anti-aliased shapes.
const SS: i32 = 4;

struct Canvas {
    w: i32,
    h: i32,
    /// Light line thickness.
    t: i32,
    px: Vec<u8>,
}

impl Canvas {
    fn new(w: i32, h: i32, thickness: i32) -> Self {
        // A light line never exceeds a third of the cell, so double lines still fit.
        let t = thickness.clamp(1, (w.min(h) / 3).max(1));
        Self {
            w,
            h,
            t,
            px: vec![0; (w * h) as usize],
        }
    }

    fn heavy(&self) -> i32 {
        (2 * self.t).min(self.w.min(self.h)).max(1)
    }

    /// Fill `[x0, x1) × [y0, y1)` (clamped) with coverage `a`.
    fn rect(&mut self, x: Span, y: Span, a: u8) {
        let (x0, x1) = (x.0.max(0), x.1.min(self.w));
        let (y0, y1) = (y.0.max(0), y.1.min(self.h));
        for row in y0..y1 {
            let base = (row * self.w) as usize;
            for v in &mut self.px[base + x0 as usize..base + x1.max(x0) as usize] {
                *v = (*v).max(a);
            }
        }
    }

    /// Anti-aliased coverage of `inside` (cell pixel space, y down), merged by maximum.
    fn shape(&mut self, inside: impl Fn(f32, f32) -> bool) {
        let step = 1.0 / SS as f32;
        for y in 0..self.h {
            for x in 0..self.w {
                let mut hits = 0;
                for j in 0..SS {
                    for i in 0..SS {
                        let sx = x as f32 + (i as f32 + 0.5) * step;
                        let sy = y as f32 + (j as f32 + 0.5) * step;
                        hits += i32::from(inside(sx, sy));
                    }
                }
                if hits > 0 {
                    let a = ((hits * 255 + SS * SS / 2) / (SS * SS)) as u8;
                    let v = &mut self.px[(y * self.w + x) as usize];
                    *v = (*v).max(a);
                }
            }
        }
    }

    /// Horizontal and vertical arms meeting in the middle, with joins worked out per
    /// weight so corners, tees and crosses close cleanly (double lines nest).
    fn lines(&mut self, arms: [Line; 4]) {
        let [up, right, down, left] = arms;
        let (w, h, t, th) = (self.w, self.h, self.t, self.heavy());
        let v_light = centered(w, t);
        let v_heavy = centered(w, th);
        let (vl, vr) = double(w, t);
        let h_light = centered(h, t);
        let h_heavy = centered(h, th);
        let (ht, hb) = double(h, t);

        // The widest single stroke on each axis, which perpendicular arms run into.
        let widest = |a: Line, b: Line, light: Span, heavy: Span| -> Option<Span> {
            if a == Line::Heavy || b == Line::Heavy {
                Some(heavy)
            } else if a == Line::Light || b == Line::Light {
                Some(light)
            } else {
                None
            }
        };
        let v_single = widest(up, down, v_light, v_heavy);
        let h_single = widest(left, right, h_light, h_heavy);
        let v_double = up == Line::Double || down == Line::Double;
        let h_double = left == Line::Double || right == Line::Double;
        let v_end = v_single.unwrap_or(v_light);
        let h_end = h_single.unwrap_or(h_light);
        let stroke = |l: Line, light: Span, heavy: Span| match l {
            Line::Heavy => heavy,
            _ => light,
        };

        // Where one line of a double arm stops: at the near line of a perpendicular double
        // arm on its own side, else at a single stroke, else at the far line of a double
        // arm on the other side (the outer corner), else the middle.
        let stop = |same: Line, other: Line, near: i32, single: i32, far: i32, mid: i32| match (
            same, other,
        ) {
            (Line::Double, _) => near,
            (s, _) if s.single() => single,
            (Line::None, Line::Double) => far,
            (Line::None, o) if o.single() => single,
            _ => mid,
        };

        // Up and down.
        if up.single() {
            let end = if h_double {
                if down.single() { hb.1 } else { ht.1 }
            } else {
                h_end.1
            };
            self.rect(stroke(up, v_light, v_heavy), (0, end), 255);
        } else if up == Line::Double {
            let l_end = stop(left, right, ht.1, h_end.1, hb.1, h_light.1);
            let r_end = stop(right, left, ht.1, h_end.1, hb.1, h_light.1);
            self.rect(vl, (0, l_end), 255);
            self.rect(vr, (0, r_end), 255);
        }
        if down.single() {
            let start = if h_double {
                if up.single() { ht.0 } else { hb.0 }
            } else {
                h_end.0
            };
            self.rect(stroke(down, v_light, v_heavy), (start, h), 255);
        } else if down == Line::Double {
            let l_start = stop(left, right, hb.0, h_end.0, ht.0, h_light.0);
            let r_start = stop(right, left, hb.0, h_end.0, ht.0, h_light.0);
            self.rect(vl, (l_start, h), 255);
            self.rect(vr, (r_start, h), 255);
        }
        // Left and right.
        if left.single() {
            let end = if v_double {
                if right.single() { vr.1 } else { vl.1 }
            } else {
                v_end.1
            };
            self.rect((0, end), stroke(left, h_light, h_heavy), 255);
        } else if left == Line::Double {
            let t_end = stop(up, down, vl.1, v_end.1, vr.1, v_light.1);
            let b_end = stop(down, up, vl.1, v_end.1, vr.1, v_light.1);
            self.rect((0, t_end), ht, 255);
            self.rect((0, b_end), hb, 255);
        }
        if right.single() {
            let start = if v_double {
                if left.single() { vl.0 } else { vr.0 }
            } else {
                v_end.0
            };
            self.rect((start, w), stroke(right, h_light, h_heavy), 255);
        } else if right == Line::Double {
            let t_start = stop(up, down, vr.0, v_end.0, vl.0, v_light.0);
            let b_start = stop(down, up, vr.0, v_end.0, vl.0, v_light.0);
            self.rect((t_start, w), ht, 255);
            self.rect((b_start, w), hb, 255);
        }
    }

    /// Dashed lines: 2 (U+254C–F), 3 (U+2504–7) or 4 (U+2508–B) dashes per cell, each
    /// centred in its share so the pattern repeats evenly across cells.
    fn dashed(&mut self, cp: u32) {
        let (n, heavy, vertical) = match cp {
            0x2504..=0x2507 => (3, cp & 1 == 1, cp >= 0x2506),
            0x2508..=0x250B => (4, cp & 1 == 1, cp >= 0x250A),
            _ => (2, cp & 1 == 1, cp >= 0x254E),
        };
        let thick = if heavy { self.heavy() } else { self.t };
        let len = if vertical { self.h } else { self.w };
        for k in 0..n {
            let (a, b) = (k * len / n, (k + 1) * len / n);
            let gap = ((b - a) / 3).max(1);
            let dash = (a + gap / 2, b - (gap - gap / 2));
            if vertical {
                self.rect(centered(self.w, thick), dash, 255);
            } else {
                self.rect(dash, centered(self.h, thick), 255);
            }
        }
    }

    /// Rounded corners (U+256D–2570): a quarter circle between the light strokes'
    /// centre lines, finished by straight runs to the cell edges.
    fn arc(&mut self, cp: u32) {
        let (w, h, t) = (self.w, self.h, self.t);
        let vx = centered(w, t);
        let hy = centered(h, t);
        let cx = (vx.0 + vx.1) as f32 * 0.5;
        let cy = (hy.0 + hy.1) as f32 * 0.5;
        // (towards +x?, towards +y?): ╭ right+down, ╮ left+down, ╯ left+up, ╰ right+up.
        let (east, south) = match cp {
            0x256D => (true, true),
            0x256E => (false, true),
            0x256F => (false, false),
            _ => (true, false),
        };
        let rx = if east { w as f32 - cx } else { cx };
        let ry = if south { h as f32 - cy } else { cy };
        let r = rx.min(ry).max(0.5);
        let ox = if east { cx + r } else { cx - r };
        let oy = if south { cy + r } else { cy - r };
        // Straight runs from the arc's ends to the edges.
        if south {
            self.rect(vx, (oy.ceil() as i32, h), 255);
        } else {
            self.rect(vx, (0, oy.floor() as i32), 255);
        }
        if east {
            self.rect((ox.ceil() as i32, w), hy, 255);
        } else {
            self.rect((0, ox.floor() as i32), hy, 255);
        }
        let half = t as f32 * 0.5;
        self.shape(|x, y| {
            let in_quadrant =
                (if east { x <= ox } else { x >= ox }) && (if south { y <= oy } else { y >= oy });
            let d = ((x - ox).powi(2) + (y - oy).powi(2)).sqrt();
            in_quadrant && (d - r).abs() <= half
        });
    }

    /// Diagonals (U+2571–2573) corner to corner, as infinite lines so they continue into
    /// diagonal neighbours.
    fn diagonal(&mut self, cp: u32) {
        let (w, h) = (self.w as f32, self.h as f32);
        let half = self.t as f32 * 0.5;
        let len = (w * w + h * h).sqrt();
        let rising = cp == 0x2571 || cp == 0x2573;
        let falling = cp == 0x2572 || cp == 0x2573;
        self.shape(|x, y| {
            // ╲ through (0,0)–(w,h); ╱ through (w,0)–(0,h).
            let d_fall = (h * x - w * y).abs() / len;
            let d_rise = (h * x + w * y - w * h).abs() / len;
            (falling && d_fall <= half) || (rising && d_rise <= half)
        });
    }

    /// Block elements (U+2580–259F): eighths, halves, quadrants and shades. Eighth
    /// boundaries are rounded once, so complementary blocks (▀ ▄, ▌ ▐) tile exactly.
    fn block(&mut self, cp: u32) {
        let (w, h) = (self.w, self.h);
        let ev = |k: i32| (h * k + 4) / 8;
        let eh = |k: i32| (w * k + 4) / 8;
        let full = (0, w);
        let k = (cp & 0xF) as i32;
        match cp {
            0x2580 => self.rect(full, (0, ev(4)), 255),
            0x2581..=0x2588 => self.rect(full, (ev(8 - (cp - 0x2580) as i32), h), 255),
            0x2589..=0x258F => self.rect((0, eh(8 - (k - 8))), (0, h), 255),
            0x2590 => self.rect((eh(4), w), (0, h), 255),
            0x2591..=0x2593 => self.rect(full, (0, h), [64, 128, 191][(k - 1) as usize]),
            0x2594 => self.rect(full, (0, ev(1)), 255),
            0x2595 => self.rect((eh(7), w), (0, h), 255),
            _ => {
                // Quadrants: bit 0 upper left, 1 upper right, 2 lower left, 3 lower right.
                let bits = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14][(cp - 0x2596) as usize];
                let (mx, my) = (eh(4), ev(4));
                let quads = [((0, mx), (0, my)), ((mx, w), (0, my)), ((0, mx), (my, h))];
                for (i, (x, y)) in quads.into_iter().enumerate() {
                    if bits & (1 << i) != 0 {
                        self.rect(x, y, 255);
                    }
                }
                if bits & 8 != 0 {
                    self.rect((mx, w), (my, h), 255);
                }
            }
        }
    }

    /// Powerline separators (U+E0B0–E0BF): triangles, chevrons, half circles and slants.
    fn powerline(&mut self, cp: u32) {
        let (w, h) = (self.w as f32, self.h as f32);
        let half = self.t as f32 * 0.5;
        let mid = h * 0.5;
        let near = |x: f32, y: f32, a: (f32, f32), b: (f32, f32)| segment_distance((x, y), a, b);
        match cp {
            0xE0B0 => self.shape(|x, y| x <= w * (1.0 - (y - mid).abs() / mid)),
            0xE0B2 => self.shape(|x, y| x >= w * (y - mid).abs() / mid),
            0xE0B1 => self.shape(|x, y| {
                near(x, y, (0.0, 0.0), (w, mid)).min(near(x, y, (w, mid), (0.0, h))) <= half
            }),
            0xE0B3 => self.shape(|x, y| {
                near(x, y, (w, 0.0), (0.0, mid)).min(near(x, y, (0.0, mid), (w, h))) <= half
            }),
            0xE0B4..=0xE0B7 => {
                // Half an ellipse whose flat side is the cell's left (B4, B5) or right edge.
                let ox = if cp <= 0xE0B5 { 0.0 } else { w };
                let solid = cp == 0xE0B4 || cp == 0xE0B6;
                self.shape(|x, y| {
                    let e = |rx: f32, ry: f32| ((x - ox) / rx).powi(2) + ((y - mid) / ry).powi(2);
                    if solid {
                        e(w, mid) <= 1.0
                    } else {
                        e(w, mid) <= 1.0 && e((w - 2.0 * half).max(0.5), mid - 2.0 * half) > 1.0
                    }
                });
            }
            // Solid corner triangles: E0B8 ◣, E0BA ◢, E0BC ◤, E0BE ◥.
            0xE0B8 => self.shape(|x, y| x * h <= y * w),
            0xE0BA => self.shape(|x, y| (w - x) * h <= y * w),
            0xE0BC => self.shape(|x, y| x * h <= (h - y) * w),
            0xE0BE => self.shape(|x, y| (w - x) * h <= (h - y) * w),
            // Slants: E0B9 and E0BF are ╲, E0BB and E0BD are ╱.
            0xE0B9 | 0xE0BF => self.shape(|x, y| near(x, y, (0.0, 0.0), (w, h)) <= half),
            _ => self.shape(|x, y| near(x, y, (0.0, h), (w, 0.0)) <= half),
        }
    }
}

fn segment_distance(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2).clamp(0.0, 1.0)
    } else {
        0.0
    };
    ((p.0 - a.0 - t * dx).powi(2) + (p.1 - a.1 - t * dy).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn raster(ch: char, w: u16, h: u16, thickness: u16) -> RasterGlyph {
        rasterize(SpriteKey {
            ch,
            w,
            h,
            thickness,
        })
        .unwrap_or_else(|| panic!("{ch:?} is a sprite"))
    }

    fn at(g: &RasterGlyph, x: u32, y: u32) -> u8 {
        g.data[(y * g.width + x) as usize]
    }

    /// The coverage of one edge, in order: `left`/`right` columns, `top`/`bottom` rows.
    fn edge(g: &RasterGlyph, side: usize) -> Vec<u8> {
        let (w, h) = (g.width, g.height);
        match side {
            0 => (0..w).map(|x| at(g, x, 0)).collect(),
            1 => (0..h).map(|y| at(g, w - 1, y)).collect(),
            2 => (0..w).map(|x| at(g, x, h - 1)).collect(),
            _ => (0..h).map(|y| at(g, 0, y)).collect(),
        }
    }

    #[test]
    fn a_full_block_fills_every_pixel() {
        let g = raster('█', 16, 35, 2);
        assert_eq!((g.width, g.height, g.left, g.top), (16, 35, 0, 0));
        assert!(g.data.iter().all(|&a| a == 255));
    }

    #[test]
    fn the_upper_half_block_is_exactly_the_top_half() {
        for h in [34, 35] {
            let g = raster('▀', 16, h, 2);
            let lower = raster('▄', 16, h, 2);
            for y in 0..h as u32 {
                let row: Vec<u8> = (0..16).map(|x| at(&g, x, y)).collect();
                let expect = if y < (h as u32).div_ceil(2) { 255 } else { 0 };
                assert!(row.iter().all(|&a| a == expect), "row {y} of {h}");
                assert_eq!(at(&lower, 0, y), 255 - expect, "▄ completes ▀ at row {y}");
            }
        }
    }

    #[test]
    fn a_horizontal_line_runs_edge_to_edge_on_the_same_rows() {
        let g = raster('─', 16, 35, 2);
        let left = edge(&g, 3);
        assert_eq!(left, edge(&g, 1), "both ends on the same rows");
        let lit: Vec<usize> = (0..35).filter(|&y| left[y] == 255).collect();
        assert_eq!(lit, vec![16, 17], "two pixel rows, centred");
        assert!(left.iter().all(|&a| a == 0 || a == 255), "crisp, no fringe");
        // Every column is lit the same way, so the next cell continues it.
        assert!((0..16).all(|x| (0..35).all(|y| at(&g, x, y) == left[y as usize])));
    }

    #[test]
    fn corners_meet_the_lines_they_join() {
        let (horizontal, vertical) = (raster('─', 16, 35, 2), raster('│', 16, 35, 2));
        let corner = raster('┌', 16, 35, 2);
        assert_eq!(edge(&corner, 1), edge(&horizontal, 3), "right arm meets ─");
        assert_eq!(edge(&corner, 2), edge(&vertical, 0), "down arm meets │");
        assert!(
            edge(&corner, 0).iter().all(|&a| a == 0),
            "nothing on the top edge"
        );
        assert!(
            edge(&corner, 3).iter().all(|&a| a == 0),
            "nothing on the left edge"
        );
        // The bend is closed: the corner pixel where the arms cross is lit.
        assert_eq!(at(&corner, 7, 16), 255);
        let rounded = raster('╭', 16, 35, 2);
        assert_eq!(edge(&rounded, 1), edge(&horizontal, 3), "╭ meets ─");
        assert_eq!(edge(&rounded, 2), edge(&vertical, 0), "╭ meets │");
    }

    #[test]
    fn quadrants_tile_the_claude_logo() {
        let full = raster('▛', 16, 35, 2);
        let (mx, my) = (8, 18);
        assert_eq!(at(&full, 0, 0), 255);
        assert_eq!(at(&full, mx, 0), 255);
        assert_eq!(at(&full, 0, my), 255);
        assert_eq!(at(&full, mx, my), 0, "▛ leaves the lower right quadrant");
        let right = raster('▐', 16, 35, 2);
        let left = raster('▌', 16, 35, 2);
        for x in 0..16 {
            assert_eq!(
                at(&left, x, 3) ^ at(&right, x, 3),
                255,
                "▌▐ split at column {x}"
            );
        }
    }

    #[test]
    fn powerline_triangles_fill_their_flat_edge() {
        let g = raster('\u{E0B0}', 16, 35, 2);
        // Solid but for the two corner pixels, where the slopes meet the base.
        let base = edge(&g, 3);
        assert!(
            base[1..34].iter().all(|&a| a == 255),
            "the base column is solid"
        );
        assert_eq!(at(&g, 15, 0), 0, "the tip side is empty at the corner");
        assert!(
            at(&g, 15, 17) > 0,
            "the tip reaches the right edge mid-height"
        );
    }

    #[test]
    fn non_sprites_are_refused() {
        assert!(cell_sprite("a").is_none());
        assert!(cell_sprite("─a").is_none());
        assert_eq!(cell_sprite("─"), Some('─'));
        assert!(
            rasterize(SpriteKey {
                ch: 'x',
                w: 8,
                h: 16,
                thickness: 1
            })
            .is_none()
        );
    }

    /// The straight line each side of a cell must match: the light, heavy or double
    /// vertical (top/bottom edges) or horizontal (left/right edges) line.
    fn straight(line: Line, vertical: bool) -> char {
        match (line, vertical) {
            (Line::Light, true) => '│',
            (Line::Heavy, true) => '┃',
            (Line::Double, true) => '║',
            (Line::Light, false) => '─',
            (Line::Heavy, false) => '━',
            (Line::Double, false) => '═',
            (Line::None, _) => ' ',
        }
    }

    proptest! {
        /// Every plain box-drawing char, at any cell size and thickness, reaches each edge
        /// it has an arm on with exactly the straight line of that weight, and leaves the
        /// other edges empty: any two neighbours join without a seam or a step.
        #[test]
        fn every_box_char_joins_its_neighbours(
            cp in 0x2500u32..0x2580,
            w in 5u16..40,
            h in 9u16..80,
            thickness in 1u16..4,
        ) {
            let Some(arms) = box_arms(cp) else { return Ok(()) };
            let ch = char::from_u32(cp).unwrap();
            let g = raster(ch, w, h, thickness);
            for (side, arm) in arms.into_iter().enumerate() {
                let vertical = side % 2 == 0;
                if arm == Line::None {
                    prop_assert!(edge(&g, side).iter().all(|&a| a == 0), "{ch} side {side}");
                    continue;
                }
                let line = raster(straight(arm, vertical), w, h, thickness);
                prop_assert_eq!(edge(&g, side), edge(&line, side), "{} side {}", ch, side);
            }
        }
    }
}
