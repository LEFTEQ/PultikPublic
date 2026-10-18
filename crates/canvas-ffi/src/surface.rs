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

struct Shared {
    gpu: Gpu,
    text: TextSystem,
    /// Surfaces attached now.
    attached: usize,
    /// A release asked while surfaces were attached: the last detach drops the device.
    release: bool,
}

thread_local! {
    static SHARED: RefCell<Option<Shared>> = const { RefCell::new(None) };
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
                *shared = Some(Shared {
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
            if let Some(s) = shared {
                s.attached = s.attached.saturating_sub(1);
                if s.attached == 0 && s.release {
                    *shared = None;
                }
            }
        });
    }
}

/// Drop the shared device and text system (the panel's 30 s tree release): now when no surface
/// is attached, else with the last detach. The next attach builds them again.
#[unsafe(no_mangle)]
pub extern "C" fn canvas_surface_release() {
    SHARED.with_borrow_mut(|shared| match shared {
        Some(s) if s.attached > 0 => s.release = true,
        _ => *shared = None,
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
    SHARED.with_borrow(Option::is_some)
}
