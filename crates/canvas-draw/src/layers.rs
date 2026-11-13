//! A frame as depth-ordered layers over a wallpaper: what a glass compositor hands the renderer.
//!
//! A [`DisplayList`] alone cannot say "blur what is under this slab", so a frame that has
//! translucent slabs is a [`LayerFrame`]: a wallpaper and its layers back to front. The renderer
//! owns the blur (how it samples, caches and caps it); the producer only names each slab, its
//! material and what changed since the last frame, so a still frame costs no blur pass.
//!
//! Like every display-list type, everything is in view points with a top-left origin, and
//! colours are straight sRGB.

use crate::{DisplayList, Rect, Rgba};

/// A layer's identity across frames: the key of the renderer's cached blur for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LayerId(pub u64);

/// Translucent glass: the frame under the slab, blurred and saturated, under a vertical tint.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glass {
    /// The blur's standard deviation, in points.
    pub sigma: f32,
    /// The saturation applied to the blurred backdrop (`1.0` leaves it as it is).
    pub saturate: f32,
    /// The tint at the slab's top edge, composited over the blurred backdrop.
    pub tint_top: Rgba,
    /// The tint at the slab's bottom edge.
    pub tint_bottom: Rgba,
}

/// How a layer's slab is filled before its content draws.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Material {
    /// No slab: the layer is only its content.
    Bare,
    /// A translucent slab that reads the frame under it.
    Glass(Glass),
    /// An opaque slab that reads nothing under it: what glass becomes when transparency is
    /// reduced or the device is hot or saving power. It costs no blur pass.
    Solid(Rgba),
}

/// One slab of a [`LayerFrame`].
#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    pub id: LayerId,
    /// The slab, in points.
    pub rect: Rect,
    /// The slab's corner radius, in points.
    pub radius: f32,
    pub material: Material,
    /// The whole layer's opacity, `0.0..=1.0`: the slab, `under` and `content` alike.
    pub opacity: f32,
    /// Drawn before the slab and not clipped to it: the slab's drop shadows.
    pub under: DisplayList,
    /// Drawn over the slab and clipped to its rounded rect: rims, scrims, text, everything else.
    pub content: DisplayList,
    /// Moves whenever `under`, `content`, `material` or `radius` changed. With `rect`, it is how
    /// the renderer knows which cached blurs above this layer went stale; a producer that
    /// cannot tell may move it every frame, at the cost of the blur cache.
    pub rev: u64,
}

/// What sits under every layer. It is blurred once per `rev`, never per frame.
#[derive(Debug, Clone, PartialEq)]
pub struct Wallpaper {
    pub content: DisplayList,
    /// Moves whenever `content` changed (a space or a tint change).
    pub rev: u64,
}

/// A whole frame: the wallpaper, then `layers` back to front.
#[derive(Debug, Clone, PartialEq)]
pub struct LayerFrame {
    pub wallpaper: Wallpaper,
    pub layers: Vec<Layer>,
    /// The most glass layers the renderer may re-blur in one frame. A layer over the cap keeps
    /// its last blur (or samples the wallpaper's) until motion settles.
    pub blur_cap: u8,
}
