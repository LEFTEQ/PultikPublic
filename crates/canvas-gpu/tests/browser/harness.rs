//! Browser qualification fixture. Build as a cdylib example, then run wasm-bindgen
//! with --target web. No renderer or text implementation lives in the harness.

#[cfg(target_arch = "wasm32")]
mod browser {
    use canvas_draw::{
        Camera, DisplayList, Follow, Path, PathOp, Point, Rect, Rgba, RoundedRect, Stroke, TextRun,
    };
    use canvas_gpu::{Gpu, Viewport};
    use canvas_text::TextSystem;
    use std::sync::Arc;
    use wasm_bindgen::prelude::*;

    fn scene() -> DisplayList {
        let mut dl = DisplayList::new(Rgba::hex(0x101820));
        dl.push_camera(Follow::BOTH);
        dl.rect(RoundedRect::new(
            Rect::new(8.0, 8.0, 112.0, 48.0),
            6.0,
            Rgba::hex(0x206090),
        ));
        let mut edge = Path::new();
        edge.move_to(Point::new(20.0, 68.0))
            .line_to(Point::new(140.0, 68.0));
        dl.path(PathOp::stroke(
            Arc::new(edge),
            Stroke::new(4.0, Rgba::hex(0xf0b040)),
        ));
        dl.text(TextRun::new(
            "Memory graph",
            Point::new(16.0, 22.0),
            14.0,
            Rgba::WHITE,
        ));
        dl.pop_camera();
        dl
    }

    #[wasm_bindgen]
    pub async fn qualify(canvas: web_sys::HtmlCanvasElement) -> Result<JsValue, JsValue> {
        let err = |e: canvas_gpu::GpuError| JsValue::from_str(&e.to_string());
        let (gpu, mut target) = Gpu::for_canvas(canvas, 1.0).await.map_err(err)?;
        target.freeze_clock(Some(0.0));
        let dl = scene();
        let mut text = TextSystem::new();
        gpu.render(&mut target, &dl, &mut text).map_err(err)?;
        let mut off = gpu.offscreen(Viewport {
            width_px: 160,
            height_px: 88,
            scale: 1.0,
        });
        off.target_mut().freeze_clock(Some(0.0));
        gpu.render_offscreen(&mut off, &dl, &mut text)
            .map_err(err)?;
        let (_, _, pixels) = gpu.read_offscreen_async(&off).await.map_err(err)?;
        off.target_mut().begin_chunks();
        gpu.upsert_chunk(off.target_mut(), 1, Arc::new(dl), &mut text)
            .map_err(err)?;
        gpu.publish_chunks(off.target_mut(), &[1], Rgba::hex(0x101820), &mut text)
            .map_err(err)?;
        gpu.redraw_offscreen(&mut off).map_err(err)?;
        let (_, _, retained) = gpu.read_offscreen_async(&off).await.map_err(err)?;
        assert_eq!(
            pixels, retained,
            "retained quad/path pixels equal legacy browser pixels"
        );
        // Representative retained graph workload, separate from the small pixel fixture.
        let mut graph = DisplayList::new(Rgba::BLACK);
        graph.push_camera(Follow::BOTH);
        // Graph painter order: edges behind node fills behind labels. The renderer
        // batches adjacent pipelines; interleaving each edge/node/label defeats that.
        for layer in 0..3 {
            for i in 0..1000 {
                let x = (i % 40) as f32 * 120.0;
                let y = (i / 40) as f32 * 60.0;
                match layer {
                    0 => {
                        let mut path = Path::new();
                        path.move_to(Point::new(x, y))
                            .line_to(Point::new(x + 120.0, y + 60.0));
                        graph.path(PathOp::stroke(
                            Arc::new(path),
                            Stroke::new(1.0, Rgba::WHITE),
                        ));
                    }
                    1 => graph.rect(RoundedRect::new(
                        Rect::new(x, y, 100.0, 40.0),
                        4.0,
                        Rgba::hex(0x206090),
                    )),
                    _ => graph.text(TextRun::new(
                        "Memory",
                        Point::new(x + 5.0, y + 8.0),
                        12.0,
                        Rgba::WHITE,
                    )),
                }
            }
        }
        graph.pop_camera();
        gpu.render(&mut target, &graph, &mut text).map_err(err)?;
        let stats = target.stats();
        let tessellations = target.frame().tessellations();
        let geometry = target.frame().path_vertices.len();
        let now = web_sys::window().unwrap().performance().unwrap();
        let mut samples = Vec::with_capacity(1200);
        // Camera-only CPU submission: no GPU fence or pixel transfer in the timed region.
        for i in 0..1320 {
            let start = now.now();
            gpu.set_camera(
                &mut target,
                Camera {
                    scale: Point::new(1.0, 1.0),
                    offset: Point::new((i % 16) as f32, 0.0),
                },
            );
            gpu.redraw(&mut target).map_err(err)?;
            if i >= 120 {
                samples.push(now.now() - start);
            }
            // Release submitted WebGL command buffers and allow browser work between
            // frames, outside the CPU interval. A tight loop is not a frame scheduler.
            let task = js_sys::Promise::new(&mut |resolve, _| {
                web_sys::window()
                    .unwrap()
                    .set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, 0)
                    .unwrap();
            });
            wasm_bindgen_futures::JsFuture::from(task).await?;
        }
        assert_eq!(target.stats().uploads, stats.uploads);
        assert_eq!(target.frame().tessellations(), tessellations);
        assert_eq!(target.frame().path_vertices.len(), geometry);
        samples.sort_by(f64::total_cmp);
        let report = js_sys::Object::new();
        js_sys::Reflect::set(&report, &"adapter".into(), &gpu.adapter_info().into())?;
        js_sys::Reflect::set(
            &report,
            &"pixels".into(),
            &js_sys::Uint8Array::from(pixels.as_slice()),
        )?;
        js_sys::Reflect::set(&report, &"p99Ms".into(), &samples[1187].into())?;
        js_sys::Reflect::set(
            &report,
            &"uploads".into(),
            &(target.stats().uploads as f64).into(),
        )?;
        js_sys::Reflect::set(
            &report,
            &"encodes".into(),
            &(target.stats().encodes as f64).into(),
        )?;
        Ok(report.into())
    }
}
