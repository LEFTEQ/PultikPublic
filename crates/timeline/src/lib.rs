//! Semafor's timelines, natively and on the web: one pannable, zoomable, infinitely paged
//! timeline engine and its lenses (CI, Estate, Backups, and plans built from plain data), drawn
//! on the canvas crates, and the estate map (`map`).
//!
//! The engine never looks inside an item: a lens ([`lens`]) turns its items into [`Mark`]s. A
//! timeline ([`Timeline`]) owns the view, the selection and the playhead; it builds a
//! [`scene::Scene`] (fold, tracks, layout, hit index) once per semantic change — the rendered
//! window, the zoom level (√2 steps), the data — and emits it as a display list whose camera
//! layers the host's GPU target (or a browser's Canvas2D painter) places, so a pan or a pinch
//! inside a level costs two uniforms. The host supplies the clock (zone and words) and the
//! chrome (label column, axis strip, the future's hatching); the defaults are Pultík's.
//!
//! | Module | Is |
//! |---|---|
//! | [`time`] | Milliseconds, the host's clock (a zone and its words; Prague in English by default), the axis's ticks |
//! | [`geometry`] | View, zoom limits and levels, the marks → bins policy, the semantic, the host's chrome |
//! | [`density`] | The fold (clusters, cadence rails, counted schedule repeats), both stepping orders, playhead snapping |
//! | [`tracks`] | A row opening into one track per item running at once |
//! | [`layout`] | Groups of rows at a size, and which row a point is in |
//! | [`mark`] | What the engine draws: marks (bars of stretches, points with text beside), bins, bands, lines, schedules |
//! | [`lens`] | The lens contract, the palette, and the lenses (`ci`; `estate` for Estate and Backups; `agents` for an agent's history and a fleet's; `data` for a plan) |
//! | [`scene`] | Built per semantic: items, hit testing in paint order, emission |
//! | [`timeline`] | The view, gestures, keys, selection, playhead, hover, the item feed and when to build |
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

pub use geometry::{Chrome, Future};
pub use lens::data::Plan;
pub use lens::{Lens, LensSpec, Palette};
pub use mark::{Band, Bin, Cap, Line, Mark, Paint, Schedule, Stretch};
pub use time::{Clock, Words, Zone, ZoneTable};
pub use timeline::{Feed, FeedItem, Hover, LaneBox, Step, Timeline};
