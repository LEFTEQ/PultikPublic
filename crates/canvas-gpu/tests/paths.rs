//! Paths and the camera, rendered offscreen and probed at known pixels (D18, phase-2 AC3):
//! a cubic with round caps, a dashed stroke with a phase, a round join, an arrowhead, the
//! 4× MSAA edge; then a camera-only redraw that moves a camera layer with no rebuild, no
//! upload and no glyph. Skips when the machine has no adapter.

use canvas_draw::{
    Camera, Dash, DisplayList, LineJoin, Path, PathOp, Point, Rect, Rgba, RoundedRect, Stroke,
    TextRun,
};
use canvas_gpu::{Gpu, GpuError, Viewport};
use canvas_text::TextSystem;
use std::sync::Arc;

fn gpu() -> Option<Gpu> {
    match Gpu::new() {
        Ok(g) => Some(g),
        Err(GpuError::Adapter(e)) => {
            eprintln!("skipping: no GPU adapter ({e})");
            None
        }
        Err(e) => panic!("{e}"),
    }
}

fn pixel(img: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * w + x) * 4) as usize;
    [img[i], img[i + 1], img[i + 2], img[i + 3]]
}

const BLACK: [u8; 4] = [0, 0, 0, 255];
const RED: [u8; 4] = [255, 0, 0, 255];
const GREEN: [u8; 4] = [0, 255, 0, 255];
const BLUE: [u8; 4] = [0, 0, 255, 255];
const WHITE: [u8; 4] = [255, 255, 255, 255];

fn p(x: f32, y: f32) -> Point {
    Point::new(x, y)
}

#[test]
fn paths_land_on_their_pixels() {
    let Some(gpu) = gpu() else { return };
    let mut dl = DisplayList::new(Rgba::BLACK);
    // A cubic, 8 pt wide with round caps: its midpoint (t = 0.5) is (100, 60).
    let mut cubic = Path::new();
    cubic
        .move_to(p(20.0, 60.0))
        .cubic_to(p(60.0, 10.0), p(140.0, 110.0), p(180.0, 60.0));
    dl.path(PathOp::stroke(
        Arc::new(cubic),
        Stroke::new(8.0, Rgba::hex(0xff0000)).round(),
    ));
    // A dash of 10 on, 10 off, 5 into the pattern, along y = 105 from x = 10.
    let mut line = Path::new();
    line.move_to(p(10.0, 105.0)).line_to(p(190.0, 105.0));
    dl.path(PathOp::stroke(
        Arc::new(line),
        Stroke::new(4.0, Rgba::hex(0x00ff00)).dash(Dash {
            on: 10.0,
            off: 10.0,
            phase: 5.0,
            speed: 0.0,
        }),
    ));
    // A 10 pt corner at (180, 20) with a round join.
    let mut corner = Path::new();
    corner
        .move_to(p(140.0, 20.0))
        .line_to(p(180.0, 20.0))
        .line_to(p(180.0, 50.0));
    dl.path(PathOp::stroke(
        Arc::new(corner),
        Stroke::new(10.0, Rgba::hex(0x0000ff)).join(LineJoin::Round),
    ));
    // An arrowhead with its tip at (40, 20), pointing right.
    dl.path(PathOp::fill(
        Arc::new(Path::arrowhead(p(40.0, 20.0), p(1.0, 0.0), 12.0, 10.0)),
        Rgba::WHITE,
    ));
    let mut text = TextSystem::new();
    let (w, _, img) = gpu
        .render_to_rgba(&dl, &mut text, 200.0, 120.0, 1.0)
        .expect("offscreen render");

    assert_eq!(pixel(&img, w, 100, 60), RED, "the cubic's midpoint");
    assert_eq!(pixel(&img, w, 100, 25), BLACK, "off the cubic");
    // Its start tangent is (40, -50): 3 pt behind the start lies in the round cap only.
    assert_eq!(pixel(&img, w, 18, 62), RED, "the round cap");
    let partial = (50..72).any(|y| {
        let [r, ..] = pixel(&img, w, 100, y);
        (30..225).contains(&r)
    });
    assert!(partial, "the 4x MSAA pass antialiases the cubic's edge");

    // Pixel centres x + 0.5 are 20.5 and 30.5 along the line: 25.5 and 35.5 into the pattern.
    assert_eq!(
        pixel(&img, w, 12, 105),
        GREEN,
        "first dash, shortened by the phase"
    );
    assert_eq!(pixel(&img, w, 20, 105), BLACK, "the gap after it");
    assert_eq!(pixel(&img, w, 30, 105), GREEN, "the second dash");
    assert_eq!(pixel(&img, w, 40, 105), BLACK, "the second gap");

    assert_eq!(pixel(&img, w, 183, 18), BLUE, "inside the round join");
    assert_eq!(pixel(&img, w, 184, 15), BLACK, "where a miter would reach");

    assert_eq!(pixel(&img, w, 34, 20), WHITE, "inside the arrowhead");
    assert_eq!(pixel(&img, w, 42, 20), BLACK, "past its tip");
    assert_eq!(pixel(&img, w, 38, 16), BLACK, "outside its flank");
}

/// The x extent of pixels on row `y` where channel `c` alone is lit.
fn span(img: &[u8], w: u32, y: u32, c: usize) -> Option<(u32, u32)> {
    let only = |px: [u8; 4]| (0..3).all(|i| (px[i] > 128) == (i == c));
    let lit: Vec<u32> = (0..w).filter(|&x| only(pixel(img, w, x, y))).collect();
    Some((*lit.first()?, *lit.last()?))
}

/// The x extent of every bright pixel in rows `ys`.
fn ink(img: &[u8], w: u32, ys: std::ops::Range<u32>) -> Option<(u32, u32)> {
    let xs: Vec<u32> = ys
        .flat_map(|y| {
            (0..w)
                .filter(move |&x| pixel(img, w, x, y)[1] > 128)
                .collect::<Vec<_>>()
        })
        .collect();
    Some((*xs.iter().min()?, *xs.iter().max()?))
}

#[test]
fn a_camera_move_redraws_without_a_rebuild() {
    let Some(gpu) = gpu() else { return };
    let mut dl = DisplayList::new(Rgba::BLACK);
    dl.push_camera(canvas_draw::Follow::BOTH);
    dl.rect(RoundedRect::new(
        Rect::new(10.0, 10.0, 20.0, 10.0),
        0.0,
        Rgba::hex(0xff0000),
    ));
    let mut bar = Path::new();
    bar.move_to(p(10.0, 40.0)).line_to(p(30.0, 40.0));
    dl.path(PathOp::stroke(
        Arc::new(bar),
        Stroke::new(4.0, Rgba::hex(0x0000ff)),
    ));
    dl.text(TextRun::new(
        "Mark",
        p(10.0, 60.0),
        14.0,
        Rgba::hex(0x00ff00),
    ));
    dl.pop_camera();
    // Outside the layer: never moves.
    dl.rect(RoundedRect::new(
        Rect::new(150.0, 10.0, 10.0, 10.0),
        0.0,
        Rgba::WHITE,
    ));

    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(Viewport {
        width_px: 200,
        height_px: 100,
        scale: 1.0,
    });
    gpu.render_offscreen(&mut off, &dl, &mut text)
        .expect("render");
    let (w, _, before) = gpu.read_offscreen(&off).expect("read");
    let stats = off.target().stats();
    let tessellations = off.target().frame().tessellations();
    assert!(
        text.atlas_mut().take_uploads().is_empty(),
        "the render took its glyphs"
    );

    gpu.set_camera(
        off.target_mut(),
        Camera {
            scale: p(2.0, 1.0),
            offset: p(20.0, 0.0),
        },
    );
    gpu.redraw_offscreen(&mut off).expect("redraw");
    let (_, _, after) = gpu.read_offscreen(&off).expect("read");

    let moved = off.target().stats();
    assert_eq!(
        moved.uploads, stats.uploads,
        "a camera move uploads no instance"
    );
    assert_eq!(moved.encodes, stats.encodes + 1);
    assert_eq!(off.target().frame().tessellations(), tessellations);
    assert!(
        text.atlas_mut().take_uploads().is_empty(),
        "and inserts no glyph"
    );

    assert_eq!(
        span(&before, w, 15, 0),
        Some((10, 29)),
        "the rect at scale 1"
    );
    assert_eq!(
        span(&after, w, 15, 0),
        Some((40, 79)),
        "x2, then 20 pt right"
    );
    assert_eq!(
        span(&after, w, 40, 2),
        Some((40, 79)),
        "the path moves with it"
    );
    assert_eq!(
        pixel(&after, w, 155, 15),
        WHITE,
        "the screen layer stays put"
    );
    #[cfg(target_os = "macos")]
    {
        let (a0, a1) = ink(&before, w, 60..80).expect("the label drew");
        let (b0, b1) = ink(&after, w, 60..80).expect("the label drew");
        assert_eq!(
            b0,
            a0 + 30,
            "the run's pen moves as the camera says: 10 pt to 40"
        );
        assert_eq!(b1 - b0, a1 - a0, "a glyph keeps its size under the zoom");
    }
}

#[test]
fn a_rebuild_of_the_same_paths_tessellates_nothing() {
    let Some(gpu) = gpu() else { return };
    let mut wave = Path::new();
    wave.move_to(p(0.0, 50.0))
        .quad_to(p(50.0, 0.0), p(100.0, 50.0));
    let wave = Arc::new(wave);
    let list = |color| {
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.path(PathOp::stroke(
            wave.clone(),
            Stroke::new(3.0, color).round(),
        ));
        dl
    };
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(Viewport {
        width_px: 100,
        height_px: 60,
        scale: 1.0,
    });
    gpu.render_offscreen(&mut off, &list(Rgba::WHITE), &mut text)
        .expect("render");
    assert_eq!(off.target().frame().tessellations(), 1);
    gpu.render_offscreen(&mut off, &list(Rgba::hex(0xff0000)), &mut text)
        .expect("render");
    assert_eq!(
        off.target().frame().tessellations(),
        1,
        "a recolour reuses the cached triangles"
    );
}

#[test]
fn a_layer_follows_only_its_axes() {
    let Some(gpu) = gpu() else { return };
    let mut dl = DisplayList::new(Rgba::BLACK);
    let square = |dl: &mut DisplayList, follow, x: f32, color| {
        dl.push_camera(follow);
        dl.rect(RoundedRect::new(Rect::new(x, 10.0, 10.0, 10.0), 0.0, color));
        dl.pop_camera();
    };
    square(&mut dl, canvas_draw::Follow::X, 10.0, Rgba::hex(0xff0000));
    square(&mut dl, canvas_draw::Follow::Y, 40.0, Rgba::hex(0x00ff00));
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(Viewport {
        width_px: 100,
        height_px: 60,
        scale: 1.0,
    });
    gpu.render_offscreen(&mut off, &dl, &mut text)
        .expect("render");
    gpu.set_camera(
        off.target_mut(),
        Camera {
            scale: p(1.0, 1.0),
            offset: p(15.0, 20.0),
        },
    );
    gpu.redraw_offscreen(&mut off).expect("redraw");
    let (w, _, img) = gpu.read_offscreen(&off).expect("read");
    assert_eq!(pixel(&img, w, 30, 15), RED, "the x layer moved right only");
    assert_eq!(pixel(&img, w, 15, 15), BLACK);
    assert_eq!(pixel(&img, w, 45, 35), GREEN, "the y layer moved down only");
    assert_eq!(pixel(&img, w, 45, 15), BLACK);
}

#[test]
fn a_pinned_rect_keeps_its_size_under_the_zoom() {
    let Some(gpu) = gpu() else { return };
    let mut dl = DisplayList::new(Rgba::BLACK);
    dl.push_camera(canvas_draw::Follow::BOTH);
    dl.rect(RoundedRect::new(Rect::new(10.0, 10.0, 10.0, 10.0), 0.0, Rgba::hex(0xff0000)).pinned());
    dl.rect(RoundedRect::new(
        Rect::new(10.0, 30.0, 10.0, 10.0),
        0.0,
        Rgba::hex(0x00ff00),
    ));
    dl.pop_camera();
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(Viewport {
        width_px: 100,
        height_px: 60,
        scale: 1.0,
    });
    gpu.render_offscreen(&mut off, &dl, &mut text)
        .expect("render");
    gpu.set_camera(
        off.target_mut(),
        Camera {
            scale: p(2.0, 1.0),
            offset: p(0.0, 0.0),
        },
    );
    gpu.redraw_offscreen(&mut off).expect("redraw");
    let (w, _, img) = gpu.read_offscreen(&off).expect("read");
    assert_eq!(
        span(&img, w, 15, 0),
        Some((25, 34)),
        "centre 15 → 30, still 10 wide"
    );
    assert_eq!(
        span(&img, w, 35, 1),
        Some((20, 39)),
        "unpinned: 10..20 → 20..40"
    );
}
