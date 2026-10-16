//! The contract between the engine and a screen: what one kind of item is (a CI job, an estate
//! event, a backup), how it becomes a [`Mark`] and how its timeline zooms, folds and pages. A new
//! timeline is a new lens, never a new engine.

pub mod ci;
pub mod estate;

use crate::density::FoldRules;
use crate::geometry::ZoomPolicy;
use crate::mark::Mark;
use crate::time::Ms;
use canvas_draw::Rgba;

/// The colours a timeline draws in, handed over by the host (Pultík's Theme status tokens): colour
/// means status (D4), never a repository.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Palette {
    pub background: Rgba,
    /// A group's band, alternate groups.
    pub band: Rgba,
    pub foreground: Rgba,
    pub muted: Rgba,
    /// Tick lines and lane borders.
    pub grid: Rgba,
    /// A finished item's bar.
    pub data: Rgba,
    /// Running.
    pub ok: Rgba,
    pub danger: Rgba,
    pub warning: Rgba,
    /// The selection ring and the playhead.
    pub accent: Rgba,
}

impl Default for Palette {
    /// A dark palette for tests and previews; the host always hands its own.
    fn default() -> Self {
        Palette {
            background: Rgba::hex(0x16171a),
            band: Rgba::hex(0x1c1d21),
            foreground: Rgba::hex(0xe6e6e6),
            muted: Rgba::hex(0x8a8d94),
            grid: Rgba::hex(0x2a2c31),
            data: Rgba::hex(0x7d8590),
            ok: Rgba::hex(0x4cc38a),
            danger: Rgba::hex(0xf2555a),
            warning: Rgba::hex(0xe5a54b),
            accent: Rgba::hex(0xe8c468),
        }
    }
}

/// What the engine needs to know of a lens beyond its marks.
#[derive(Debug, Clone, Copy)]
pub struct LensSpec {
    pub key: &'static str,
    pub zoom: ZoomPolicy,
    pub fold: FoldRules,
    /// Rows open into one track per item running at once.
    pub tracks: bool,
    /// How far right of now the scheduled future reaches.
    pub future: Ms,
}

pub trait Lens {
    type Item;
    fn spec(&self) -> LensSpec;
    /// `item` as the engine draws it.
    fn mark(&self, item: &Self::Item, palette: &Palette) -> Mark;
    /// A folded cluster's fill on a row.
    fn cluster_tone(&self, palette: &Palette, scheduled: bool) -> Rgba {
        if scheduled {
            palette.muted.with_alpha(0.6)
        } else {
            palette.data.with_alpha(0.8)
        }
    }
}
