// SDF rounded rects: fill, inner border and soft shadow, one instanced quad each.
// Everything is in physical pixels with the origin at the top-left; colours arrive
// premultiplied and blend One / OneMinusSrcAlpha.

struct Globals {
    viewport: vec2<f32>,
    time: f32,
    _pad: f32,
    // world pixel -> view pixel: xy scale, zw offset (identity outside a camera layer).
    camera: vec4<f32>,
};
@group(0) @binding(0) var<uniform> globals: Globals;

struct Instance {
    @location(0) quad: vec4<f32>,         // x, y, w, h of the drawn quad
    @location(1) shape: vec4<f32>,        // x, y, w, h of the rounded rect
    @location(2) fill: vec4<f32>,
    @location(3) border_color: vec4<f32>,
    @location(4) params: vec4<f32>,       // radius, border width, softness, pinned
};

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) pixel: vec2<f32>,
    @location(1) @interpolate(flat) shape: vec4<f32>,
    @location(2) @interpolate(flat) fill: vec4<f32>,
    @location(3) @interpolate(flat) border_color: vec4<f32>,
    @location(4) @interpolate(flat) params: vec4<f32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> VsOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u));
    // The camera places the shape by its centre and scales it, unless it is pinned (params.w:
    // a point mark keeps its size); the quad keeps its margin around it (AA slack, a shadow's
    // blur) in pixels, and the radius and border never scale.
    let cam = globals.camera;
    let size = select(inst.shape.zw * cam.xy, inst.shape.zw, inst.params.w > 0.5);
    let centre = (inst.shape.xy + inst.shape.zw * 0.5) * cam.xy + cam.zw;
    let shape = vec4<f32>(centre - size * 0.5, size);
    let margin = inst.shape.xy - inst.quad.xy;
    let pixel = shape.xy - margin + corner * (shape.zw + 2.0 * margin);
    let ndc = pixel / globals.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.pixel = pixel;
    out.shape = shape;
    out.fill = inst.fill;
    out.border_color = inst.border_color;
    out.params = inst.params;
    return out;
}

fn sd_round_rect(p: vec2<f32>, half: vec2<f32>, radius: f32) -> f32 {
    let q = abs(p) - half + vec2<f32>(radius);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
    let half = in.shape.zw * 0.5;
    let radius = min(in.params.x, min(half.x, half.y));
    let d = sd_round_rect(in.pixel - (in.shape.xy + half), half, radius);
    let softness = in.params.z;
    var outer: f32;
    if (softness > 0.0) {
        outer = 1.0 - smoothstep(-softness, softness, d);
    } else {
        outer = clamp(0.5 - d, 0.0, 1.0);
    }
    let border = in.params.y;
    var inner = outer;
    if (border > 0.0) {
        inner = clamp(0.5 - (d + border), 0.0, 1.0);
    }
    return in.fill * inner + in.border_color * (outer - inner);
}
