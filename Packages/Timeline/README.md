# Timeline

The Swift face of the Rust timeline engine (`crates/timeline`, its C ABI `crates/timeline-ffi`):
Semafor's timelines drawn natively, keyboard first (phase-2 brief,
`docs/specs/2026-10-16-timelines-phase2-brief.md`).

- `CTimeline` is a module map over the generated `crates/timeline-ffi/include/timeline.h`
  (`cargo xtask timeline-header`, `--check` for drift). Never edit the header by hand: an ABI
  change edits the crate, regenerates the header and updates `TimelineEngine` together.
- `TimelineEngine` owns one handle: Swift hands it jobs, bins and groups of rows, gestures and
  key intents; Rust owns marks, layout, hit testing, stepping, the camera and drawing into the
  host's `CAMetalLayer`. Its GPU device exists only between `attach` and `detach`.
- The package links nothing. Pultík links `libpultik_ffi.a`, the one Rust archive with
  code-core's ABI and this one (`cargo xtask umbrella-check` proves every function exported).
