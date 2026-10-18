# Canvas

Pultík's one package for every Rust-drawn surface (PR diff decisions D5,
`docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md`): the host that puts a Rust engine on
screen, and every engine, over one C ABI (`crates/canvas-ffi`). One Swift module, `Canvas`, over
one C module, `CCanvas`.

- `CCanvas` is a module map over the generated `crates/canvas-ffi/include/canvas.h`
  (`cargo xtask canvas-header`, `--check` for drift), one prefix family per part:
  `canvas_surface_*`, `canvas_timeline_*`, `canvas_map_*`, `canvas_diff_*`. Never edit the
  header by hand: an ABI change edits the crate, regenerates the header and updates the Swift
  wrapper together.
- The host is `CanvasView` (AppKit): a `CAMetalLayer` backing, a display link that runs only
  while the engine animates or a gesture is in flight (else it sleeps until the frame's
  `nextDue`), two-finger scrolls with their momentum and pinches straight to the engine, never
  first responder (the app routes keys). It names no app type: the app gives it an `id` (its
  log lines), a background colour and `Hooks` (shown, viewed after each frame, playhead moved),
  and a `CanvasFrameObserver` (the app's frame bench) may watch its frames.
- An engine is a `CanvasEngine`: `TimelineEngine` (CI, Estate and Backups;
  `EstateTimeline.swift` adds the estate lenses' data), `MapEngine` (the estate map) and
  `DiffEngine` (the PR diff, inline or side by side, and the definition card:
  `canvas_text::diff_view`, which owns the layout, the scroll, the sticky header, the
  selection (inline only) and the word hits; Swift hands it the change set, each side's
  highlight runs, the theme id and the decor) and `MergeEngine` (one file's three-way merge,
  WebStorm's ours · result · theirs with the base on demand: `code_core::merge` merges it and
  `canvas_text::merge_view` lays the panes out, scrolls them in step, draws the ribbons and
  walks ⇥; Swift hands it the file's texts, a past merge's commit, each pane's runs and the
  panes' titles). Swift hands it data,
  gestures and key intents; Rust owns layout, hit testing, the camera and drawing. By default
  the host turns a press into the engine's click, pan or playhead scrub. An engine that
  handles the pointer itself answers `mouse(_:)`: a `.down` it takes makes the press its own
  (`.dragged` and `.up` follow, the display link stays awake), and while it `tracksHover` the
  host forwards `.moved` and `.exited` through a tracking area. Points are the view's, flipped.
- Every surface draws on one shared device (`CanvasSurface`): the GPU and the text system are
  built by the first attach and kept across detaches, so switching canvases builds none. The
  app's 30 s tree release calls `CanvasSurface.release()` after dropping its engines; `builds`
  and `live` are the panel driver's check. Main thread only.
- The package links nothing. Pultík links `libpultik_ffi.a`, the one Rust archive with
  code-core's ABI and this one (`cargo xtask umbrella-check` proves every function exported).
