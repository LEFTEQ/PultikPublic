// Tessellated paths (lyon): fills and strokes as triangles, antialiased by the pass's 4×
// MSAA. A stroke vertex carries its advancement along the path, so dashes, their phase and a
// flow (the pattern moving at `speed` points per second) are cut here, per fragment, and a
// pinch or a flow tick never tessellates again. Pixels as in rect.wgsl; colours premultiplied.

struct Globals {
    viewport: vec2<f32>,
    time: f32,
    _pad: f32,
    // world pixel -> view pixel: xy scale, zw offset (identity outside a camera layer).
    camera: vec4<f32>,
};
@group(0) @binding(0) var<uniform> globals: Globals;

struct Vertex {
    @location(0) pos: vec2<f32>,
    @location(1) advance: f32,
    @location(2) color: vec4<f32>,
    // on, off, phase, speed in pixels; on <= 0 is solid.
    @location(3) dash: vec4<f32>,
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) advance: f32,
    @location(1) @interpolate(flat) color: vec4<f32>,
    @location(2) @interpolate(flat) dash: vec4<f32>,
};

@vertex
fn vs(v: Vertex) -> VsOut {
    let pixel = v.pos * globals.camera.xy + globals.camera.zw;
    let ndc = pixel / globals.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.advance = v.advance;
    out.color = v.color;
    out.dash = v.dash;
    return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
    // Derivatives must be evaluated before a potentially non-uniform early return.
    let w = max(fwidth(in.advance), 1e-4);
    let on = in.dash.x;
    if (on <= 0.0) {
        return in.color;
    }
    let period = on + in.dash.y;
    let along = in.advance + in.dash.z - globals.time * in.dash.w;
    let d = along - floor(along / period) * period;
    // Coverage across the dash's two ends, one pixel of the advancement wide.
    let coverage = clamp(min(d, on - d) / w + 0.5, 0.0, 1.0);
    return in.color * coverage;
}
