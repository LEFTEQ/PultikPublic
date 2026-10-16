//! Offscreen render of non-text and text primitives, probed at known pixels: proves the
//! three pipelines compile and draw where the display list says. Skips when the machine has
//! no adapter (the Linux lane runs it on lavapipe).

use canvas_draw::cells::{Cell, Cursor, CursorShape, Rgb, Screen};
use canvas_draw::{CellGrid, DisplayList, Point, Rect, Rgba, RoundedRect, Size, TextRun};
use canvas_gpu::{Gpu, GpuError};
use canvas_text::TextSystem;
use std::sync::Arc;

fn pixel(img: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * w + x) * 4) as usize;
    [img[i], img[i + 1], img[i + 2], img[i + 3]]
}

#[test]
fn primitives_land_on_their_pixels() {
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(GpuError::Adapter(e)) => {
            eprintln!("skipping: no GPU adapter ({e})");
            return;
        }
        Err(e) => panic!("{e}"),
    };
    let mut dl = DisplayList::new(Rgba::hex(0x000000));
    dl.rect(RoundedRect::new(
        Rect::new(10.0, 10.0, 40.0, 30.0),
        6.0,
        Rgba::hex(0xff0000),
    ));
    dl.rect(
        RoundedRect::new(Rect::new(60.0, 10.0, 30.0, 30.0), 0.0, Rgba::TRANSPARENT)
            .border(4.0, Rgba::hex(0x00ff00)),
    );
    let blank = |bg: Rgb| Cell {
        text: String::new(),
        fg: Rgb(255, 255, 255),
        bg,
        flags: 0,
    };
    dl.cells(CellGrid::new(
        Point::new(10.0, 50.0),
        Size::new(10.0, 20.0),
        14.0,
        Arc::new(Screen {
            default_fg: Rgb(255, 255, 255),
            default_bg: Rgb(0, 0, 0),
            cursor: Cursor {
                col: 0,
                row: 0,
                shape: CursorShape::Block,
                visible: false,
                blinking: false,
            },
            cursor_color: None,
            rows: vec![vec![blank(Rgb(0, 0, 255)), blank(Rgb(0, 0, 0))]],
        }),
    ));
    dl.text(TextRun::new(
        "MMMM",
        Point::new(40.0, 50.0),
        24.0,
        Rgba::WHITE,
    ));

    let mut text = TextSystem::new();
    let (w, h, img) = gpu
        .render_to_rgba(&dl, &mut text, 120.0, 80.0, 2.0)
        .expect("offscreen render");
    assert_eq!((w, h), (240, 160));
    assert_eq!(pixel(&img, w, 60, 50), [255, 0, 0, 255], "rect fill");
    assert_eq!(
        pixel(&img, w, 21, 21),
        [0, 0, 0, 255],
        "outside the rounded corner"
    );
    assert_eq!(pixel(&img, w, 122, 40), [0, 255, 0, 255], "border");
    assert_eq!(pixel(&img, w, 150, 50), [0, 0, 0, 255], "border is hollow");
    assert_eq!(pixel(&img, w, 30, 120), [0, 0, 255, 255], "cell background");
    assert_eq!(
        pixel(&img, w, 50, 120),
        [0, 0, 0, 255],
        "default cells are not painted"
    );
    #[cfg(target_os = "macos")]
    {
        let lit = (80..200)
            .flat_map(|x| (100..150).map(move |y| (x, y)))
            .filter(|&(x, y)| pixel(&img, w, x, y)[0] > 200)
            .count();
        assert!(lit > 200, "text drew {lit} bright pixels");
    }
}

/// The Claude Code logo is drawn from our block sprites: every solid block must meet its
/// neighbours, across columns and rows, with no background pixel between them.
#[test]
fn the_claude_logo_has_no_seams() {
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(GpuError::Adapter(e)) => {
            eprintln!("skipping: no GPU adapter ({e})");
            return;
        }
        Err(e) => panic!("{e}"),
    };
    let (fg, bg) = (Rgb(0xd7, 0x77, 0x57), Rgb(0x1d, 0x20, 0x22));
    let rows = [" ▐▛███▜▌ ", "▝▜█████▛▘", "  ▘▘ ▝▝  "];
    let lines = rows
        .iter()
        .map(|r| {
            r.chars()
                .map(|c| Cell {
                    text: if c == ' ' { String::new() } else { c.into() },
                    fg,
                    bg,
                    flags: 0,
                })
                .collect()
        })
        .collect();
    let frame = Screen {
        default_fg: fg,
        default_bg: bg,
        cursor: Cursor {
            col: 0,
            row: 0,
            shape: CursorShape::Block,
            visible: false,
            blinking: false,
        },
        cursor_color: None,
        rows: lines,
    };
    let mut text = TextSystem::new();
    text.set_term_font(Some("Monaco"), 13.0);
    let scale = 2.0;
    let (cw, ch) = text.term_metrics().cell_px(13.0 * scale);
    let mut dl = DisplayList::new(Rgba::rgb8(bg.0, bg.1, bg.2));
    let origin = Point::new(4.0, 4.0);
    dl.cells(CellGrid::new(
        origin,
        Size::new(cw as f32 / scale, ch as f32 / scale),
        13.0,
        Arc::new(frame),
    ));
    let (w, _, img) = gpu
        .render_to_rgba(&dl, &mut text, 100.0, 70.0, scale as f64)
        .expect("offscreen render");
    let (ox, oy) = (8, 8);
    let ink = [fg.0, fg.1, fg.2, 255];
    let solid = |x0: u32, y0: u32, x1: u32, y1: u32, what: &str| {
        for y in y0..y1 {
            for x in x0..x1 {
                assert_eq!(pixel(&img, w, x, y), ink, "{what}: a gap at ({x}, {y})");
            }
        }
    };
    let col = |c: u32| ox + c * cw;
    let row = |r: u32| oy + r * ch;
    let half = (ch * 4 + 4) / 8; // the sprites' upper-half split
    solid(
        col(3),
        row(0),
        col(6),
        row(2),
        "███ over █████, across the row seam",
    );
    solid(
        col(2),
        row(1),
        col(7),
        row(2),
        "▜█████▛ joined across columns",
    );
    solid(
        col(1) + cw / 2,
        row(0),
        col(8) - cw / 2,
        row(0) + half,
        "▐▛███▜▌ top half",
    );
    assert_eq!(
        pixel(&img, w, col(0) + 1, row(0) + 1),
        [bg.0, bg.1, bg.2, 255],
        "the background stays where no block is"
    );
}
