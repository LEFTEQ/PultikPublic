//! The retained path uses the same pipelines, clip/scissor and 4x MSAA pass.
use canvas_draw::{
    Camera, DisplayList, Follow, Path, PathOp, Point, Rect, Rgba, RoundedRect, Stroke, TextRun,
};
use canvas_gpu::{Gpu, GpuError, Viewport};
use canvas_text::TextSystem;
use std::sync::Arc;

fn gpu() -> Option<Gpu> {
    match Gpu::new() {
        Ok(gpu) => {
            eprintln!("retained test adapter: {}", gpu.adapter_info());
            Some(gpu)
        }
        Err(GpuError::Adapter(e)) => {
            eprintln!("skipping: no GPU adapter ({e})");
            None
        }
        Err(e) => panic!("{e}"),
    }
}
fn rect(color: Rgba, x: f32) -> Arc<DisplayList> {
    let mut list = DisplayList::new(Rgba::BLACK);
    list.push_camera(Follow::BOTH);
    list.rect(RoundedRect::new(Rect::new(x, 8.0, 40.0, 40.0), 0.0, color));
    list.pop_camera();
    Arc::new(list)
}
fn pixel(gpu: &Gpu, off: &canvas_gpu::Offscreen, x: u32, y: u32) -> [u8; 4] {
    let (w, _, pixels) = gpu.read_offscreen(off).unwrap();
    pixels[((y * w + x) * 4) as usize..((y * w + x) * 4 + 4) as usize]
        .try_into()
        .unwrap()
}
fn viewport() -> Viewport {
    Viewport {
        width_px: 96,
        height_px: 64,
        scale: 1.0,
    }
}

#[test]
fn fused_quads_preserve_interleaved_painter_order_at_every_camera() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut list = DisplayList::new(Rgba::BLACK);
    for follow in [Follow::NONE, Follow::X, Follow::Y, Follow::BOTH] {
        list.push_camera(follow);
        list.push_clip(Rect::new(0.0, 0.0, 90.0, 60.0));
        for i in 0..8 {
            list.rect(RoundedRect::new(
                Rect::new(4.0 + i as f32 * 6.0, 4.0 + i as f32 * 3.0, 30.0, 18.0),
                4.0,
                Rgba::hex(0x224488).with_alpha(0.65),
            ));
            list.text(TextRun::new(
                "Ab 🦊",
                Point::new(8.0 + i as f32 * 6.0, 8.0 + i as f32 * 3.0),
                12.0,
                Rgba::WHITE,
            ));
        }
        list.pop_clip();
        list.pop_camera();
    }
    let mut legacy = gpu.offscreen(viewport());
    let mut retained = gpu.offscreen(viewport());
    gpu.render_offscreen(&mut legacy, &list, &mut text).unwrap();
    retained.target_mut().begin_chunks();
    gpu.upsert_chunk(retained.target_mut(), 1, Arc::new(list), &mut text)
        .unwrap();
    gpu.publish_chunks(retained.target_mut(), &[1], Rgba::BLACK, &mut text)
        .unwrap();
    for camera in [
        Camera::IDENTITY,
        Camera {
            offset: Point::new(-3.25, 2.75),
            scale: Point::new(1.25, 0.8),
        },
    ] {
        gpu.set_camera(legacy.target_mut(), camera);
        gpu.set_camera(retained.target_mut(), camera);
        gpu.redraw_offscreen(&mut legacy).unwrap();
        gpu.redraw_offscreen(&mut retained).unwrap();
        assert_eq!(
            gpu.read_offscreen(&legacy).unwrap().2,
            gpu.read_offscreen(&retained).unwrap().2
        );
    }
    text.atlas_mut().clear();
    gpu.refresh_chunks(retained.target_mut(), &mut text);
    gpu.redraw_offscreen(&mut retained).unwrap();
    assert_eq!(
        gpu.read_offscreen(&legacy).unwrap().2,
        gpu.read_offscreen(&retained).unwrap().2
    );
}

#[test]
fn publication_is_atomic_ordered_and_removable() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(viewport());
    let red = rect(Rgba::hex(0xff0000), 8.0);
    let green = rect(Rgba::hex(0x00ff00), 20.0);
    off.target_mut().begin_chunks();
    gpu.upsert_chunk(off.target_mut(), 1, red.clone(), &mut text)
        .unwrap();
    gpu.upsert_chunk(off.target_mut(), 2, green.clone(), &mut text)
        .unwrap();
    gpu.publish_chunks(off.target_mut(), &[1, 2], Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(pixel(&gpu, &off, 30, 20), [0, 255, 0, 255]);
    let stats = off.target().retained_stats();
    off.target_mut().begin_chunks();
    gpu.upsert_chunk(
        off.target_mut(),
        1,
        rect(Rgba::hex(0x0000ff), 8.0),
        &mut text,
    )
    .unwrap();
    off.target_mut().remove_chunk(2).unwrap();
    assert!(
        gpu.publish_chunks(off.target_mut(), &[1, 2], Rgba::BLACK, &mut text)
            .is_err()
    );
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(
        pixel(&gpu, &off, 30, 20),
        [0, 255, 0, 255],
        "staged edits and rejected publication are invisible"
    );
    gpu.publish_chunks(off.target_mut(), &[1], Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(pixel(&gpu, &off, 30, 20), [0, 0, 255, 255]);
    assert_eq!(off.target().retained_stats().uploads, stats.uploads + 1);
    off.target_mut().begin_chunks();
    gpu.upsert_chunk(off.target_mut(), 2, green, &mut text)
        .unwrap();
    gpu.publish_chunks(off.target_mut(), &[2, 1], Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(
        pixel(&gpu, &off, 30, 20),
        [0, 0, 255, 255],
        "explicit painter order, not key order"
    );
    off.target_mut().begin_chunks();
    assert!(
        gpu.publish_chunks(off.target_mut(), &[1, 1], Rgba::BLACK, &mut text)
            .is_err()
    );
    gpu.publish_chunks(off.target_mut(), &[], Rgba::WHITE, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(
        pixel(&gpu, &off, 30, 20),
        [255, 255, 255, 255],
        "empty publication clears"
    );
}

#[test]
fn camera_overlay_clips_paths_and_single_list_parity() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(viewport());
    let mut path = DisplayList::new(Rgba::BLACK);
    path.push_camera(Follow::BOTH);
    path.push_clip(Rect::new(0.0, 0.0, 48.0, 64.0));
    let mut line = Path::new();
    line.move_to(Point::new(8.0, 30.0))
        .line_to(Point::new(80.0, 30.0));
    path.path(PathOp::stroke(
        Arc::new(line),
        Stroke::new(5.0, Rgba::WHITE).round(),
    ));
    path.pop_clip();
    path.pop_camera();
    let mut overlay = DisplayList::new(Rgba::BLACK);
    overlay.rect(RoundedRect::new(
        Rect::new(24.0, 24.0, 8.0, 12.0),
        0.0,
        Rgba::hex(0xff0000),
    ));
    let mut single = path.clone();
    single.ops.extend(overlay.ops.clone());
    off.target_mut().begin_chunks();
    let path = Arc::new(path);
    gpu.upsert_chunk(off.target_mut(), 9, path.clone(), &mut text)
        .unwrap();
    gpu.set_chunk_overlay(off.target_mut(), Some(Arc::new(overlay)), &mut text)
        .unwrap();
    gpu.publish_chunks(off.target_mut(), &[9], Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    let retained = gpu.read_offscreen(&off).unwrap().2;
    let expected = gpu
        .render_to_rgba(&single, &mut text, 96.0, 64.0, 1.0)
        .unwrap()
        .2;
    assert_eq!(
        retained, expected,
        "one MSAA resolve for all lists, overlay and clips"
    );
    assert_eq!(pixel(&gpu, &off, 60, 30), [0, 0, 0, 255]);
    let stats = off.target().retained_stats();
    gpu.set_camera(
        off.target_mut(),
        Camera {
            offset: Point::new(4.0, 0.0),
            ..Camera::IDENTITY
        },
    );
    gpu.refresh_chunks(off.target_mut(), &mut text);
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(
        stats,
        off.target().retained_stats(),
        "camera has zero uploads/builds/tessellations"
    );
    assert_eq!(
        pixel(&gpu, &off, 28, 30),
        [255, 0, 0, 255],
        "overlay stays in view coordinates"
    );
    off.target_mut().begin_chunks();
    gpu.upsert_chunk(off.target_mut(), 9, path, &mut text)
        .unwrap();
    gpu.publish_chunks(off.target_mut(), &[9], Rgba::BLACK, &mut text)
        .unwrap();
    assert_eq!(
        stats,
        off.target().retained_stats(),
        "identical Arc upsert reuses buffers"
    );
    gpu.render_offscreen(&mut off, &single, &mut text).unwrap();
    gpu.set_camera(off.target_mut(), Camera::IDENTITY);
    gpu.redraw_offscreen(&mut off).unwrap();
    assert_eq!(
        gpu.read_offscreen(&off).unwrap().2,
        expected,
        "legacy render exits retained mode"
    );
}

#[test]
fn atlas_reset_refreshes_only_atlas_dependent_chunks() {
    let Some(gpu) = gpu() else { return };
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(viewport());
    let mut label = DisplayList::new(Rgba::BLACK);
    label.text(TextRun::new(
        "Retained",
        Point::new(8.0, 12.0),
        14.0,
        Rgba::WHITE,
    ));
    off.target_mut().begin_chunks();
    gpu.upsert_chunk(
        off.target_mut(),
        1,
        rect(Rgba::hex(0x002244), 0.0),
        &mut text,
    )
    .unwrap();
    gpu.upsert_chunk(off.target_mut(), 2, Arc::new(label), &mut text)
        .unwrap();
    gpu.publish_chunks(off.target_mut(), &[1, 2], Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    let pixels = gpu.read_offscreen(&off).unwrap().2;
    let before = off.target().retained_stats();
    text.atlas_mut().clear();
    gpu.refresh_chunks(off.target_mut(), &mut text);
    gpu.redraw_offscreen(&mut off).unwrap();
    let after = off.target().retained_stats();
    assert_eq!(after.uploads - before.uploads, 1);
    assert_eq!(after.atlas_refreshes - before.atlas_refreshes, 1);
    assert_eq!(after.tessellations, before.tessellations);
    assert_eq!(pixels, gpu.read_offscreen(&off).unwrap().2);
}

#[test]
#[ignore = "D12 CPU gate: run with --profile perf -- --ignored --nocapture"]
fn retained_cpu_frame_cost() {
    let gpu = Gpu::new().expect("CPU submission gate needs an actual GPU");
    let mut text = TextSystem::new();
    let mut off = gpu.offscreen(Viewport {
        width_px: 320,
        height_px: 180,
        scale: 1.0,
    });
    let mut lists = Vec::new();
    for chunk in 0..64 {
        let mut dl = DisplayList::new(Rgba::BLACK);
        dl.push_camera(Follow::BOTH);
        for i in (chunk..15_000).step_by(64) {
            let x = (i % 100) as f32 * 12.0;
            let y = (i / 100) as f32 * 12.0;
            let mut p = Path::new();
            p.move_to(Point::new(x, y))
                .line_to(Point::new(x + 8.0, y + 8.0));
            dl.path(PathOp::stroke(Arc::new(p), Stroke::new(1.0, Rgba::WHITE)));
        }
        for i in (chunk..5_000).step_by(64) {
            let x = (i % 100) as f32 * 12.0;
            let y = (i / 100) as f32 * 12.0;
            dl.rect(RoundedRect::new(
                Rect::new(x, y, 10.0, 8.0),
                2.0,
                Rgba::hex(0x4488cc),
            ));
            dl.text(TextRun::new(
                format!("Node {i}"),
                Point::new(x, y),
                8.0,
                Rgba::WHITE,
            ));
        }
        dl.pop_camera();
        lists.push(Arc::new(dl));
    }
    let mut single = DisplayList::new(Rgba::BLACK);
    for list in &lists {
        single.ops.extend(list.ops.iter().cloned());
    }
    gpu.render_offscreen(&mut off, &single, &mut text).unwrap();
    let batch_count = off.target().frame().batches.len();
    let mut baseline = Vec::new();
    for iteration in 0..1320 {
        let start = std::time::Instant::now();
        gpu.set_camera(
            off.target_mut(),
            Camera {
                offset: Point::new((iteration % 10) as f32, 0.0),
                ..Camera::IDENTITY
            },
        );
        gpu.submit_offscreen(&mut off).unwrap();
        if iteration >= 120 {
            baseline.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        gpu.read_offscreen(&off).unwrap();
    }
    baseline.sort_by(f64::total_cmp);
    eprintln!(
        "single-list baseline: {batch_count} batches, CPU p99 {:.3} ms",
        baseline[baseline.len() * 99 / 100]
    );
    let order: Vec<_> = (0..64).collect();
    off.target_mut().begin_chunks();
    for (id, list) in lists.iter().enumerate() {
        gpu.upsert_chunk(off.target_mut(), id as u64, list.clone(), &mut text)
            .unwrap();
    }
    gpu.publish_chunks(off.target_mut(), &order, Rgba::BLACK, &mut text)
        .unwrap();
    gpu.redraw_offscreen(&mut off).unwrap();
    let base = off.target().retained_stats();
    let mut camera = Vec::new();
    let mut changed = Vec::new();
    let mut change_stages = [Vec::new(), Vec::new(), Vec::new()];
    let mut stages = [Vec::new(), Vec::new(), Vec::new(), Vec::new()];
    for iteration in 0..1320 {
        let start = std::time::Instant::now();
        gpu.set_camera(
            off.target_mut(),
            Camera {
                offset: Point::new((iteration % 10) as f32, 0.0),
                ..Camera::IDENTITY
            },
        );
        gpu.refresh_chunks(off.target_mut(), &mut text);
        gpu.submit_offscreen(&mut off).unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        if iteration >= 120 {
            camera.push(elapsed);
            let p = off.target().cpu_profile();
            for (samples, value) in
                stages
                    .iter_mut()
                    .zip([p.uniforms_ms, p.commands_ms, p.finish_ms, p.submit_ms])
            {
                samples.push(value);
            }
        }
        // Fence outside the measured CPU region, so driver backlog is not the gate.
        gpu.read_offscreen(&off).unwrap();
    }
    assert_eq!(base, off.target().retained_stats());
    for iteration in 0..1320 {
        let id = iteration % 64;
        let start = std::time::Instant::now();
        off.target_mut().begin_chunks();
        // A real fill change, with warm path geometry; cloning is timed too.
        let mut revision = (*lists[id]).clone();
        let rect = revision
            .ops
            .iter_mut()
            .find_map(|op| {
                if let canvas_draw::Op::Rect(r) = op {
                    Some(r)
                } else {
                    None
                }
            })
            .unwrap();
        rect.fill = Rgba::hex(if (iteration / 64) % 2 == 0 {
            0x4488cc
        } else {
            0x6699dd
        });
        gpu.upsert_chunk(off.target_mut(), id as u64, Arc::new(revision), &mut text)
            .unwrap();
        gpu.publish_chunks(off.target_mut(), &order, Rgba::BLACK, &mut text)
            .unwrap();
        gpu.submit_offscreen(&mut off).unwrap();
        let elapsed = start.elapsed().as_secs_f64() * 1000.0;
        if iteration >= 120 {
            changed.push(elapsed);
            let p = off.target().cpu_profile();
            for (samples, value) in
                change_stages
                    .iter_mut()
                    .zip([p.rebuild_ms, p.upload_ms, p.bundle_ms])
            {
                samples.push(value);
            }
        }
        gpu.read_offscreen(&off).unwrap();
    }
    let after = off.target().retained_stats();
    assert_eq!(after.uploads - base.uploads, 1320);
    assert_eq!(after.tessellations, base.tessellations);
    for (name, mut values) in ["uniforms", "commands", "finish", "submit"]
        .into_iter()
        .zip(stages)
    {
        values.sort_by(f64::total_cmp);
        eprintln!("stage {name} p99 {:.3} ms", values[values.len() * 99 / 100]);
    }
    for (name, mut values) in ["rebuild", "upload", "bundle"]
        .into_iter()
        .zip(change_stages)
    {
        values.sort_by(f64::total_cmp);
        eprintln!(
            "change {name} p99 {:.3} ms",
            values[values.len() * 99 / 100]
        );
    }
    for (name, mut values) in [("camera", camera), ("single-chunk", changed)] {
        values.sort_by(f64::total_cmp);
        let p99 = values[(values.len() * 99 / 100).min(values.len() - 1)];
        eprintln!(
            "{name}: 64 chunks / 5000 labels / 15000 edges CPU p99 {p99:.3} ms; {}",
            gpu.adapter_info()
        );
        assert!(p99 <= 2.0, "{name} CPU p99 {p99:.3} ms > 2 ms");
    }
}
