// Retained rects and glyphs share one instanced pipeline in exact painter order.
struct Globals { viewport: vec2<f32>, time: f32, _pad: f32, camera: vec4<f32> };
@group(0) @binding(0) var<uniform> globals: Globals;
@group(1) @binding(0) var alpha_atlas: texture_2d_array<f32>;
@group(1) @binding(1) var color_atlas: texture_2d_array<f32>;
@group(1) @binding(2) var atlas_sampler: sampler;
struct Instance {
    @location(0) quad: vec4<f32>,
    @location(1) shape: vec4<f32>,
    @location(2) fill: vec4<f32>,
    @location(3) border: vec4<f32>,
    @location(4) params: vec4<f32>,
    @location(5) uv: vec4<f32>,
    // x: kind (0 rect, 1 glyph), y: atlas layer plus glyph flags in high bits.
    @location(6) tag: vec2<u32>,
};
struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) pixel: vec2<f32>,
    @location(1) @interpolate(flat) shape: vec4<f32>,
    @location(2) @interpolate(flat) fill: vec4<f32>,
    @location(3) @interpolate(flat) border: vec4<f32>,
    @location(4) @interpolate(flat) params: vec4<f32>,
    @location(5) uv: vec2<f32>,
    @location(6) @interpolate(flat) tag: vec2<u32>,
};
@vertex fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> VsOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u));
    let cam = globals.camera;
    var pixel: vec2<f32>;
    var shape = inst.shape;
    if (inst.tag.x == 0u) {
        let size = select(inst.shape.zw * cam.xy, inst.shape.zw, inst.params.w > 0.5);
        let centre = (inst.shape.xy + inst.shape.zw * 0.5) * cam.xy + cam.zw;
        shape = vec4<f32>(centre - size * 0.5, size);
        let margin = inst.shape.xy - inst.quad.xy;
        pixel = shape.xy - margin + corner * (shape.zw + 2.0 * margin);
    } else {
        var origin = floor(inst.params.xy * cam.xy + cam.zw + vec2<f32>(0.5)) + inst.quad.xy;
        var size = inst.quad.zw;
        if ((inst.tag.y & 131072u) != 0u) {
            origin = inst.quad.xy * cam.xy + cam.zw;
            size = inst.quad.zw * cam.xy;
        }
        pixel = origin + corner * size;
    }
    var out: VsOut;
    let ndc = pixel / globals.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.pixel = pixel; out.shape = shape; out.fill = inst.fill;
    out.border = inst.border; out.params = inst.params;
    out.uv = mix(inst.uv.xy, inst.uv.zw, corner); out.tag = inst.tag;
    return out;
}
fn sd_round_rect(p: vec2<f32>, half: vec2<f32>, radius: f32) -> f32 {
    let q = abs(p) - half + vec2<f32>(radius);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}
@fragment fn fs(in: VsOut) -> @location(0) vec4<f32> {
    if (in.tag.x != 0u) {
        let layer = i32(in.tag.y & 65535u);
        let coverage = textureSampleLevel(alpha_atlas, atlas_sampler, in.uv, layer, 0.0).r;
        let rgba = textureSampleLevel(color_atlas, atlas_sampler, in.uv, layer, 0.0);
        if ((in.tag.y & 65536u) != 0u) { return rgba * in.fill.a; }
        return in.fill * coverage;
    }
    let half = in.shape.zw * 0.5;
    let radius = min(in.params.x, min(half.x, half.y));
    let d = sd_round_rect(in.pixel - (in.shape.xy + half), half, radius);
    let softness = in.params.z;
    var outer: f32;
    if (softness > 0.0) { outer = 1.0 - smoothstep(-softness, softness, d); }
    else { outer = clamp(0.5 - d, 0.0, 1.0); }
    let border = in.params.y;
    var inner = outer;
    if (border > 0.0) { inner = clamp(0.5 - (d + border), 0.0, 1.0); }
    return in.fill * inner + in.border * (outer - inner);
}
