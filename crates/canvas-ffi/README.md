# canvas-ffi

The C ABI and the Rust-only shared renderer owner for hosted canvas surfaces.
The generated `include/canvas.h` remains the Swift boundary; Rust references never
cross it. See `Packages/Canvas/README.md` for the native host and engine model.

Other workspace Rust embeddings may use `surface::Surface` directly, without
creating a second device or text system. On the main thread, attach a valid
`CAMetalLayer` with `unsafe Surface::attach`, then call `resize` as the host size
changes. The layer must outlive the surface. `Surface` is neither Send nor Sync.

`surface.with(|gpu, target, text| ...)` borrows the existing shared `Gpu`, that
surface's `Target`, and the shared `TextSystem` for the closure. Use the ordinary
single-list or retained multi-list canvas-gpu APIs there. The closure must not
re-enter another shared surface operation; the borrow is exclusive, and its
references cannot escape. `atlas_generation` exposes the shared atlas generation
for engines retaining glyph references. Retained consumers call
`Gpu::refresh_chunks` before redraw after possible atlas changes.

Drop the surface to detach; the GPU/text owner remains available to the next
surface. `canvas_surface_release` drops it when no surfaces remain (or defers
until the last detach). No private engine dependency or parallel renderer belongs
here. Attach failures implement `std::error::Error` through `SurfaceError` without
exposing the C ABI's internal failure type.
