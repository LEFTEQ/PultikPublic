//! The shared device (D2, docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md): one [`Gpu`] (device, pipelines, atlas textures) and one
//! [`TextSystem`] (the atlas's CPU side and the shaping caches) for every surface Pultík draws
//! on its main thread: the timelines, the estate map and the diff alike. The device is built on
//! the first attach and dropped by [`canvas_surface_release`] (the panel's 30 s tree release)
//! once no surface is attached, never by a detach, so moving between canvases builds nothing.
//!
//! One text system means one atlas: a frame that fills it clears it, and every other surface's
//! last frame then points at glyphs the atlas no longer holds. An engine records the atlas's
//! generation at its last build and rebuilds, rather than redrawing, once it moved.

use crate::Failure;
use canvas_gpu::{Gpu, Target};
use canvas_text::TextSystem;
use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::mem::ManuallyDrop;

struct Shared {
    gpu: Gpu,
    text: TextSystem,
    /// Surfaces attached now.
    attached: usize,
    /// A release asked while surfaces were attached: the last detach drops the device.
    release: bool,
}

thread_local! {
    /// The thread's device. Its own end (the thread's, the process quitting) never drops it: a
    /// thread's thread-locals go last-registered first and the first attach registers this one
    /// before anything draws, so wgpu's own (its lock tracing, in debug builds) are gone by then,
    /// and the device's drop reaching them aborted every quit. A release still drops it (`None`).
    static SHARED: RefCell<ManuallyDrop<Option<Shared>>> =
        const { RefCell::new(ManuallyDrop::new(None)) };
    static BUILDS: Cell<u32> = const { Cell::new(0) };
}

/// One layer's target on the shared device. Dropping it detaches it.
pub(crate) struct Surface {
    target: Option<Target>,
}

impl Surface {
    /// A target on `layer` (building the device first when there is none), presenting as soon
    /// as a frame is done: the host's display link paces frames. In step with the display, the
    /// panel's surface is composited at 60 Hz on a 120 Hz screen and every frame waits ~11 ms
    /// for a drawable (AC 8, Metal System Trace 2026-10-16); presented when done, ~0.4 ms.
    ///
    /// # Safety
    /// `layer` is a valid CAMetalLayer that outlives the surface.
    pub(crate) unsafe fn attach(
        layer: *mut c_void,
        width: f64,
        height: f64,
        scale: f64,
    ) -> Result<Self, Failure> {
        if layer.is_null() {
            return Err(Failure::Invalid("a null layer"));
        }
        #[cfg(not(target_vendor = "apple"))]
        {
            let _ = (width, height, scale);
            Err(Failure::Engine("layers are Apple-only".into()))
        }
        #[cfg(target_vendor = "apple")]
        SHARED.with_borrow_mut(|shared| {
            if shared.is_none() {
                let gpu = Gpu::new().map_err(|e| Failure::Engine(e.to_string()))?;
                BUILDS.set(BUILDS.get() + 1);
                **shared = Some(Shared {
                    gpu,
                    text: TextSystem::new(),
                    attached: 0,
                    release: false,
                });
            }
            let s = shared.as_mut().expect("built above");
            // SAFETY: the caller's contract: a valid CAMetalLayer that outlives the target.
            let mut target = unsafe {
                s.gpu.create_layer_target(
                    layer,
                    canvas_gpu::Compositing::Opaque,
                    width,
                    height,
                    scale,
                )
            }
            .map_err(|e| Failure::Engine(e.to_string()))?;
            s.gpu.set_vsync(&mut target, false);
            s.attached += 1;
            s.release = false;
            Ok(Surface {
                target: Some(target),
            })
        })
    }

    pub(crate) fn resize(&mut self, width: f64, height: f64, scale: f64) {
        self.with(|gpu, target, _| gpu.resize(target, width, height, scale));
    }

    pub(crate) fn set_vsync(&mut self, vsync: bool) {
        self.with(|gpu, target, _| gpu.set_vsync(target, vsync));
    }

    /// Run `f` on the device, this surface's target and the shared text system.
    pub(crate) fn with<R>(&mut self, f: impl FnOnce(&Gpu, &mut Target, &mut TextSystem) -> R) -> R {
        let target = self
            .target
            .as_mut()
            .expect("a surface holds its target until dropped");
        SHARED.with_borrow_mut(|shared| {
            let s = shared
                .as_mut()
                .expect("the device outlives every attached surface");
            f(&s.gpu, target, &mut s.text)
        })
    }

    pub(crate) fn animating(&self) -> bool {
        self.target.as_ref().is_some_and(Target::animating)
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        // The target goes before the device it was made on.
        drop(self.target.take());
        SHARED.with_borrow_mut(|shared| {
            if let Some(s) = shared.as_mut() {
                s.attached = s.attached.saturating_sub(1);
                if s.attached == 0 && s.release {
                    **shared = None;
                }
            }
        });
    }
}

/// Drop the shared device and text system (the panel's 30 s tree release): now when no surface
/// is attached, else with the last detach. The next attach builds them again.
#[unsafe(no_mangle)]
pub extern "C" fn canvas_surface_release() {
    SHARED.with_borrow_mut(|shared| match shared.as_mut() {
        Some(s) if s.attached > 0 => s.release = true,
        _ => **shared = None,
    });
}

/// How many times this thread built the shared device: one per process until a release (the
/// panel driver's check that switching canvases builds none).
#[unsafe(no_mangle)]
pub extern "C" fn canvas_surface_builds() -> u32 {
    BUILDS.get()
}

/// The shared device exists now.
#[unsafe(no_mangle)]
pub extern "C" fn canvas_surface_live() -> bool {
    SHARED.with_borrow(|shared| shared.is_some())
}

#[cfg(all(test, target_vendor = "apple"))]
mod tests {
    use super::*;
    use canvas_draw::{DisplayList, Op, Path, PathOp, Point, Rgba, TextRun};
    use std::sync::Arc;

    /// A thread that ends with its device alive and drawn with (the process quitting) ends
    /// cleanly: its thread-locals' destructors never drop the device.
    #[test]
    fn a_thread_ends_with_its_drawn_device_alive() {
        let ended = std::thread::spawn(|| {
            // The slot first, as an attach touches it before anything draws.
            SHARED.with_borrow(|_| ());
            let gpu = Gpu::new().expect("a Metal device");
            let mut text = TextSystem::new();
            let mut off = gpu.offscreen(canvas_gpu::Viewport {
                width_px: 200,
                height_px: 100,
                scale: 2.0,
            });
            let mut dl = DisplayList::new(Rgba::new(0.0, 0.0, 0.0, 1.0));
            let white = Rgba::new(1.0, 1.0, 1.0, 1.0);
            dl.ops.push(Op::Text(TextRun::new(
                "fn main() {}",
                Point::new(4.0, 4.0),
                12.0,
                white,
            )));
            let mut path = Path::new();
            path.move_to(Point::new(0.0, 0.0))
                .line_to(Point::new(50.0, 40.0))
                .line_to(Point::new(0.0, 40.0))
                .close();
            dl.ops.push(Op::Path(PathOp::fill(Arc::new(path), white)));
            gpu.render_offscreen(&mut off, &dl, &mut text)
                .expect("a frame");
            drop(off);
            SHARED.with_borrow_mut(|shared| {
                **shared = Some(Shared {
                    gpu,
                    text,
                    attached: 0,
                    release: false,
                })
            });
        })
        .join();
        assert!(ended.is_ok());
    }
}
