// The dual-Kawase chain behind glass, and the copy of a layer frame's scene to its target.
//
// Fragment passes, not compute, so the chain runs on every backend the renderer ships (WebGL2
// has none). Each pass draws one triangle over its whole destination under a scissor, and a
// fragment's own pixel centre names where it reads: texel x of level k covers full-resolution
// pixels [x * 2^k, (x + 1) * 2^k), so a destination centre times `ratio` is the same point in
// source texels, exact on textures whose sizes were rounded up.

struct Params {
    rect: vec4<f32>,
    tint_top: vec4<f32>,
    tint_bottom: vec4<f32>,
    solid: vec4<f32>,
    // 1 / the source's size in texels, destination texels to source texels, the tap offset in
    // source texels.
    src_inv: vec2<f32>,
    ratio: f32,
    offset: f32,
    viewport: vec2<f32>,
    radius: f32,
    opacity: f32,
    blur_inv: vec2<f32>,
    saturate: f32,
    mode: f32,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(1) @binding(0) var src: texture_2d<f32>;
@group(1) @binding(1) var lin: sampler;

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let corner = vec2<f32>(f32((vi << 1u) & 2u), f32(vi & 2u));
    return vec4<f32>(corner * 2.0 - 1.0, 0.0, 1.0);
}

fn tap(c: vec2<f32>, d: vec2<f32>) -> vec4<f32> {
    return textureSampleLevel(src, lin, (c + d) * p.src_inv, 0.0);
}

// Full resolution to a quarter in one pass: four bilinear taps average the 4x4 block.
@fragment
fn quarter(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = pos.xy * p.ratio;
    return (tap(c, vec2<f32>(-1.0, -1.0)) + tap(c, vec2<f32>(1.0, -1.0))
        + tap(c, vec2<f32>(-1.0, 1.0)) + tap(c, vec2<f32>(1.0, 1.0))) * 0.25;
}

// Down one level: the centre and four diagonal taps.
@fragment
fn down(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = pos.xy * p.ratio;
    let o = p.offset;
    var sum = tap(c, vec2<f32>(0.0, 0.0)) * 4.0;
    sum += tap(c, vec2<f32>(-o, -o));
    sum += tap(c, vec2<f32>(o, o));
    sum += tap(c, vec2<f32>(o, -o));
    sum += tap(c, vec2<f32>(-o, o));
    return sum / 8.0;
}

// Up one level: four taps on the axes and four diagonal ones at half the reach, weighted twice.
@fragment
fn up(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = pos.xy * p.ratio;
    let o = p.offset;
    let h = o * 0.5;
    var sum = tap(c, vec2<f32>(-o, 0.0));
    sum += tap(c, vec2<f32>(o, 0.0));
    sum += tap(c, vec2<f32>(0.0, -o));
    sum += tap(c, vec2<f32>(0.0, o));
    sum += tap(c, vec2<f32>(-h, h)) * 2.0;
    sum += tap(c, vec2<f32>(h, h)) * 2.0;
    sum += tap(c, vec2<f32>(h, -h)) * 2.0;
    sum += tap(c, vec2<f32>(-h, -h)) * 2.0;
    return sum / 12.0;
}

// The finished scene onto the target, texel for texel.
@fragment
fn blit(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return textureLoad(src, vec2<i32>(pos.xy), 0);
}
