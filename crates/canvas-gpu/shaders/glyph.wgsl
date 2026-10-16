// Textured glyph quads: coverage from the alpha atlas tinted by the run colour, or
// premultiplied colour (emoji) from the RGBA atlas scaled by the run's opacity.

struct Globals {
    viewport: vec2<f32>,
    time: f32,
    _pad: f32,
    // world pixel -> view pixel: xy scale, zw offset (identity outside a camera layer).
    camera: vec4<f32>,
};
@group(0) @binding(0) var<uniform> globals: Globals;
@group(1) @binding(0) var alpha_atlas: texture_2d_array<f32>;
@group(1) @binding(1) var color_atlas: texture_2d_array<f32>;
@group(1) @binding(2) var atlas_sampler: sampler;

struct Instance {
    @location(0) quad: vec4<f32>,   // x, y, w, h in pixels
    @location(1) uv: vec4<f32>,     // u0, v0, u1, v1
    @location(2) color: vec4<f32>,  // premultiplied tint
    @location(3) page: vec2<u32>,   // layer; flags: 1 colour glyph, 2 stretched by the camera
    @location(4) anchor: vec2<f32>, // the pen in a camera layer (quad.xy is then its offset)
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) @interpolate(flat) color: vec4<f32>,
    @location(2) @interpolate(flat) page: vec2<u32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> VsOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u));
    // A glyph keeps its size: the camera moves its pen, snapped to a pixel, so text in a
    // camera layer stays crisp. An image (flag 2) is a rect the camera stretches.
    let cam = globals.camera;
    var origin = floor(inst.anchor * cam.xy + cam.zw + vec2<f32>(0.5)) + inst.quad.xy;
    var size = inst.quad.zw;
    if ((inst.page.y & 2u) != 0u) {
        origin = inst.quad.xy * cam.xy + cam.zw;
        size = inst.quad.zw * cam.xy;
    }
    let pixel = origin + corner * size;
    let ndc = pixel / globals.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = mix(inst.uv.xy, inst.uv.zw, corner);
    out.color = inst.color;
    out.page = inst.page;
    return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
    let layer = i32(in.page.x);
    let coverage = textureSampleLevel(alpha_atlas, atlas_sampler, in.uv, layer, 0.0).r;
    let rgba = textureSampleLevel(color_atlas, atlas_sampler, in.uv, layer, 0.0);
    if ((in.page.y & 1u) != 0u) {
        return rgba * in.color.a;
    }
    return in.color * coverage;
}
