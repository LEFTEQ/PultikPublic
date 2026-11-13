//! Layer frames with glass, drawn offscreen and read back: the slab blurs what is under it and
//! leaves the rest alone, a solid slab is its colour, a still frame costs no blur, the cap
//! holds while a stack moves, and a layer that leaves frees its blur. Skips when the machine
//! has no adapter (the Linux lane runs it on lavapipe).

use canvas_draw::layers::{Glass, Layer, LayerFrame, LayerId, Material, Wallpaper};
use canvas_draw::{DisplayList, Rect, Rgba, RoundedRect};
use canvas_gpu::{Gpu, GpuError, Offscreen, Viewport};
use canvas_text::TextSystem;

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

/// 200 x 100 points: red on the left half, blue on the right.
fn wallpaper() -> Wallpaper {
    let mut content = DisplayList::new(Rgba::BLACK);
    content.rect(RoundedRect::new(
        Rect::new(0.0, 0.0, 100.0, 100.0),
        0.0,
        Rgba::rgb8(255, 0, 0),
    ));
    content.rect(RoundedRect::new(
        Rect::new(100.0, 0.0, 100.0, 100.0),
        0.0,
        Rgba::rgb8(0, 0, 255),
    ));
    Wallpaper { content, rev: 1 }
}

fn layer(id: u64, rect: Rect, material: Material) -> Layer {
    Layer {
        id: LayerId(id),
        rect,
        radius: 12.0,
        material,
        opacity: 1.0,
        under: DisplayList::new(Rgba::TRANSPARENT),
        content: DisplayList::new(Rgba::TRANSPARENT),
        rev: 1,
    }
}

fn glass() -> Material {
    Material::Glass(Glass {
        sigma: 12.0,
        saturate: 1.0,
        tint_top: Rgba::TRANSPARENT,
        tint_bottom: Rgba::TRANSPARENT,
    })
}

fn offscreen(gpu: &Gpu) -> Offscreen {
    gpu.offscreen(Viewport {
        width_px: 200,
        height_px: 100,
        scale: 1.0,
    })
}

#[test]
fn glass_blurs_what_is_under_it_and_nothing_else() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = offscreen(&gpu);
    let frame = LayerFrame {
        wallpaper: wallpaper(),
        layers: vec![layer(1, Rect::new(40.0, 10.0, 120.0, 80.0), glass())],
        blur_cap: 4,
    };
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    let stats = off.target().stats();
    assert_eq!(
        (stats.wallpaper_blurs, stats.blur_passes),
        (1, 0),
        "over nothing, the slab samples the wallpaper's one blur"
    );
    let (w, _, img) = gpu.read_offscreen(&off).expect("read back");
    assert_eq!(
        pixel(&img, w, 10, 50),
        [255, 0, 0, 255],
        "outside: untouched"
    );
    assert_eq!(
        pixel(&img, w, 190, 50),
        [0, 0, 255, 255],
        "outside: untouched"
    );
    let [r, g, b, a] = pixel(&img, w, 100, 50);
    assert!(
        (90..=170).contains(&r) && (90..=170).contains(&b) && g < 20 && a == 255,
        "the seam under the slab blends both halves: {:?}",
        [r, g, b, a]
    );
    let [r, _, b, _] = pixel(&img, w, 96, 50);
    assert!(
        b > 30 && r > b,
        "just left of the seam, blue bleeds in: {r}, {b}"
    );
}

#[test]
fn a_solid_slab_is_its_colour() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = offscreen(&gpu);
    let frame = LayerFrame {
        wallpaper: wallpaper(),
        layers: vec![layer(
            1,
            Rect::new(40.0, 10.0, 120.0, 80.0),
            Material::Solid(Rgba::rgb8(0x1a, 0x21, 0x40)),
        )],
        blur_cap: 4,
    };
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    let stats = off.target().stats();
    assert_eq!((stats.wallpaper_blurs, stats.blur_passes), (0, 0));
    let (w, _, img) = gpu.read_offscreen(&off).expect("read back");
    for (x, y) in [(60, 50), (100, 50), (140, 50)] {
        let got = pixel(&img, w, x, y);
        let want = [0x1a, 0x21, 0x40, 0xff];
        assert!(
            got.iter().zip(want).all(|(g, w)| g.abs_diff(w) <= 1),
            "({x}, {y}): {got:?}"
        );
    }
    assert_eq!(pixel(&img, w, 10, 50), [255, 0, 0, 255]);
}

#[test]
fn a_still_frame_does_no_blur() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = offscreen(&gpu);
    let frame = LayerFrame {
        wallpaper: wallpaper(),
        layers: vec![
            layer(1, Rect::new(20.0, 20.0, 100.0, 60.0), glass()),
            layer(2, Rect::new(80.0, 30.0, 100.0, 50.0), glass()),
        ],
        blur_cap: 4,
    };
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    let first = off.target().stats();
    assert_eq!((first.wallpaper_blurs, first.blur_passes), (1, 1));
    assert_eq!(first.cached_blurs, 1, "the upper slab keeps its own blur");
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    let second = off.target().stats();
    assert_eq!((second.wallpaper_blurs, second.blur_passes), (0, 0));
}

#[test]
fn a_moving_stack_stays_within_the_cap_and_settles() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = offscreen(&gpu);
    let stack = |dx: f32| LayerFrame {
        wallpaper: wallpaper(),
        layers: (0..6)
            .map(|i| {
                let at = 10.0 + 12.0 * i as f32 + dx;
                layer(i, Rect::new(at, 10.0 + 4.0 * i as f32, 90.0, 60.0), glass())
            })
            .collect(),
        blur_cap: 2,
    };
    for dx in 0..4 {
        gpu.render_layers_offscreen(&mut off, &stack(dx as f32), &mut text)
            .expect("render");
        let passes = off.target().stats().blur_passes;
        assert_eq!(
            passes, 2,
            "every stacked layer moved: the cap holds at {passes}"
        );
    }
    let still = stack(3.0);
    let settled = (0..8).any(|_| {
        gpu.render_layers_offscreen(&mut off, &still, &mut text)
            .expect("render");
        let passes = off.target().stats().blur_passes;
        assert!(passes <= 2, "{passes} passes over a cap of 2");
        passes == 0
    });
    assert!(
        settled,
        "the deferred blurs catch up once the stack is still"
    );
}

#[test]
fn a_layer_that_leaves_frees_its_blur() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = offscreen(&gpu);
    let bottom = layer(1, Rect::new(20.0, 20.0, 100.0, 60.0), glass());
    let top = layer(2, Rect::new(80.0, 30.0, 100.0, 50.0), glass());
    let mut frame = LayerFrame {
        wallpaper: wallpaper(),
        layers: vec![bottom, top],
        blur_cap: 4,
    };
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    assert_eq!(off.target().stats().cached_blurs, 1);
    frame.layers.pop();
    gpu.render_layers_offscreen(&mut off, &frame, &mut text)
        .expect("render");
    assert_eq!(off.target().stats().cached_blurs, 0);
}
