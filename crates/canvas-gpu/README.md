# canvas-gpu

The shared wgpu renderer consumes `canvas-draw` display lists and `canvas-text`'s
atlas. Native Metal/Vulkan/GLES backends and BGRA targets remain unchanged.
`wasm32-unknown-unknown` enables wgpu's WebGPU and WebGL2 backends by target cfg,
not a crate feature. Browser targets use RGBA8 so WebGL2 needs no BGRA extension.
The same pipelines, instance buffers, paths and atlas draw both targets.

## Retained multi-list targets

Use `Target::begin_chunks`, `Gpu::upsert_chunk` / `Target::remove_chunk`,
`Gpu::set_chunk_overlay`, then `Gpu::publish_chunks` with an explicit painter-order
key slice and target clear colour. Prepare across as many host ticks as needed:
redraw keeps the previous complete publication visible until publish. A replacement
owns separate GPU buffers; neither a staged edit nor a failed publication changes
visible geometry. Beginning again abandons staging. Keys omitted from the order
remain cached but invisible; remove them explicitly when no longer reusable.

Lists are immutable `Arc<DisplayList>` resources. Reuse the same allocation for
unchanged content; a new allocation requests a rebuild/upload of only that key.
Each list balances its own clip and camera operations; list clear colours are
ignored. The optional overlay draws last. All chunks share the target's four
Follow uniforms and one render pass, including one 4× MSAA resolve if any list has
paths. This is not an independent-camera-per-chunk API.

After another surface may have reset the shared atlas, call `refresh_chunks`
before `set_camera` + `redraw`. Atlas-dependent lists rebuild their glyph references
and refresh their glyph/combined-quad buffers and bundles; shape/path-only
resources remain untouched.
Resizing rebuilds viewport-dependent frames. Retained building never evicts atlas
entries under already-published chunks: an oversized working set omits glyphs
that cannot fit until the host explicitly clears the atlas. Single-list `render`
and `draw_offscreen` select the original path again; their pixels are unchanged.
`retained_stats` counts resource uploads, builds, tessellation misses and atlas
refreshes; camera-only frames change none of them.

### CPU submission gate (D12)

`cargo test -p canvas-gpu --profile perf --test retained retained_cpu_frame_cost -- --ignored --nocapture`
measures 64 chunks containing 5,000 labelled nodes and 15,000 edges, using 120
warmups and 1,200 measured samples for both camera-only submission and one-key
replacement. Both p99 values must be ≤2.00 ms. Instance/glyph writes and render-pass
submission are included; readback/fences and the initial full scene build are
outside the timer. The single-key revision clones one list and reuses its warm
path cache; counters assert exactly one resource upload per replacement and no
new tessellations. This gates CPU cost, not GPU duration or application layout.
Run native GPU qualification on Metal, portable workspace verification on Devbox.
### Retained command cost (2026-10-21, Apple M3 Max / Metal)

The original submission measured camera p99 7.683 ms and single-key change p99
7.114 ms. Instrumentation reproduced 8.091 ms camera total: uniform writes
0.358 ms, command recording 0.536 ms, `CommandEncoder::finish` 7.735 ms, queue
submit 0.094 ms (stage percentiles are independent, not additive). The fixture
alternates each rect with its label: the equivalent single list has **10,064
batches**, so combining lists alone does not fix the draw-call cost. Isolated
single-list p99 was 11.870 ms; bare render bundles still spent 9.308 ms in finish.

Retained preparation now packs adjacent rect/glyph instances in exact painter
order into one tagged quad pipeline and caches render bundles per clip run and
sample count. No sorting, element walk, geometry work or instance upload occurs
on a camera frame. This fixture becomes two draws per chunk (path, ordered quads),
128 draws total. Camera frames write only changed, used Follow uniforms; static
scenes do not advance an unused shader clock. The existing single-list pipelines
stay unchanged; byte-equality tests cover interleaved translucent rects, text,
colour emoji, clips, mixed Follow axes and the one MSAA resolve.

Optimized p99: **camera 0.281 ms, single-key change 0.853 ms** (1,200 measured
samples each; each key's repeated revision alternates one node fill). Camera
stages: uniforms 0.059 ms, command recording 0.013 ms, finish 0.191 ms, queue
submit 0.029 ms. Change preparation: rebuild 0.177 ms, resource uploads 0.203 ms,
bundle creation 0.101 ms. The same run's single-list baseline was 9.499 ms. Inactive buffers are
recycled per key only after their old publication loses all CPU owners; staged
replacements never write the currently published buffers. Queue ordering protects
already-submitted GPU reads. This avoids allocator/driver spikes while retaining
atomic publication. The camera loop performed
zero resource uploads/builds/tessellations; the change loop uploaded exactly
1,320 resources including warmup and performed no new tessellations.

`Target::cpu_profile` separates uniform writes, command recording, finish and
queue submission, and on surfaces separately records acquire and present wall
time. This fixture is offscreen: acquire/present/vsync waits are **absent**, and
readback/GPU fences are outside every measured region. It does not claim a GPU
duration, compositor measurement or CAMetalLayer present latency. The MSAA path
remains one pass and one resolve, never one per chunk.

### Viewport-selected retained submissions

Each clip run retains conservative geometry bounds and its Follow class when its
bundles are built. Bounds come from prepared shapes, glyph anchors/pixel extents,
cells and tessellated path vertices, so pinned geometry and fixed-size text keep
their screen-space margins at every zoom. Mixed-Follow or unknown bounds remain
unculled. Publication builds a balanced spatial hierarchy per Follow class and
caches aggregate path/animation/uniform flags. Camera changes query those indexes,
restore painter order, and retain the selection allocation; an unchanged camera
and publication reuse the selection without walking all chunks.

Consecutive selected runs sharing a scissor execute in one bundle call. Culling
never reorders runs, changes a clip, removes the overlay ordering or uploads a
resource. Publication/atlas refresh invalidates the index and camera cache.
`CpuFrameProfile` additionally exposes `cull_ms`, `retained_runs`, `executed_runs`
and `bundle_calls` for qualification.

Apple M3 Max / Metal, optimized native measurement: the 20,000-key grid with a
320×180 viewport executed 252 runs in one bundle call. Over 200 measured camera
submissions after 40 warmups, p50 was 0.411 ms, p99 2.161 ms, max 34.290 ms;
selection-query p99 was 0.022 ms. GPU readback/fences were outside the timer and
resource upload/build/tessellation counters stayed unchanged. This is CPU
submission evidence, not a browser or GPU-duration claim. The existing 64-chunk
5k-label/15k-edge gate measured camera p99 0.287 ms and single-key replacement
p99 0.641 ms (1,200 samples after 120 warmups), preserving the earlier native
camera level within measurement variation.

```sh
cargo test -p canvas-gpu --profile perf --test retained retained_20k_visible_submission_cost -- --ignored --nocapture
cargo test -p canvas-gpu --profile perf --test retained retained_cpu_frame_cost -- --ignored --nocapture
```

The Devbox Rust image has no native graphics adapter: portable GPU integration
tests return early there. The retained pixel/culling tests and both measurements
above were therefore also run against the actual Metal adapter. The Wasm browser
harness build passed on Devbox; no browser execution is claimed by this change.

## Browser host

Call `Gpu::for_canvas(canvas, backing_scale).await` on the main thread. It selects
WebGPU first and falls back to WebGL2 when no usable WebGPU device is available.
The surface and device must be created together for WebGL2. A browser canvas is
bound to its first context type; a surface error after successful WebGPU context
creation is returned, not silently retried on the already-claimed canvas.

Call `render` when content changes, then `set_camera` + `redraw` for camera-only
frames. These frames retain geometry and glyph buffers; they do not rebuild or
upload instances. Browser offscreen drawing submits without blocking. Await
`read_offscreen_async` for RGBA readback; synchronous initialization and readback
wrappers are native-only. This avoids blocking the browser's completion callbacks.
Browser readback pumps WebGL device callbacks while yielding browser tasks.

Use HTTPS (or localhost) for WebGPU. WebGL2 is the software-renderable CI path.
Only downlevel WebGL2 limits are requested on Wasm. No compute/storage shader
features are required. Text limitations are documented in `../canvas-text/README.md`.

## Qualification

Build on Devbox, never a full workspace build on the Mac:

```sh
devbox run --image rust:1.96.0-trixie -- 'sh crates/canvas-gpu/tests/browser/build.sh'
```

The pinned wasm-bindgen executable is SHA256-checked. Generated artifacts stay in
ignored `target/browser/` on the box. Run the static server as a Devbox app command
`bun crates/canvas-gpu/tests/browser/server.ts {port}`, with `ready: {http: /}`.
Open the URL returned by `devbox url`, not a guessed port. The page exposes
`window.qualification`: a golden-pixel assertion (per-channel tolerance 12, at
most 0.5% of pixels outside tolerance), an independent text-ink assertion and the
camera CPU gate. `?webgl` hides WebGPU before initialization to qualify fallback.
`?capture` writes a baseline candidate to `target/browser/candidate.json`, never
a pass against the golden. Review a candidate before replacing `golden.json`.

`tests/browser/run.ts` is the Bun headless CI entrypoint for an environment providing
Chromium (`CHROMIUM_PATH`); no Playwright package installation is needed. Pass the
running qualification URL. Chromium's built-in DOM runner selects software ANGLE
and disables WebGPU; the fixture must finish with `passed: true`.

The pixel fixture is 160×88: rounded blue node, a gold path and white label. The
separate camera workload retains 1,000 nodes, 1,000 labels and 1,000 edges, ordered
as edges → fills → labels for batching, in the existing `perf` Cargo profile. It
uses 120 warm-up submissions and 1,200 measured pan submissions at scale 1, yielding
a browser task between submissions (outside the measurement). No geometry
build, GPU fence or readback is inside the measured region. p99 must be ≤8.33 ms;
upload and tessellation counters must remain unchanged. This measures CPU
submission, not GPU duration or a consumer's graph layout/hit-test cost (D12).

### Recorded qualification (2026-10-21)

On the session's headless Onyx Chromium 154 on an Apple M3 Max, the 160×88
committed fixture matched exactly on WebGPU and ANGLE/Metal WebGL2 (0 pixels
outside tolerance, 298 white text pixels). The graph camera p99 was 0.40 ms on
WebGPU and 0.90 ms on WebGL2. Each run retained two content uploads and encoded
1,322 frames; the 1,320 camera submissions did not upload or tessellate.

After the retained submission change, the same Onyx Chromium 154 WebGL2 harness
passed again on ANGLE/Metal: 0 pixels outside tolerance (maximum channel delta 2),
298 white text pixels, camera p99 1.10 ms, two content uploads and 1,322 encodes.
The direct HTTP qualification address selected WebGL2 (not a WebGPU result).
After quad fusion/buffer recycling, the harness also asserts exact retained versus
legacy pixels before comparing the committed golden. It passed with 0 pixels
outside tolerance (maximum delta 2), 298 text pixels and camera p99 0.80 ms.

The Devbox Linux software-Chromium attempt did not run the fixture: Chromium
aborted with `No usable sandbox!` before loading the page. The runner deliberately
does not disable Chromium's sandbox. An owner must provide a sandbox-capable
Chromium installation on that guest before this becomes qualified Linux CI.
The golden uses platform sans-serif; Linux font portability remains unqualified
until that run is possible. Do not call the Mac WebGL result a software-GL pass.
