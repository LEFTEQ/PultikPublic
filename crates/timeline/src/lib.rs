//! Semafor's timelines, natively: one pannable, zoomable, infinitely paged timeline engine and
//! its lenses (CI, Estate, Backups), drawn on the canvas crates, and the estate map (`map`).
//!
//! The engine never looks inside an item: a lens ([`lens`]) turns its items into [`Mark`]s. A
//! timeline ([`Timeline`]) owns the view, the selection and the playhead; it builds a
//! [`scene::Scene`] (fold, tracks, layout, hit index) once per semantic change — the rendered
//! window, the zoom level (√2 steps), the data — and emits it as a display list whose camera
//! layers the host's GPU target places, so a pan or a pinch inside a level costs two uniforms.
//!
//! | Module | Is |
//! |---|---|
//! | [`time`] | Milliseconds, the Prague clock (EU DST rule), the axis's ticks and labels |
//! | [`geometry`] | View, zoom limits and levels, the marks → bins policy, the semantic |
//! | [`density`] | The fold (clusters, cadence rails, counted schedule repeats), both stepping orders, playhead snapping |
//! | [`tracks`] | A row opening into one track per item running at once |
//! | [`layout`] | Groups of rows at a size, and which row a point is in |
//! | [`mark`] | What the engine draws: marks, bins, bands, schedules |
//! | [`lens`] | The lens contract, the palette, and the lenses (`ci`; `estate` for Estate and Backups) |
//! | [`scene`] | Built per semantic: items, hit testing in paint order, emission |
//! | [`timeline`] | The view, gestures, keys, selection, playhead and when to build |
//! | [`map`] | The estate map: Semafor's layered layout ported, its routes, the drawn scene, arrow walking |

pub mod density;
pub mod geometry;
pub mod layout;
pub mod lens;
pub mod map;
pub mod mark;
pub mod scene;
pub mod time;
pub mod timeline;
pub mod tracks;

pub use lens::{Lens, LensSpec, Palette};
pub use mark::{Band, Bin, Mark, Paint, Schedule};
pub use timeline::{Step, Timeline};
