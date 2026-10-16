// Terminal cell backgrounds (and cursor, underline and strike bars): flat premultiplied
// quads, the cheapest pipeline, drawn before a grid's glyphs.

struct Globals {
    viewport: vec2<f32>,
    time: f32,
    _pad: f32,
    // world pixel -> view pixel: xy scale, zw offset (identity outside a camera layer).
    camera: vec4<f32>,
};
@group(0) @binding(0) var<uniform> globals: Globals;

struct Instance {
    @location(0) quad: vec4<f32>,
    @location(1) color: vec4<f32>,
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) color: vec4<f32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> VsOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u));
    let cam = globals.camera;
    let pixel = inst.quad.xy * cam.xy + cam.zw + corner * inst.quad.zw * cam.xy;
    let ndc = pixel / globals.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.color = inst.color;
    return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
    return in.color;
}
