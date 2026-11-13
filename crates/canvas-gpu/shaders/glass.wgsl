// A glass layer's slab, and a group (a layer's `under` or `content` drawn apart) composited at
// the layer's opacity. Physical pixels, origin top-left; colours leave premultiplied and blend
// One / OneMinusSrcAlpha like every other pipeline.

struct Params {
    // The quad drawn, x, y, w, h: the slab, or for an unclipped group the whole target.
    rect: vec4<f32>,
    // Straight sRGB tints at the slab's top and bottom edges.
    tint_top: vec4<f32>,
    tint_bottom: vec4<f32>,
    // A solid slab's straight colour.
    solid: vec4<f32>,
    src_inv: vec2<f32>,
    ratio: f32,
    offset: f32,
    viewport: vec2<f32>,
    radius: f32,
    opacity: f32,
    // 1 / the blurred backdrop's size, in its quarter-resolution texels.
    blur_inv: vec2<f32>,
    saturate: f32,
    // 0 glass, 1 solid; for a group, 1 masks it by the rounded rect and 0 does not.
    mode: f32,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(1) @binding(0) var src: texture_2d<f32>;
@group(1) @binding(1) var lin: sampler;

struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) pixel: vec2<f32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> VsOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u));
    // One pixel of slack on every side for the edge's antialiasing.
    let pixel = p.rect.xy - 1.0 + corner * (p.rect.zw + 2.0);
    let ndc = pixel / p.viewport * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    var out: VsOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.pixel = pixel;
    return out;
}

fn sd_round_rect(q: vec2<f32>, half: vec2<f32>, radius: f32) -> f32 {
    let d = abs(q) - half + vec2<f32>(radius);
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0) - radius;
}

// The rounded rect's antialiased coverage at `pixel`.
fn coverage(pixel: vec2<f32>) -> f32 {
    let half = p.rect.zw * 0.5;
    let radius = min(p.radius, min(half.x, half.y));
    return clamp(0.5 - sd_round_rect(pixel - (p.rect.xy + half), half, radius), 0.0, 1.0);
}

@fragment
fn slab(in: VsOut) -> @location(0) vec4<f32> {
    var cov = coverage(in.pixel) * p.opacity;
    var rgb: vec3<f32>;
    if (p.mode < 0.5) {
        // The quarter-resolution blur, sampled bilinearly at this full-resolution pixel.
        let b = textureSampleLevel(src, lin, in.pixel * 0.25 * p.blur_inv, 0.0).rgb;
        // CSS saturate(): away from the Rec. 709 luma by `saturate`.
        let luma = dot(b, vec3<f32>(0.213, 0.715, 0.072));
        let s = clamp(mix(vec3<f32>(luma), b, p.saturate), vec3<f32>(0.0), vec3<f32>(1.0));
        let t = clamp((in.pixel.y - p.rect.y) / max(p.rect.w, 1.0), 0.0, 1.0);
        let tint = mix(p.tint_top, p.tint_bottom, t);
        rgb = mix(s, tint.rgb, tint.a);
    } else {
        rgb = p.solid.rgb;
        cov *= p.solid.a;
    }
    return vec4<f32>(rgb * cov, cov);
}

@fragment
fn group(in: VsOut) -> @location(0) vec4<f32> {
    let c = textureLoad(src, vec2<i32>(in.position.xy), 0);
    var k = p.opacity;
    if (p.mode > 0.5) {
        k *= coverage(in.pixel);
    }
    return c * k;
}
