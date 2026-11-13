//! Glass: a [`LayerFrame`] drawn with translucent slabs that blur what is under them.
//!
//! The technique is the one the glass spike measured: dual Kawase at quarter resolution. A 4x4
//! box takes the frame to 1/4, the chain goes down as deep as the sigma needs (1/64 for 28 pt on
//! a 3x phone) and back up to 1/4, with its tap offset calibrated so the
//! chain's spread equals the layer's sigma, and the slab samples the result bilinearly at full
//! resolution. A full-resolution Gaussian costs a whole 120 Hz frame on the phone, so there is
//! none.
//!
//! Caching is always on, because a still desktop must cost what an opaque one does:
//! - the wallpaper is blurred once per `Wallpaper::rev` (once per glass sigma in use);
//! - a glass layer whose footprint (its rect grown by 3 sigma) meets no layer beneath samples
//!   that blur at no cost, even while it moves;
//! - a glass layer over other layers keeps its own blur and re-blurs only when its rect moved,
//!   the layers beneath it changed order, or a layer beneath whose old or new rect meets its
//!   footprint changed this frame (its rect, `rev` or opacity, or its own re-blur);
//! - at most `blur_cap` of those re-blur a frame, the moving layers first, then the layers above
//!   one, then those nearest the front. The rest keep their last blur, or sample the wallpaper's
//!   when they moved, and re-blur on a later frame, so the exact stack returns as motion settles.
//!
//! A still frame does no blur pass; `Solid` and `Bare` never blur.
//!
//! Every list draws into a scene texture the chain can read, copied to the target last in the
//! pass that also draws the frame's last batch (a frame no chain or scratch list read draws
//! straight onto the target), and the wallpaper opens the first batch: on Metal each pass is two
//! command buffers. A list that has paths, a list drawn at a layer's partial opacity, and a
//! layer's content under a rounded clip are drawn apart into a scratch texture first and
//! composited: that pass starts cleared, so its 4x MSAA attachment stays memoryless, and the scene
//! is never multisampled.

use crate::frame::{Frame, Viewport};
use crate::{Buffers, FORMAT, Globals, Gpu, GpuError, PATH_SAMPLES, Target};
use canvas_draw::Rect;
use canvas_draw::layers::{LayerFrame, LayerId, Material};
use canvas_text::TextSystem;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// The chain's base level: the 4x4 box lands at 1/4, where every blur is kept.
const BASE: u32 = 2;
/// The deepest level the chain may reach (1/512), past any sigma the design names.
const DEEPEST: u32 = BASE + 7;
/// Passes of the longest chain: the box, then down and back up through every level.
const CHAIN_PASSES: usize = 1 + 2 * (DEEPEST - BASE) as usize;

/// The uniform block every glass pass reads (`Params` in `blur.wgsl` and `glass.wgsl`).
#[repr(C)]
#[derive(Clone, Copy, Default, bytemuck::Pod, bytemuck::Zeroable)]
struct Params {
    rect: [f32; 4],
    tint_top: [f32; 4],
    tint_bottom: [f32; 4],
    solid: [f32; 4],
    src_inv: [f32; 2],
    ratio: f32,
    offset: f32,
    viewport: [f32; 2],
    radius: f32,
    opacity: f32,
    blur_inv: [f32; 2],
    saturate: f32,
    mode: f32,
}

/// How deep the chain goes and how far its taps reach, for one sigma.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Plan {
    deepest: u32,
    /// The tap offset, in source texels.
    offset: f32,
}

/// A texture the glass passes draw into and read, with its bind group as a source.
struct Tex {
    _texture: wgpu::Texture,
    view: wgpu::TextureView,
    source: wgpu::BindGroup,
    size: [u32; 2],
}

impl Tex {
    fn new(
        device: &wgpu::Device,
        pipes: &GlassPipelines,
        label: &str,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Self {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let source = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(label),
            layout: &pipes.source_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&pipes.sampler),
                },
            ],
        });
        Self {
            _texture: texture,
            view,
            source,
            size,
        }
    }

    fn inv(&self) -> [f32; 2] {
        [1.0 / self.size[0] as f32, 1.0 / self.size[1] as f32]
    }
}

/// The glass pipelines and what they share, built once per [`Gpu`].
pub(crate) struct GlassPipelines {
    /// The blur chain's format: half floats where the adapter renders and filters them (no
    /// banding on a dark gradient), else 8 bits.
    chain_format: wgpu::TextureFormat,
    params_layout: wgpu::BindGroupLayout,
    source_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    quarter: wgpu::RenderPipeline,
    down: wgpu::RenderPipeline,
    up: wgpu::RenderPipeline,
    blit: wgpu::RenderPipeline,
    slab: wgpu::RenderPipeline,
    group: wgpu::RenderPipeline,
    /// Calibrated chains by sigma key: the search runs once per sigma per device.
    plans: Mutex<HashMap<u32, Plan>>,
}

impl GlassPipelines {
    pub(crate) fn new(device: &wgpu::Device, adapter: &wgpu::Adapter) -> Self {
        let half = adapter.get_texture_format_features(wgpu::TextureFormat::Rgba16Float);
        let chain_format = if half
            .allowed_usages
            .contains(wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING)
            && half
                .flags
                .contains(wgpu::TextureFormatFeatureFlags::FILTERABLE)
        {
            wgpu::TextureFormat::Rgba16Float
        } else {
            wgpu::TextureFormat::Rgba8Unorm
        };
        let params_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("glass params"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: true,
                    min_binding_size: wgpu::BufferSize::new(size_of::<Params>() as u64),
                },
                count: None,
            }],
        });
        let source_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("glass source"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("glass"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("glass"),
            bind_group_layouts: &[Some(&params_layout), Some(&source_layout)],
            ..Default::default()
        });
        let module = |label: &str, source: &str| {
            device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some(label),
                source: wgpu::ShaderSource::Wgsl(source.into()),
            })
        };
        let blur = module("blur", include_str!("../shaders/blur.wgsl"));
        let glass = module("glass", include_str!("../shaders/glass.wgsl"));
        let pipeline = |module: &wgpu::ShaderModule,
                        entry: &str,
                        format: wgpu::TextureFormat,
                        blend: Option<wgpu::BlendState>,
                        topology: wgpu::PrimitiveTopology| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(entry),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module,
                    entry_point: Some("vs"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                primitive: wgpu::PrimitiveState {
                    topology,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some(entry),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let list = wgpu::PrimitiveTopology::TriangleList;
        let strip = wgpu::PrimitiveTopology::TriangleStrip;
        let over = Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING);
        Self {
            quarter: pipeline(&blur, "quarter", chain_format, None, list),
            down: pipeline(&blur, "down", chain_format, None, list),
            up: pipeline(&blur, "up", chain_format, None, list),
            blit: pipeline(&blur, "blit", FORMAT, None, list),
            slab: pipeline(&glass, "slab", FORMAT, over, strip),
            group: pipeline(&glass, "group", FORMAT, over, strip),
            chain_format,
            params_layout,
            source_layout,
            sampler,
            plans: Mutex::new(HashMap::new()),
        }
    }

    /// The chain for `sigma_px`, calibrated on first use.
    fn plan(&self, key: u32) -> Plan {
        // The map is a memo: a panic elsewhere cannot leave it half-written.
        let mut plans = self.plans.lock().unwrap_or_else(|e| e.into_inner());
        *plans
            .entry(key)
            .or_insert_with(|| calibrate(key as f32 / SIGMA_STEPS))
    }
}

/// Sigmas are keyed in quarter pixels: closer ones share a chain and a wallpaper blur.
const SIGMA_STEPS: f32 = 4.0;

fn sigma_key(sigma_px: f32) -> u32 {
    (sigma_px.max(0.0) * SIGMA_STEPS).round() as u32
}

/// The chain whose spread is nearest `sigma_px`: the shallowest depth that comes within 4 %
/// at some offset from 0.75 to 2 texels in sixteenths, as the spike calibrated it, or the
/// nearest of all depths.
fn calibrate(sigma_px: f32) -> Plan {
    let n = ((sigma_px * 24.0) as usize).max(2048).next_power_of_two();
    let mut nearest: Option<(Plan, f32)> = None;
    for deepest in BASE + 1..=DEEPEST {
        let mut best: Option<(Plan, f32)> = None;
        for step in 0..=20 {
            let plan = Plan {
                deepest,
                offset: 0.75 + step as f32 * 0.0625,
            };
            let miss = (spread(n, plan) - sigma_px).abs();
            if best.is_none_or(|(_, b)| miss < b) {
                best = Some((plan, miss));
            }
        }
        let Some((plan, miss)) = best else { continue };
        if miss <= 0.04 * sigma_px {
            return plan;
        }
        if nearest.is_none_or(|(_, b)| miss < b) {
            nearest = Some((plan, miss));
        }
    }
    nearest.map_or(
        Plan {
            deepest: BASE + 1,
            offset: 0.75,
        },
        |(plan, _)| plan,
    )
}

/// The standard deviation, in full-resolution pixels, of `plan`'s chain on an impulse in a row
/// of `n` pixels. Every pass is linear and its taps are symmetric, so a row's response is the
/// column sum of the 2D one: each pass reduces to its taps' horizontal positions and weights.
fn spread(n: usize, plan: Plan) -> f32 {
    let len = |k: u32| n.div_ceil(1 << k);
    let mut row = vec![0.0f32; n];
    row[n / 2] = 1.0;
    let mut cur = resample(&row, len(BASE), 4.0, &[(-1.0, 0.5), (1.0, 0.5)]);
    let o = plan.offset;
    for k in BASE + 1..=plan.deepest {
        cur = resample(&cur, len(k), 2.0, &[(0.0, 0.5), (-o, 0.25), (o, 0.25)]);
    }
    let (a, b, c) = (1.0 / 12.0, 2.0 / 12.0, 4.0 / 12.0);
    for k in (BASE..plan.deepest).rev() {
        let taps = [(-o, a), (o, a), (0.0, b), (-o / 2.0, c), (o / 2.0, c)];
        cur = resample(&cur, len(k), 0.5, &taps);
    }
    let scale = (1u32 << BASE) as f64;
    let (mut m0, mut m1, mut m2) = (0.0f64, 0.0f64, 0.0f64);
    for (x, v) in cur.iter().enumerate() {
        let (v, pos) = (*v as f64, (x as f64 + 0.5) * scale - 0.5);
        m0 += v;
        m1 += v * pos;
        m2 += v * pos * pos;
    }
    let mean = m1 / m0;
    (m2 / m0 - mean * mean).max(0.0).sqrt() as f32
}

/// One pass of the chain on a row: each destination texel's centre times `ratio` is the same
/// point in source texels, and every tap there is a bilinear read clamped to the edge.
fn resample(src: &[f32], len: usize, ratio: f32, taps: &[(f32, f32)]) -> Vec<f32> {
    let at = |i: f32| src[(i.max(0.0) as usize).min(src.len() - 1)];
    (0..len)
        .map(|x| {
            let c = (x as f32 + 0.5) * ratio;
            taps.iter()
                .map(|&(d, w)| {
                    let t = c + d - 0.5;
                    let i = t.floor();
                    let f = t - i;
                    w * (at(i) * (1.0 - f) + at(i + 1.0) * f)
                })
                .sum()
        })
        .collect()
}

/// One display list's built frame and its GPU buffers, kept while its key holds: its `rev` and,
/// for a layer, its rect. A layer's lists are in absolute points, so a moved slab whose producer
/// kept its `rev` still draws its lists where they now are.
#[derive(Default)]
struct List {
    frame: Frame,
    buffers: Buffers,
    /// The key and atlas generation it was built at.
    built: Option<((u64, Rect), u64)>,
    /// Rebuilt since its buffers were written.
    stale: bool,
}

impl List {
    fn build(
        &mut self,
        dl: &canvas_draw::DisplayList,
        key: (u64, Rect),
        text: &mut TextSystem,
        vp: Viewport,
    ) {
        if self.built == Some((key, text.atlas().generation())) {
            return;
        }
        self.frame.rebuild(dl, text, vp);
        self.built = Some((key, text.atlas().generation()));
        self.stale = true;
    }

    /// Build again without clearing the atlas: another list cleared it after this one was built.
    fn rebuild(
        &mut self,
        dl: &canvas_draw::DisplayList,
        key: (u64, Rect),
        text: &mut TextSystem,
        vp: Viewport,
    ) {
        self.frame.rebuild_retained(dl, text, vp);
        self.built = Some((key, text.atlas().generation()));
        self.stale = true;
    }

    fn is_empty(&self) -> bool {
        self.frame.batches.is_empty()
    }
}

/// What a layer was last frame: what its cache and its neighbours' dirt are judged against.
#[derive(Clone, Copy)]
struct Seen {
    rect: Rect,
    rev: u64,
    opacity: f32,
    /// A hash of the ids beneath it, back to front.
    below: u64,
}

/// A layer's own quarter-resolution blur.
struct Cached {
    tex: Tex,
    sigma: u32,
    /// The rect it was blurred for: the chain writes only that region.
    rect: Rect,
}

#[derive(Default)]
struct LayerState {
    under: List,
    content: List,
    seen: Option<Seen>,
    blur: Option<Cached>,
    /// Wanted a re-blur and was over the cap: it re-blurs on a later frame.
    pending: bool,
}

/// A target's layer-frame state: the scene, the chain's levels and every cached blur.
pub(crate) struct Glass {
    viewport: Viewport,
    scene: Tex,
    scratch: Tex,
    /// The 4x attachment of a group or wallpaper with paths, resolved and never stored.
    msaa: Option<wgpu::TextureView>,
    /// The chain's scratch levels, by level (`BASE..=DEEPEST`).
    levels: Vec<Option<Tex>>,
    wallpaper: List,
    wall_rev: Option<u64>,
    /// The wallpaper blurred per sigma key, with the `rev` it was blurred at.
    wall_blurs: HashMap<u32, (Tex, Option<u64>)>,
    layers: HashMap<LayerId, LayerState>,
    /// The frame's pass parameters at `stride` bytes apart, bound by dynamic offset.
    uniforms: Option<(wgpu::Buffer, u64, wgpu::BindGroup)>,
    staging: Vec<u8>,
    stride: u64,
}

fn level_size(size: [u32; 2], k: u32) -> [u32; 2] {
    [
        size[0].div_ceil(1 << k).max(1),
        size[1].div_ceil(1 << k).max(1),
    ]
}

impl Glass {
    fn new(device: &wgpu::Device, pipes: &GlassPipelines, viewport: Viewport) -> Self {
        let size = [viewport.width_px.max(1), viewport.height_px.max(1)];
        let align = device.limits().min_uniform_buffer_offset_alignment as u64;
        Self {
            viewport,
            scene: Tex::new(device, pipes, "glass scene", size, FORMAT),
            scratch: Tex::new(device, pipes, "glass group", size, FORMAT),
            msaa: None,
            levels: (0..=DEEPEST).map(|_| None).collect(),
            wallpaper: List::default(),
            wall_rev: None,
            wall_blurs: HashMap::new(),
            layers: HashMap::new(),
            uniforms: None,
            staging: Vec::new(),
            stride: (size_of::<Params>() as u64).div_ceil(align) * align,
        }
    }

    fn size(&self) -> [u32; 2] {
        self.scene.size
    }
}

/// A full-resolution pixel box, `x0..x1` by `y0..y1`.
#[derive(Clone, Copy)]
struct Px {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
}

impl Px {
    fn of(r: Rect, scale: f32, size: [u32; 2]) -> Self {
        Self {
            x0: (r.x * scale).clamp(0.0, size[0] as f32),
            y0: (r.y * scale).clamp(0.0, size[1] as f32),
            x1: (r.max_x() * scale).clamp(0.0, size[0] as f32),
            y1: (r.max_y() * scale).clamp(0.0, size[1] as f32),
        }
    }

    /// The texels of level `k` this box covers, two more on every side for the taps' reach,
    /// as a scissor `[x, y, w, h]`.
    fn at_level(self, k: u32, size: [u32; 2]) -> [u32; 4] {
        let d = (1u32 << k) as f32;
        let [w, h] = level_size(size, k);
        let x0 = ((self.x0 / d).floor() - 2.0).max(0.0) as u32;
        let y0 = ((self.y0 / d).floor() - 2.0).max(0.0) as u32;
        let x1 = (((self.x1 / d).ceil() + 2.0) as u32).min(w);
        let y1 = (((self.y1 / d).ceil() + 2.0) as u32).min(h);
        [x0, y0, x1.saturating_sub(x0), y1.saturating_sub(y0)]
    }

    /// The whole pixels it touches, as a scissor.
    fn scissor(self) -> [u32; 4] {
        let (x0, y0) = (self.x0.floor() as u32, self.y0.floor() as u32);
        let (x1, y1) = (self.x1.ceil() as u32, self.y1.ceil() as u32);
        [x0, y0, x1.saturating_sub(x0), y1.saturating_sub(y0)]
    }
}

fn grow(r: Rect, m: f32) -> Rect {
    Rect::new(r.x - m, r.y - m, r.w + 2.0 * m, r.h + 2.0 * m)
}

fn rgba(c: canvas_draw::Rgba) -> [f32; 4] {
    [c.r, c.g, c.b, c.a]
}

/// Where a glass slab reads its backdrop this frame.
#[derive(Clone, Copy, PartialEq)]
enum Source {
    Wallpaper,
    Own,
}

/// One glass layer's part of the frame's plan.
struct GlassSlot {
    key: u32,
    plan: Plan,
    footprint: Px,
    source: Source,
}

/// One layer's part of the frame's plan.
struct Slot {
    moved: bool,
    /// Its look changed this frame: dirt for the glass above it.
    dirty: bool,
    candidate: bool,
    reblur: bool,
    below: u64,
    glass: Option<GlassSlot>,
}

/// A draw on the scene in the pass now open.
enum Draw<'a> {
    List(&'a List, Option<[u32; 4]>),
    Quad(&'a wgpu::RenderPipeline, u32, &'a wgpu::BindGroup),
}

impl Gpu {
    fn glass_pipelines(&self) -> &GlassPipelines {
        self.glass
            .get_or_init(|| GlassPipelines::new(&self.device, &self.adapter))
    }

    /// Build every list of `frame` whose `rev` moved and write its buffers, before a surface
    /// texture is acquired.
    pub(crate) fn prepare_layers(
        &self,
        target: &mut Target,
        frame: &LayerFrame,
        text: &mut TextSystem,
    ) {
        let pipes = self.glass_pipelines();
        let vp = target.viewport;
        // A resize drops every blur: each is a region of a texture the old size.
        if target.glass.as_ref().is_some_and(|g| g.viewport != vp) {
            target.glass = None;
        }
        let g = target
            .glass
            .get_or_insert_with(|| Box::new(Glass::new(&self.device, pipes, vp)));
        // A layer frame is not the retained display list: `redraw` must not repeat that one.
        target.uploaded = false;
        let start = text.atlas().generation();
        let wall = &frame.wallpaper;
        g.wallpaper
            .build(&wall.content, (wall.rev, Rect::ZERO), text, vp);
        for layer in &frame.layers {
            let st = g.layers.entry(layer.id).or_default();
            st.under
                .build(&layer.under, (layer.rev, layer.rect), text, vp);
            st.content
                .build(&layer.content, (layer.rev, layer.rect), text, vp);
        }
        if text.atlas().generation() != start {
            // A list cleared the atlas mid-frame: the lists built before it point at slots
            // reused since, so all are built again without clearing it twice.
            g.wallpaper
                .rebuild(&wall.content, (wall.rev, Rect::ZERO), text, vp);
            for layer in &frame.layers {
                let st = g.layers.entry(layer.id).or_default();
                st.under
                    .rebuild(&layer.under, (layer.rev, layer.rect), text, vp);
                st.content
                    .rebuild(&layer.content, (layer.rev, layer.rect), text, vp);
            }
        }
        let mut uploaded = false;
        let lists = std::iter::once(&mut g.wallpaper).chain(
            g.layers
                .values_mut()
                .flat_map(|st| [&mut st.under, &mut st.content]),
        );
        for list in lists.filter(|l| l.stale) {
            self.upload_buffers(&mut list.buffers, &list.frame);
            list.stale = false;
            uploaded = true;
        }
        if uploaded {
            target.stats.uploads += 1;
        }
        self.upload_atlas(text);
    }

    /// Plan the frame's blurs, encode it onto `view` and submit it.
    pub(crate) fn encode_layers(
        &self,
        target: &mut Target,
        frame: &LayerFrame,
        view: &wgpu::TextureView,
    ) -> Result<(), GpuError> {
        let pipes = self.glass_pipelines();
        let Some(mut g) = target.glass.take() else {
            return Err(GpuError::Surface(
                "layer frame encoded before it was prepared".into(),
            ));
        };
        let vp = target.viewport;
        let size = g.size();
        let scale = vp.scale;
        let wall_dirty = g.wall_rev != Some(frame.wallpaper.rev);

        // Plan, back to front: which glass reads what, and which re-blurs.
        let mut slots: Vec<Slot> = Vec::with_capacity(frame.layers.len());
        let mut below: u64 = 0xcbf2_9ce4_8422_2325;
        for (i, layer) in frame.layers.iter().enumerate() {
            let st = &g.layers[&layer.id];
            let seen = st.seen;
            let moved = seen.is_none_or(|s| s.rect != layer.rect);
            let changed =
                moved || seen.is_some_and(|s| s.rev != layer.rev || s.opacity != layer.opacity);
            let mut slot = Slot {
                moved,
                dirty: changed,
                candidate: false,
                reblur: false,
                below,
                glass: None,
            };
            if let Material::Glass(material) = layer.material {
                let sigma = material.sigma.max(0.0);
                let key = sigma_key(sigma * scale);
                let plan = pipes.plan(key);
                let reach = grow(layer.rect, 3.0 * sigma);
                let over = frame.layers[..i].iter().any(|b| b.rect.intersects(&reach));
                let mut source = Source::Wallpaper;
                if over {
                    let current = st
                        .blur
                        .as_ref()
                        .is_some_and(|b| b.sigma == key && b.rect == layer.rect);
                    let dirt = wall_dirty
                        || slots.iter().zip(&frame.layers).any(|(s, b)| {
                            s.dirty
                                && (b.rect.intersects(&reach)
                                    || g.layers[&b.id]
                                        .seen
                                        .is_some_and(|old| old.rect.intersects(&reach)))
                        });
                    let reordered = seen.is_none_or(|s| s.below != below);
                    slot.candidate = !current || st.pending || dirt || reordered;
                    if current {
                        source = Source::Own;
                    }
                }
                // A layer that re-blurs is dirt for the glass above it, even over the cap: it
                // will re-blur on a later frame.
                slot.dirty |= slot.candidate || (!over && wall_dirty);
                slot.glass = Some(GlassSlot {
                    key,
                    plan,
                    footprint: Px::of(reach, scale, size),
                    source,
                });
            }
            below = (below ^ layer.id.0).wrapping_mul(0x100_0000_01b3);
            slots.push(slot);
        }
        let first_moved = slots.iter().position(|s| s.moved);
        let mut wanted: Vec<usize> = (0..slots.len()).filter(|&i| slots[i].candidate).collect();
        wanted.sort_by_key(|&i| {
            // The spike's order: the moving layers, the layers above one, then the nearest the
            // front. Layers left pending by an earlier frame go before the rest, lowest first, so a
            // settling stack converges: the lowest pending layer is resolved every frame, and the
            // dirt it leaves lies only above it.
            let (class, order) = if slots[i].moved {
                (0, -(i as isize))
            } else if first_moved.is_some_and(|m| i > m) {
                (1, -(i as isize))
            } else if g.layers[&frame.layers[i].id].pending {
                (2, i as isize)
            } else {
                (3, -(i as isize))
            };
            (class, order)
        });
        for &i in wanted.iter().take(frame.blur_cap as usize) {
            slots[i].reblur = true;
            if let Some(glass) = &mut slots[i].glass {
                glass.source = Source::Own;
            }
        }

        // Allocate what the plan needs: wallpaper blurs per sigma, the levels, own caches.
        let mut sigmas: Vec<(u32, Plan)> = slots
            .iter()
            .filter_map(|s| s.glass.as_ref().map(|g| (g.key, g.plan)))
            .collect();
        sigmas.sort_by_key(|(k, _)| *k);
        sigmas.dedup_by_key(|(k, _)| *k);
        g.wall_blurs
            .retain(|k, _| sigmas.iter().any(|(key, _)| key == k));
        let base = level_size(size, BASE);
        let mut deepest = BASE;
        for &(key, plan) in &sigmas {
            let entry = g.wall_blurs.entry(key).or_insert_with(|| {
                let tex = Tex::new(
                    &self.device,
                    pipes,
                    "wallpaper blur",
                    base,
                    pipes.chain_format,
                );
                (tex, None)
            });
            if wall_dirty || entry.1.is_none() {
                entry.1 = None;
                deepest = deepest.max(plan.deepest);
            }
        }
        for (slot, layer) in slots.iter().zip(&frame.layers) {
            let Some(glass) = slot.glass.as_ref().filter(|_| slot.reblur) else {
                continue;
            };
            deepest = deepest.max(glass.plan.deepest);
            let st = g
                .layers
                .get_mut(&layer.id)
                .expect("prepared with the frame");
            if st.blur.is_none() {
                st.blur = Some(Cached {
                    tex: Tex::new(&self.device, pipes, "layer blur", base, pipes.chain_format),
                    sigma: glass.key,
                    rect: layer.rect,
                });
            }
        }
        for k in BASE..=deepest {
            if g.levels[k as usize].is_none() {
                let tex = Tex::new(
                    &self.device,
                    pipes,
                    "blur level",
                    level_size(size, k),
                    pipes.chain_format,
                );
                g.levels[k as usize] = Some(tex);
            }
        }
        let paths = g.wallpaper.frame.has_paths()
            || frame.layers.iter().any(|l| {
                let st = &g.layers[&l.id];
                st.under.frame.has_paths() || st.content.frame.has_paths()
            });
        if paths && g.msaa.is_none() {
            g.msaa = Some(self.msaa_attachment(size));
        }
        let most = 1 + CHAIN_PASSES * (sigmas.len() + frame.layers.len()) + 3 * frame.layers.len();
        let need = most as u64 * g.stride;
        if g.uniforms.as_ref().is_none_or(|(_, cap, _)| *cap < need) {
            let capacity = need.next_power_of_two().max(4096);
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("glass params"),
                size: capacity,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("glass params"),
                layout: &pipes.params_layout,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &buffer,
                        offset: 0,
                        size: wgpu::BufferSize::new(size_of::<Params>() as u64),
                    }),
                }],
            });
            g.uniforms = Some((buffer, capacity, bind));
        }

        // Encode.
        self.write_cameras(target, None, false);
        let mut staging = std::mem::take(&mut g.staging);
        staging.clear();
        let mut wallpaper_blurs = 0;
        let mut blur_passes = 0;
        let command = {
            let g = &*g;
            let Some((_, _, params)) = &g.uniforms else {
                unreachable!("allocated above")
            };
            let mut pass = Passes {
                gpu: self,
                pipes,
                glass: g,
                cameras: &target.cameras,
                params,
                staging: &mut staging,
                stride: g.stride,
                vp,
                encoder: self
                    .device
                    .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                        label: Some("layer frame"),
                    }),
                draws: Vec::new(),
                clear: None,
            };
            // The wallpaper opens the scene's first batch instead of a pass of its own: on Metal
            // every render pass is two command buffers. One with paths still draws multisampled.
            if g.wallpaper.frame.has_paths() {
                pass.list(&g.wallpaper, &g.scene, g.wallpaper.frame.clear, None);
            } else {
                pass.clear = Some(g.wallpaper.frame.clear);
                pass.draws.push(Draw::List(&g.wallpaper, None));
            }
            let full = Px {
                x0: 0.0,
                y0: 0.0,
                x1: size[0] as f32,
                y1: size[1] as f32,
            };
            for &(key, plan) in &sigmas {
                let (tex, rev) = &g.wall_blurs[&key];
                if rev.is_none() {
                    // The chain reads the wallpaper from the scene.
                    pass.flush();
                    pass.chain(plan, full, full, tex);
                    wallpaper_blurs += 1;
                }
            }
            for (slot, layer) in slots.iter().zip(&frame.layers) {
                let st = &g.layers[&layer.id];
                let rect = Px::of(layer.rect, scale, size);
                if let Some(glass) = &slot.glass
                    && slot.reblur
                    && let Some(cached) = &st.blur
                {
                    pass.flush();
                    pass.chain(glass.plan, glass.footprint, rect, &cached.tex);
                    blur_passes += 1;
                }
                if layer.opacity <= 0.0 {
                    continue;
                }
                let opacity = layer.opacity.min(1.0);
                let quad = [
                    layer.rect.x * scale,
                    layer.rect.y * scale,
                    layer.rect.w * scale,
                    layer.rect.h * scale,
                ];
                let radius = layer.radius.max(0.0) * scale;
                if !st.under.is_empty() {
                    if opacity >= 1.0 && !st.under.frame.has_paths() {
                        pass.draws.push(Draw::List(&st.under, None));
                    } else {
                        pass.flush();
                        pass.list(&st.under, &g.scratch, [0.0; 4], None);
                        pass.quad(
                            &pipes.group,
                            &g.scratch,
                            Params {
                                rect: [0.0, 0.0, size[0] as f32, size[1] as f32],
                                opacity,
                                mode: 0.0,
                                ..pass.base()
                            },
                        );
                    }
                }
                let slab = Params {
                    rect: quad,
                    radius,
                    opacity,
                    ..pass.base()
                };
                match (layer.material, &slot.glass) {
                    (Material::Glass(m), Some(glass)) => {
                        let tex = match glass.source {
                            Source::Own => st.blur.as_ref().map(|b| &b.tex),
                            Source::Wallpaper => None,
                        }
                        .unwrap_or(&g.wall_blurs[&glass.key].0);
                        pass.quad(
                            &pipes.slab,
                            tex,
                            Params {
                                tint_top: rgba(m.tint_top),
                                tint_bottom: rgba(m.tint_bottom),
                                blur_inv: tex.inv(),
                                saturate: m.saturate,
                                mode: 0.0,
                                ..slab
                            },
                        );
                    }
                    (Material::Solid(c), _) => {
                        // A solid slab reads no backdrop; the scratch only fills the binding.
                        pass.quad(
                            &pipes.slab,
                            &g.scratch,
                            Params {
                                solid: rgba(c),
                                mode: 1.0,
                                ..slab
                            },
                        );
                    }
                    _ => {}
                }
                if !st.content.is_empty() {
                    let clip = rect.scissor();
                    if opacity >= 1.0 && radius <= 0.0 && !st.content.frame.has_paths() {
                        pass.draws.push(Draw::List(&st.content, Some(clip)));
                    } else {
                        pass.flush();
                        pass.list(&st.content, &g.scratch, [0.0; 4], Some(clip));
                        pass.quad(&pipes.group, &g.scratch, Params { mode: 1.0, ..slab });
                    }
                }
            }
            pass.finish(view);
            pass.encoder.finish()
        };
        if let Some((buffer, _, _)) = &g.uniforms
            && !staging.is_empty()
        {
            self.queue.write_buffer(buffer, 0, &staging);
        }
        g.staging = staging;
        self.queue.submit([command]);
        target.stats.encodes += 1;

        // Record what this frame was, for the next one's plan.
        for (key, _) in &sigmas {
            if let Some(entry) = g.wall_blurs.get_mut(key) {
                entry.1 = Some(frame.wallpaper.rev);
            }
        }
        g.wall_rev = Some(frame.wallpaper.rev);
        let present: HashSet<LayerId> = frame.layers.iter().map(|l| l.id).collect();
        for (slot, layer) in slots.iter().zip(&frame.layers) {
            let st = g
                .layers
                .get_mut(&layer.id)
                .expect("prepared with the frame");
            st.seen = Some(Seen {
                rect: layer.rect,
                rev: layer.rev,
                opacity: layer.opacity,
                below: slot.below,
            });
            match &slot.glass {
                Some(glass) if slot.reblur => {
                    if let Some(cached) = &mut st.blur {
                        cached.sigma = glass.key;
                        cached.rect = layer.rect;
                    }
                    st.pending = false;
                }
                Some(_) if slot.candidate => st.pending = true,
                // Over nothing: the wallpaper's blur serves it, so its own is freed.
                Some(glass) if glass.source == Source::Wallpaper => {
                    st.blur = None;
                    st.pending = false;
                }
                Some(_) => {}
                None => {
                    st.blur = None;
                    st.pending = false;
                }
            }
        }
        g.layers.retain(|id, _| present.contains(id));
        target.stats.blur_passes = blur_passes;
        target.stats.wallpaper_blurs = wallpaper_blurs;
        target.stats.cached_blurs = g.layers.values().filter(|s| s.blur.is_some()).count() as u32;
        target.glass = Some(g);
        Ok(())
    }

    fn msaa_attachment(&self, size: [u32; 2]) -> wgpu::TextureView {
        self.device
            .create_texture(&wgpu::TextureDescriptor {
                label: Some("glass msaa"),
                size: wgpu::Extent3d {
                    width: size[0],
                    height: size[1],
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: PATH_SAMPLES,
                dimension: wgpu::TextureDimension::D2,
                format: FORMAT,
                // Cleared, resolved and never stored: tile memory only on Apple GPUs.
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TRANSIENT_ATTACHMENT,
                view_formats: &[],
            })
            .create_view(&wgpu::TextureViewDescriptor::default())
    }
}

/// One layer frame's command encoder, with the scene draws batched into as few passes as the
/// blurs between them allow.
struct Passes<'a> {
    gpu: &'a Gpu,
    pipes: &'a GlassPipelines,
    glass: &'a Glass,
    cameras: &'a [Globals; 4],
    params: &'a wgpu::BindGroup,
    staging: &'a mut Vec<u8>,
    stride: u64,
    vp: Viewport,
    encoder: wgpu::CommandEncoder,
    draws: Vec<Draw<'a>>,
    /// The wallpaper's clear, while its batch has not reached the scene: the first pass over
    /// the scene clears it to this.
    clear: Option<[f64; 4]>,
}

impl<'a> Passes<'a> {
    /// The parameters every pass shares.
    fn base(&self) -> Params {
        Params {
            viewport: [self.vp.width_px as f32, self.vp.height_px as f32],
            ..Params::default()
        }
    }

    /// Stage `params` and return its dynamic offset.
    fn stage(&mut self, params: Params) -> u32 {
        let at = self.staging.len();
        let offset = at as u64;
        self.staging.resize(at + self.stride as usize, 0);
        self.staging[at..at + size_of::<Params>()].copy_from_slice(bytemuck::bytes_of(&params));
        offset as u32
    }

    fn quad(&mut self, pipeline: &'a wgpu::RenderPipeline, src: &'a Tex, params: Params) {
        let offset = self.stage(params);
        self.draws.push(Draw::Quad(pipeline, offset, &src.source));
    }

    /// Draw the batched scene draws in one pass over what the scene holds (cleared to the
    /// wallpaper's colour when its batch is the first to reach it).
    fn flush(&mut self) {
        if self.draws.is_empty() {
            return;
        }
        let load = match self.clear.take() {
            Some(c) => clear_to(c),
            None => wgpu::LoadOp::Load,
        };
        let glass = self.glass;
        self.draw_onto(&glass.scene.view, load, None);
    }

    /// End the frame on `view` in one pass. The scene is copied there and the draws still
    /// batched land on the copy: no glass reads the scene after them, and the blit is an exact
    /// copy into the same format, so blending them onto `view` gives the pixels blending them
    /// onto the scene would. A frame whose scene was never drawn (no chain, no scratch list)
    /// is drawn straight onto `view`, its wallpaper's clear first.
    fn finish(&mut self, view: &wgpu::TextureView) {
        match self.clear.take() {
            Some(c) => self.draw_onto(view, clear_to(c), None),
            None => {
                let at = self.stage(self.base());
                self.draw_onto(view, clear_to([0.0; 4]), Some(at));
            }
        }
    }

    /// One pass onto `view`: the scene's blit first when `blit` holds its parameters, then
    /// every batched draw.
    fn draw_onto(
        &mut self,
        view: &wgpu::TextureView,
        load: wgpu::LoadOp<wgpu::Color>,
        blit: Option<u32>,
    ) {
        let (w, h) = (self.vp.width_px, self.vp.height_px);
        let mut pass = self.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("glass scene"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        if let Some(at) = blit {
            pass.set_pipeline(&self.pipes.blit);
            pass.set_bind_group(0, self.params, &[at]);
            pass.set_bind_group(1, &self.glass.scene.source, &[]);
            pass.draw(0..3, 0..1);
        }
        for draw in self.draws.drain(..) {
            match draw {
                Draw::List(list, clip) => self.gpu.draw_batches(
                    &mut pass,
                    &self.gpu.single,
                    self.cameras,
                    &list.frame,
                    &list.buffers,
                    self.vp,
                    clip,
                ),
                Draw::Quad(pipeline, offset, src) => {
                    pass.set_pipeline(pipeline);
                    pass.set_bind_group(0, self.params, &[offset]);
                    pass.set_bind_group(1, src, &[]);
                    pass.set_scissor_rect(0, 0, w, h);
                    pass.draw(0..4, 0..1);
                }
            }
        }
    }

    /// Draw `list` alone into `dst`, cleared to `clear` first: 4x multisampled and resolved
    /// when it has paths.
    fn list(&mut self, list: &List, dst: &Tex, clear: [f64; 4], clip: Option<[u32; 4]>) {
        let [r, g, b, a] = clear;
        let load = wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a });
        let paths = list.frame.has_paths();
        let attachment = match (&self.glass.msaa, paths) {
            (Some(msaa), true) => wgpu::RenderPassColorAttachment {
                view: msaa,
                depth_slice: None,
                resolve_target: Some(&dst.view),
                ops: wgpu::Operations {
                    load,
                    store: wgpu::StoreOp::Discard,
                },
            },
            _ => wgpu::RenderPassColorAttachment {
                view: &dst.view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load,
                    store: wgpu::StoreOp::Store,
                },
            },
        };
        let pipes = if paths {
            self.gpu.multisampled()
        } else {
            &self.gpu.single
        };
        let mut pass = self.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("glass list"),
            color_attachments: &[Some(attachment)],
            ..Default::default()
        });
        self.gpu.draw_batches(
            &mut pass,
            pipes,
            self.cameras,
            &list.frame,
            &list.buffers,
            self.vp,
            clip,
        );
    }

    /// One pass of the chain from `src` into `dst` under `scissor` (in `dst`'s texels).
    fn step(
        &mut self,
        pipeline: &wgpu::RenderPipeline,
        src: &Tex,
        dst: &Tex,
        scissor: [u32; 4],
        ratio: f32,
        offset: f32,
    ) {
        let [x, y, w, h] = scissor;
        if w == 0 || h == 0 {
            return;
        }
        let at = self.stage(Params {
            src_inv: src.inv(),
            ratio,
            offset,
            ..self.base()
        });
        let mut pass = self.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("blur"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &dst.view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, self.params, &[at]);
        pass.set_bind_group(1, &src.source, &[]);
        pass.set_scissor_rect(x, y, w, h);
        pass.draw(0..3, 0..1);
    }

    /// Blur the scene under `footprint` into `dst`'s `out` region: the box to 1/4, down to the
    /// plan's depth and back up. Each level is written only where the footprint reaches.
    fn chain(&mut self, plan: Plan, footprint: Px, out: Px, dst: &Tex) {
        let g = self.glass;
        let pipes = self.pipes;
        let size = g.size();
        let level = |k: u32| {
            g.levels[k as usize]
                .as_ref()
                .expect("levels allocated for the plan")
        };
        let o = plan.offset;
        self.step(
            &pipes.quarter,
            &g.scene,
            level(BASE),
            footprint.at_level(BASE, size),
            4.0,
            0.0,
        );
        for k in BASE + 1..=plan.deepest {
            self.step(
                &pipes.down,
                level(k - 1),
                level(k),
                footprint.at_level(k, size),
                2.0,
                o,
            );
        }
        for k in (BASE..plan.deepest).rev() {
            let (target, region) = if k == BASE {
                (dst, out.at_level(BASE, size))
            } else {
                (level(k), footprint.at_level(k, size))
            };
            self.step(&pipes.up, level(k + 1), target, region, 0.5, o);
        }
    }
}

/// A pass's load that clears to `c`.
fn clear_to([r, g, b, a]: [f64; 4]) -> wgpu::LoadOp<wgpu::Color> {
    wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a })
}
