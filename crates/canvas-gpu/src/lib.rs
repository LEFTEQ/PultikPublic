//! The one renderer: wgpu device, CAMetalLayer surfaces, instanced pipelines (SDF rects, glyphs, cells, images).
//!
//! One [`Gpu`] (instance, adapter, device, queue, the pipelines and the glyph atlas
//! textures) is shared by every [`Target`]: a host's surfaces (a canvas, an input bar, a
//! timeline) are separate targets on one device. A frame is a [`frame::Frame`] built on the
//! CPU from a display list, then one render pass. Atlas pages upload only the rects written
//! since the last frame; the host renders only when something is dirty, so an idle UI does no
//! GPU work.
//!
//! A target keeps its last frame's instances on the GPU: [`Gpu::set_camera`] and
//! [`Gpu::redraw`] move a camera layer (a pan, a pinch, a dash's flow) by rewriting two
//! uniforms, with no rebuild, no upload and no glyph. A frame that draws paths renders in a 4×
//! multisampled pass ([`PATH_SAMPLES`], memoryless on Apple GPUs) resolved into the target;
//! every other frame stays single-sampled.

pub mod frame;
pub mod retained;
mod tess;

pub use retained::{ChunkId, RetainedStats};

pub use frame::{Batch, Frame, Pipeline, Viewport};

use canvas_draw::{Camera, DisplayList, Follow};
use canvas_text::{MAX_ALPHA_PAGES, MAX_COLOR_PAGES, PAGE_SIZE, PageKind, TextSystem};
use frame::{CellInstance, GlyphInstance, PathVertex, RectInstance};
#[cfg(target_vendor = "apple")]
use std::ffi::c_void;
#[cfg(not(target_arch = "wasm32"))]
use std::future::Future;
use std::sync::OnceLock;
#[cfg(not(target_arch = "wasm32"))]
use std::task::{Context, Poll, Waker};
#[cfg(not(target_arch = "wasm32"))]
use std::time::Instant;
#[cfg(target_arch = "wasm32")]
use web_time::Instant;

/// Samples of the pass a frame with paths draws in (D18).
pub const PATH_SAMPLES: u32 = 4;

/// Every target renders in this format (always supported by CAMetalLayer); colours are
/// written gamma-encoded, so blending happens in sRGB space like AppKit's.
#[cfg(not(target_arch = "wasm32"))]
pub const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Bgra8Unorm;
#[cfg(target_arch = "wasm32")]
pub const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

#[derive(Debug, thiserror::Error)]
pub enum GpuError {
    #[error("no usable GPU adapter: {0}")]
    Adapter(String),
    #[error("could not create the GPU device: {0}")]
    Device(String),
    #[error("surface: {0}")]
    Surface(String),
    #[error("readback: {0}")]
    Readback(String),
    #[error("waiting for the GPU: {0}")]
    Wait(String),
}

/// How the surface composites over what is behind it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compositing {
    /// The canvas: an opaque layer.
    Opaque,
    /// The bar: transparent inside the host's glass.
    Transparent,
}

/// What a [`Gpu::render`] call did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameOutcome {
    Presented,
    /// Occluded, timed out or reconfigured: nothing was drawn; render again next tick.
    Skipped,
}

/// Wait for a future that wgpu's native backends resolve without a reactor.
#[cfg(not(target_arch = "wasm32"))]
fn block_on<F: Future>(fut: F) -> F::Output {
    let mut fut = std::pin::pin!(fut);
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
}

#[derive(Clone)]
struct GrowBuffer {
    buffer: wgpu::Buffer,
    capacity: u64,
}

#[derive(Default, Clone)]
struct Buffers {
    rects: Option<GrowBuffer>,
    glyphs: Option<GrowBuffer>,
    cells: Option<GrowBuffer>,
    path_vertices: Option<GrowBuffer>,
    path_indices: Option<GrowBuffer>,
}

/// One uniform block (`Globals` in the shaders): viewport, clock, camera.
struct Globals {
    buffer: wgpu::Buffer,
    bind: wgpu::BindGroup,
}

/// What a target did, for tests and diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TargetStats {
    /// Frames whose instances were written to the GPU.
    pub uploads: u64,
    /// Render passes encoded (an upload, or a redraw of the retained frame).
    pub encodes: u64,
}

/// CPU wall time of the most recent submission, excluding offscreen fences.
#[derive(Debug, Clone, Copy, Default)]
pub struct CpuFrameProfile {
    pub uniforms_ms: f64,
    pub commands_ms: f64,
    pub finish_ms: f64,
    pub submit_ms: f64,
    pub acquire_ms: f64,
    pub present_ms: f64,
    pub rebuild_ms: f64,
    pub upload_ms: f64,
    pub bundle_ms: f64,
}

/// A render destination: a configured surface, or none (offscreen capture).
pub struct Target {
    surface: Option<wgpu::Surface<'static>>,
    config: Option<wgpu::SurfaceConfiguration>,
    viewport: Viewport,
    /// One uniform block per [`Follow`] (by its index): identity outside a camera layer, the
    /// camera on x, on y, on both.
    cameras: [Globals; 4],
    camera_data: [Option<[f32; 8]>; 4],
    camera: Camera,
    clock: Instant,
    frozen_clock: Option<f32>,
    buffers: Buffers,
    retained: retained::Scene,
    /// The multisampled colour attachment of a frame with paths, and its size.
    msaa: Option<(wgpu::TextureView, [u32; 2])>,
    /// The last frame's instance arrays, rebuilt in place so steady frames allocate nothing.
    frame: Frame,
    /// The GPU buffers hold `frame`: a redraw may re-encode it as it is.
    uploaded: bool,
    stats: TargetStats,
    profile: CpuFrameProfile,
}

impl Target {
    pub fn viewport(&self) -> Viewport {
        self.viewport
    }

    pub fn camera(&self) -> Camera {
        self.camera
    }

    pub fn cpu_profile(&self) -> CpuFrameProfile {
        self.profile
    }

    pub fn stats(&self) -> TargetStats {
        self.stats
    }

    /// The last frame flows (a dash with a speed): its host keeps redrawing while it shows.
    pub fn animating(&self) -> bool {
        if self.retained.active() {
            self.retained.animated()
        } else {
            self.frame.animated
        }
    }

    /// The last frame built for this target.
    pub fn frame(&self) -> &Frame {
        &self.frame
    }

    /// Hold the shader clock at `seconds` (`None`: follow the wall clock), for goldens.
    pub fn freeze_clock(&mut self, seconds: Option<f32>) {
        self.frozen_clock = seconds;
    }

    fn time(&self) -> f32 {
        self.frozen_clock
            .unwrap_or_else(|| (self.clock.elapsed().as_secs_f64() % 3600.0) as f32)
    }
}

/// A colour texture to draw built frames into without presenting: what
/// `cargo xtask scroll-bench --gpu` times (upload, encode, submit, wait), by hand, never in
/// CI (D12), and what offscreen goldens read back.
pub struct Offscreen {
    target: Target,
    texture: wgpu::Texture,
    view: wgpu::TextureView,
}

impl Offscreen {
    pub fn target(&self) -> &Target {
        &self.target
    }

    pub fn target_mut(&mut self) -> &mut Target {
        &mut self.target
    }
}

/// The pipelines of one sample count; only the multisampled set draws paths.
struct Pipelines {
    quad: wgpu::RenderPipeline,
    rect: wgpu::RenderPipeline,
    glyph: wgpu::RenderPipeline,
    cell: wgpu::RenderPipeline,
    path: Option<wgpu::RenderPipeline>,
}

pub struct Gpu {
    // Surfaces are created from it (CAMetalLayer targets are Apple-only for now).
    #[cfg_attr(not(target_vendor = "apple"), allow(dead_code))]
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    single: Pipelines,
    /// Built on the first frame with paths: a host that never draws one never pays for it.
    multisampled: OnceLock<Pipelines>,
    globals_layout: wgpu::BindGroupLayout,
    atlas_layout: wgpu::BindGroupLayout,
    atlas_bind: wgpu::BindGroup,
    alpha_atlas: wgpu::Texture,
    color_atlas: wgpu::Texture,
}

/// The rect, glyph and cell pipelines at `samples`, and at [`PATH_SAMPLES`] the path pipeline.
fn pipelines(
    device: &wgpu::Device,
    globals_layout: &wgpu::BindGroupLayout,
    atlas_layout: &wgpu::BindGroupLayout,
    samples: u32,
) -> Pipelines {
    let pipeline = |name: &str,
                    source: &str,
                    layouts: &[Option<&wgpu::BindGroupLayout>],
                    buffer: wgpu::VertexBufferLayout<'_>,
                    topology: wgpu::PrimitiveTopology| {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(name),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some(name),
            bind_group_layouts: layouts,
            ..Default::default()
        });
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(name),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs"),
                compilation_options: Default::default(),
                buffers: &[Some(buffer)],
            },
            primitive: wgpu::PrimitiveState {
                topology,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState {
                count: samples,
                ..Default::default()
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: FORMAT,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview_mask: None,
            cache: None,
        })
    };
    let instanced = |stride: usize, attributes| wgpu::VertexBufferLayout {
        array_stride: stride as u64,
        step_mode: wgpu::VertexStepMode::Instance,
        attributes,
    };
    let strip = wgpu::PrimitiveTopology::TriangleStrip;
    Pipelines {
        quad: pipeline(
            "retained quad", include_str!("../shaders/quad.wgsl"),
            &[Some(globals_layout),Some(atlas_layout)],
            instanced(size_of::<retained::QuadInstance>(), &wgpu::vertex_attr_array![0=>Float32x4,1=>Float32x4,2=>Float32x4,3=>Float32x4,4=>Float32x4,5=>Float32x4,6=>Uint32x2]),strip,
        ),
        rect: pipeline(
            "rect",
            include_str!("../shaders/rect.wgsl"),
            &[Some(globals_layout)],
            instanced(
                size_of::<RectInstance>(),
                &wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32x4, 3 => Float32x4, 4 => Float32x4],
            ),
            strip,
        ),
        glyph: pipeline(
            "glyph",
            include_str!("../shaders/glyph.wgsl"),
            &[Some(globals_layout), Some(atlas_layout)],
            instanced(
                size_of::<GlyphInstance>(),
                &wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4, 2 => Float32x4, 3 => Uint32x2, 4 => Float32x2],
            ),
            strip,
        ),
        cell: pipeline(
            "cell",
            include_str!("../shaders/cell.wgsl"),
            &[Some(globals_layout)],
            instanced(
                size_of::<CellInstance>(),
                &wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4],
            ),
            strip,
        ),
        path: (samples == PATH_SAMPLES).then(|| {
            pipeline(
                "path",
                include_str!("../shaders/path.wgsl"),
                &[Some(globals_layout)],
                wgpu::VertexBufferLayout {
                    array_stride: size_of::<PathVertex>() as u64,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32, 2 => Unorm8x4, 3 => Float32x4],
                },
                wgpu::PrimitiveTopology::TriangleList,
            )
        }),
    }
}

fn px(points: f64, scale: f64) -> u32 {
    (points * scale).round().max(1.0) as u32
}

impl Gpu {
    /// Create the instance, a high-performance adapter and the device. Blocks briefly.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn new() -> Result<Self, GpuError> {
        block_on(Self::new_async())
    }

    /// Browser-safe initialization: yields while the adapter and device are requested.
    /// Without WebGPU, wgpu selects its WebGL2 backend.
    pub async fn new_async() -> Result<Self, GpuError> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        Self::initialize(instance, None).await
    }

    async fn initialize(
        instance: wgpu::Instance,
        surface: Option<&wgpu::Surface<'_>>,
    ) -> Result<Self, GpuError> {
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: surface,
                ..Default::default()
            })
            .await
            .map_err(|e| GpuError::Adapter(e.to_string()))?;
        #[cfg(not(target_arch = "wasm32"))]
        let limits = wgpu::Limits::downlevel_defaults();
        #[cfg(target_arch = "wasm32")]
        let limits = wgpu::Limits::downlevel_webgl2_defaults();
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("canvas"),
                required_limits: limits.using_resolution(adapter.limits()),
                ..Default::default()
            })
            .await
            .map_err(|e| GpuError::Device(e.to_string()))?;
        device.on_uncaptured_error(std::sync::Arc::new(|e: wgpu::Error| {
            tracing::error!(error = %e, "wgpu validation error");
        }));

        let globals_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("globals"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: // The path pass cuts dashes by the clock per fragment.
                wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let tex_entry = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2Array,
                multisampled: false,
            },
            count: None,
        };
        let atlas_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("atlas"),
            entries: &[
                tex_entry(0),
                tex_entry(1),
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let atlas_texture = |label, format, layers: usize| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d {
                    width: PAGE_SIZE,
                    height: PAGE_SIZE,
                    depth_or_array_layers: layers as u32,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            })
        };
        let alpha_atlas =
            atlas_texture("alpha-atlas", wgpu::TextureFormat::R8Unorm, MAX_ALPHA_PAGES);
        let color_atlas = atlas_texture(
            "color-atlas",
            wgpu::TextureFormat::Rgba8Unorm,
            MAX_COLOR_PAGES,
        );
        let array_view = |t: &wgpu::Texture| {
            t.create_view(&wgpu::TextureViewDescriptor {
                dimension: Some(wgpu::TextureViewDimension::D2Array),
                ..Default::default()
            })
        };
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("atlas"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let atlas_bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("atlas"),
            layout: &atlas_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&array_view(&alpha_atlas)),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&array_view(&color_atlas)),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&sampler),
                },
            ],
        });

        let single = pipelines(&device, &globals_layout, &atlas_layout, 1);

        Ok(Self {
            instance,
            adapter,
            device,
            queue,
            single,
            multisampled: OnceLock::new(),
            globals_layout,
            atlas_layout,
            atlas_bind,
            alpha_atlas,
            color_atlas,
        })
    }

    /// Create a device and its browser surface together. WebGL2 requires the adapter
    /// to be selected for this canvas; WebGPU is attempted first, then WebGL2.
    #[cfg(target_arch = "wasm32")]
    pub async fn for_canvas(
        canvas: web_sys::HtmlCanvasElement,
        scale: f32,
    ) -> Result<(Self, Target), GpuError> {
        let mut errors = Vec::new();
        for backend in [wgpu::Backends::BROWSER_WEBGPU, wgpu::Backends::GL] {
            let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
            descriptor.backends = backend;
            let instance = wgpu::Instance::new(descriptor);
            // Do not claim a canvas context until WebGPU has supplied a usable device:
            // a canvas that already owns a webgpu context cannot later become WebGL2.
            let (gpu, surface) = if backend == wgpu::Backends::BROWSER_WEBGPU {
                let gpu = match Self::initialize(instance, None).await {
                    Ok(g) => g,
                    Err(e) => {
                        errors.push(e.to_string());
                        continue;
                    }
                };
                let surface = gpu
                    .instance
                    .create_surface(wgpu::SurfaceTarget::Canvas(canvas.clone()))
                    .map_err(|e| GpuError::Surface(e.to_string()))?;
                (gpu, surface)
            } else {
                let surface =
                    match instance.create_surface(wgpu::SurfaceTarget::Canvas(canvas.clone())) {
                        Ok(s) => s,
                        Err(e) => {
                            errors.push(e.to_string());
                            continue;
                        }
                    };
                let gpu = match Self::initialize(instance, Some(&surface)).await {
                    Ok(g) => g,
                    Err(e) => {
                        errors.push(e.to_string());
                        continue;
                    }
                };
                (gpu, surface)
            };
            let caps = surface.get_capabilities(&gpu.adapter);
            if !caps.formats.contains(&FORMAT) {
                errors.push(format!("browser surface does not support {FORMAT:?}"));
                continue;
            }
            let viewport = Viewport {
                width_px: canvas.width().max(1),
                height_px: canvas.height().max(1),
                scale,
            };
            let config = wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: FORMAT,
                color_space: Default::default(),
                width: viewport.width_px,
                height: viewport.height_px,
                present_mode: wgpu::PresentMode::Fifo,
                desired_maximum_frame_latency: 2,
                alpha_mode: wgpu::CompositeAlphaMode::Opaque,
                view_formats: vec![],
            };
            surface.configure(&gpu.device, &config);
            let mut target = gpu.target(viewport);
            target.surface = Some(surface);
            target.config = Some(config);
            return Ok((gpu, target));
        }
        Err(GpuError::Adapter(errors.join("; ")))
    }

    /// The adapter's name and backend, for diagnostics.
    pub fn adapter_info(&self) -> String {
        let info = self.adapter.get_info();
        format!("{} ({:?})", info.name, info.backend)
    }

    fn multisampled(&self) -> &Pipelines {
        self.multisampled.get_or_init(|| {
            pipelines(
                &self.device,
                &self.globals_layout,
                &self.atlas_layout,
                PATH_SAMPLES,
            )
        })
    }

    fn globals(&self, label: &str) -> Globals {
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some(label),
            size: 32,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(label),
            layout: &self.globals_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: buffer.as_entire_binding(),
            }],
        });
        Globals { buffer, bind }
    }

    fn target(&self, viewport: Viewport) -> Target {
        Target {
            surface: None,
            config: None,
            viewport,
            cameras: [
                self.globals("globals"),
                self.globals("camera x"),
                self.globals("camera y"),
                self.globals("camera"),
            ],
            camera_data: [None; 4],
            camera: Camera::IDENTITY,
            clock: Instant::now(),
            frozen_clock: None,
            buffers: Buffers::default(),
            retained: retained::Scene::default(),
            msaa: None,
            frame: Frame::default(),
            uploaded: false,
            stats: TargetStats::default(),
            profile: CpuFrameProfile::default(),
        }
    }

    /// A surface on the host's `CAMetalLayer`, sized in points at `scale`.
    ///
    /// # Safety
    /// `layer` must be a valid `CAMetalLayer*` that outlives the returned [`Target`].
    #[cfg(target_vendor = "apple")]
    pub unsafe fn create_layer_target(
        &self,
        layer: *mut c_void,
        compositing: Compositing,
        width: f64,
        height: f64,
        scale: f64,
    ) -> Result<Target, GpuError> {
        // SAFETY: forwarded from the caller's contract.
        let surface = unsafe {
            self.instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer))
        }
        .map_err(|e| GpuError::Surface(e.to_string()))?;
        let caps = surface.get_capabilities(&self.adapter);
        if !caps.formats.contains(&FORMAT) {
            return Err(GpuError::Surface(format!(
                "{FORMAT:?} unsupported; surface offers {:?}",
                caps.formats
            )));
        }
        let alpha_mode = match compositing {
            Compositing::Opaque => wgpu::CompositeAlphaMode::Opaque,
            Compositing::Transparent => [
                wgpu::CompositeAlphaMode::PreMultiplied,
                wgpu::CompositeAlphaMode::PostMultiplied,
            ]
            .into_iter()
            .find(|m| caps.alpha_modes.contains(m))
            .unwrap_or(wgpu::CompositeAlphaMode::Auto),
        };
        let viewport = Viewport {
            width_px: px(width, scale),
            height_px: px(height, scale),
            scale: scale as f32,
        };
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: FORMAT,
            color_space: Default::default(),
            width: viewport.width_px,
            height: viewport.height_px,
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode,
            view_formats: vec![],
        };
        surface.configure(&self.device, &config);
        let mut target = self.target(viewport);
        target.surface = Some(surface);
        target.config = Some(config);
        Ok(target)
    }

    /// Present in step with the display (`vsync`, the default: `Fifo`, the layer's display sync)
    /// or as soon as a frame is done (`Immediate`), which frees a drawable without waiting for the
    /// next refresh. A host that paces its own frames by a display link can run without.
    pub fn set_vsync(&self, target: &mut Target, vsync: bool) {
        if let (Some(surface), Some(config)) = (&target.surface, &mut target.config) {
            config.present_mode = if vsync {
                wgpu::PresentMode::Fifo
            } else {
                wgpu::PresentMode::Immediate
            };
            surface.configure(&self.device, config);
        }
    }

    /// Resize a target (points at `scale`); reconfigures its surface.
    pub fn resize(&self, target: &mut Target, width: f64, height: f64, scale: f64) {
        target.viewport = Viewport {
            width_px: px(width, scale),
            height_px: px(height, scale),
            scale: scale as f32,
        };
        if let (Some(surface), Some(config)) = (&target.surface, &mut target.config) {
            config.width = target.viewport.width_px;
            config.height = target.viewport.height_px;
            surface.configure(&self.device, config);
        }
    }

    fn upload_atlas(&self, text: &mut TextSystem) {
        let uploads = text.atlas_mut().take_uploads();
        for up in uploads {
            let Some(page) = text.atlas().page(up.kind, up.page) else {
                continue;
            };
            let bpp = page.bytes_per_pixel() as u32;
            let texture = match up.kind {
                PageKind::Alpha => &self.alpha_atlas,
                PageKind::Color => &self.color_atlas,
            };
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: up.rect.x,
                        y: up.rect.y,
                        z: up.page as u32,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                &page.data[((up.rect.y * PAGE_SIZE + up.rect.x) * bpp) as usize..],
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(PAGE_SIZE * bpp),
                    rows_per_image: None,
                },
                wgpu::Extent3d {
                    width: up.rect.w,
                    height: up.rect.h,
                    depth_or_array_layers: 1,
                },
            );
        }
    }

    fn write_buffer<T: bytemuck::Pod>(
        &self,
        slot: &mut Option<GrowBuffer>,
        data: &[T],
        usage: wgpu::BufferUsages,
    ) {
        if data.is_empty() {
            return;
        }
        let bytes: &[u8] = bytemuck::cast_slice(data);
        let need = bytes.len() as u64;
        if slot.as_ref().is_none_or(|b| b.capacity < need) {
            let capacity = need.next_power_of_two().max(4096);
            *slot = Some(GrowBuffer {
                buffer: self.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("instances"),
                    size: capacity,
                    usage: usage | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                }),
                capacity,
            });
        }
        if let Some(b) = slot {
            self.queue.write_buffer(&b.buffer, 0, bytes);
        }
    }

    /// Write `frame`'s instances and path geometry into the target's buffers.
    fn upload(&self, target: &mut Target, frame: &Frame) {
        self.upload_buffers(&mut target.buffers, frame);
        target.stats.uploads += 1;
    }

    fn upload_buffers(&self, buffers: &mut Buffers, frame: &Frame) {
        let vertex = wgpu::BufferUsages::VERTEX;
        self.write_buffer(&mut buffers.rects, &frame.rects, vertex);
        self.write_buffer(&mut buffers.glyphs, &frame.glyphs, vertex);
        self.write_buffer(&mut buffers.cells, &frame.cells, vertex);
        self.write_buffer(&mut buffers.path_vertices, &frame.path_vertices, vertex);
        let index = wgpu::BufferUsages::INDEX;
        self.write_buffer(&mut buffers.path_indices, &frame.path_indices, index);
    }

    /// The multisampled attachment at the target's size, created on its first frame with
    /// paths and again after a resize.
    fn msaa_view(&self, target: &mut Target) -> wgpu::TextureView {
        let size = [target.viewport.width_px, target.viewport.height_px];
        if let Some((view, at)) = &target.msaa
            && *at == size
        {
            return view.clone();
        }
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("msaa"),
            size: wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: PATH_SAMPLES,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            // Resolved in the pass and never stored: tile memory only on Apple GPUs.
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TRANSIENT_ATTACHMENT,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        target.msaa = Some((view.clone(), size));
        view
    }

    /// Encode `frame` (already uploaded) into one render pass on `view`: the uniforms are
    /// the only writes, so a camera move or a clock tick costs this alone.
    fn encode(&self, target: &mut Target, frame: &Frame, view: &wgpu::TextureView) {
        if target.retained.active() {
            let scene = std::mem::take(&mut target.retained);
            self.encode_lists(target, scene.frames(), scene.clear(), view, Some(&scene));
            target.retained = scene;
        } else {
            let buffers = std::mem::take(&mut target.buffers);
            self.encode_lists(
                target,
                std::iter::once((frame, &buffers)),
                frame.clear,
                view,
                None,
            );
            target.buffers = buffers;
        }
    }

    fn encode_lists<'a>(
        &self,
        target: &mut Target,
        frames: impl Iterator<Item = (&'a Frame, &'a Buffers)> + Clone,
        clear: [f64; 4],
        view: &wgpu::TextureView,
        scene: Option<&retained::Scene>,
    ) {
        let started = Instant::now();
        let vp = target.viewport;
        let (w, h, t, s) = (
            vp.width_px as f32,
            vp.height_px as f32,
            target.time(),
            vp.scale,
        );
        let used = scene.map(|s| s.follows());
        for (i, f) in [Follow::NONE, Follow::X, Follow::Y, Follow::BOTH]
            .into_iter()
            .enumerate()
        {
            let c = f.of(target.camera);
            let data = [
                w,
                h,
                if scene.is_some_and(|s| !s.animated()) {
                    0.0
                } else {
                    t
                },
                0.0,
                c.scale.x,
                c.scale.y,
                c.offset.x * s,
                c.offset.y * s,
            ];
            if used.is_none_or(|mask| mask[i]) && target.camera_data[i] != Some(data) {
                self.queue
                    .write_buffer(&target.cameras[i].buffer, 0, bytemuck::cast_slice(&data));
                target.camera_data[i] = Some(data);
            }
        }
        target.profile.uniforms_ms = started.elapsed().as_secs_f64() * 1000.0;
        let commands = Instant::now();
        let multisampled = frames.clone().any(|(frame, _)| frame.has_paths());
        let msaa = multisampled.then(|| self.msaa_view(target));
        let pipes = if multisampled {
            self.multisampled()
        } else {
            &self.single
        };

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("frame"),
            });
        {
            let [r, g, b, a] = clear;
            let load = wgpu::LoadOp::Clear(wgpu::Color { r, g, b, a });
            let attachment = match &msaa {
                Some(msaa) => wgpu::RenderPassColorAttachment {
                    view: msaa,
                    depth_slice: None,
                    resolve_target: Some(view),
                    ops: wgpu::Operations {
                        load,
                        store: wgpu::StoreOp::Discard,
                    },
                },
                None => wgpu::RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load,
                        store: wgpu::StoreOp::Store,
                    },
                },
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("frame"),
                color_attachments: &[Some(attachment)],
                ..Default::default()
            });
            if let Some(scene) = scene {
                for run in scene.bundles() {
                    pass.set_scissor_rect(
                        run.scissor[0],
                        run.scissor[1],
                        run.scissor[2],
                        run.scissor[3],
                    );
                    pass.execute_bundles(std::iter::once(if multisampled {
                        &run.msaa
                    } else {
                        run.single.as_ref().expect("single-sampled chunk")
                    }));
                }
            } else {
                pass.set_bind_group(1, &self.atlas_bind, &[]);
                let mut bound: Option<Follow> = None;
                let mut scissor: Option<[u32; 4]> = None;
                for (frame, buffers) in frames {
                    let mut pipeline: Option<Pipeline> = None;
                    for batch in &frame.batches {
                        let [x, y, w, h] =
                            batch.scissor.unwrap_or([0, 0, vp.width_px, vp.height_px]);
                        if w == 0 || h == 0 {
                            continue;
                        }
                        let buffer = match batch.pipeline {
                            Pipeline::Rect => &buffers.rects,
                            Pipeline::Glyph => &buffers.glyphs,
                            Pipeline::Cell => &buffers.cells,
                            Pipeline::Path => &buffers.path_vertices,
                        };
                        let Some(buffer) = buffer else { continue };
                        if bound != Some(batch.follow) {
                            pass.set_bind_group(0, &target.cameras[batch.follow.index()].bind, &[]);
                            bound = Some(batch.follow);
                        }
                        // Only what changed between batches is set again: a timeline alternates a few
                        // pipelines under one scissor thousands of times.
                        if scissor != Some([x, y, w, h]) {
                            pass.set_scissor_rect(x, y, w, h);
                            scissor = Some([x, y, w, h]);
                        }
                        if pipeline != Some(batch.pipeline) {
                            match batch.pipeline {
                                Pipeline::Rect => pass.set_pipeline(&pipes.rect),
                                Pipeline::Glyph => pass.set_pipeline(&pipes.glyph),
                                Pipeline::Cell => pass.set_pipeline(&pipes.cell),
                                Pipeline::Path => {
                                    let (Some(path), Some(indices)) =
                                        (&pipes.path, &buffers.path_indices)
                                    else {
                                        continue;
                                    };
                                    pass.set_pipeline(path);
                                    pass.set_index_buffer(
                                        indices.buffer.slice(..),
                                        wgpu::IndexFormat::Uint32,
                                    );
                                }
                            }
                            pass.set_vertex_buffer(0, buffer.buffer.slice(..));
                            pipeline = Some(batch.pipeline);
                        }
                        if batch.pipeline == Pipeline::Path {
                            pass.draw_indexed(batch.instances.clone(), 0, 0..1);
                        } else {
                            pass.draw(0..4, batch.instances.clone());
                        }
                    }
                }
            }
        }
        target.profile.commands_ms = commands.elapsed().as_secs_f64() * 1000.0;
        let finish = Instant::now();
        let command = encoder.finish();
        target.profile.finish_ms = finish.elapsed().as_secs_f64() * 1000.0;
        let submit = Instant::now();
        self.queue.submit([command]);
        target.profile.submit_ms = submit.elapsed().as_secs_f64() * 1000.0;
        target.stats.encodes += 1;
    }

    /// The surface's next texture, or why there is none this tick.
    fn acquire(&self, target: &Target) -> Result<Option<wgpu::SurfaceTexture>, GpuError> {
        let Some(surface) = &target.surface else {
            return Err(GpuError::Surface("target has no surface".into()));
        };
        match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t)
            | wgpu::CurrentSurfaceTexture::Suboptimal(t) => Ok(Some(t)),
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                Ok(None)
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                if let Some(config) = &target.config {
                    surface.configure(&self.device, config);
                }
                Ok(None)
            }
            wgpu::CurrentSurfaceTexture::Validation => Err(GpuError::Surface(
                "validation error acquiring a frame".into(),
            )),
        }
    }

    /// Encode the target's retained frame on the surface's next texture and present it.
    fn present(&self, target: &mut Target) -> Result<FrameOutcome, GpuError> {
        let acquired = Instant::now();
        let texture = self.acquire(target)?;
        target.profile.acquire_ms = acquired.elapsed().as_secs_f64() * 1000.0;
        let Some(texture) = texture else {
            return Ok(FrameOutcome::Skipped);
        };
        let view = texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let frame = std::mem::take(&mut target.frame);
        self.encode(target, &frame, &view);
        target.frame = frame;
        let presented = Instant::now();
        self.queue.present(texture);
        target.profile.present_ms = presented.elapsed().as_secs_f64() * 1000.0;
        Ok(FrameOutcome::Presented)
    }

    /// Draw `dl` to a surface target and present it.
    pub fn render(
        &self,
        target: &mut Target,
        dl: &DisplayList,
        text: &mut TextSystem,
    ) -> Result<FrameOutcome, GpuError> {
        if target.surface.is_none() {
            return Err(GpuError::Surface("target has no surface".into()));
        }
        target.retained.active = false;
        target.frame.rebuild(dl, text, target.viewport);
        self.upload_atlas(text);
        let frame = std::mem::take(&mut target.frame);
        self.upload(target, &frame);
        target.frame = frame;
        target.uploaded = true;
        self.present(target)
    }

    /// Where the target's camera layers draw from the next encode on.
    pub fn set_camera(&self, target: &mut Target, camera: Camera) {
        target.camera = camera;
    }

    /// Present the last rendered frame again under the current camera and clock: no rebuild,
    /// no instance upload, no glyph. Errors when nothing was rendered yet.
    pub fn redraw(&self, target: &mut Target) -> Result<FrameOutcome, GpuError> {
        if !target.uploaded {
            return Err(GpuError::Surface("nothing rendered to redraw".into()));
        }
        self.present(target)
    }

    /// An [`Offscreen`] target of `viewport`'s size.
    pub fn offscreen(&self, viewport: Viewport) -> Offscreen {
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("offscreen"),
            size: wgpu::Extent3d {
                width: viewport.width_px,
                height: viewport.height_px,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        Offscreen {
            target: self.target(viewport),
            texture,
            view,
        }
    }

    fn wait(&self) -> Result<(), GpuError> {
        #[cfg(not(target_arch = "wasm32"))]
        {
            self.device
                .poll(wgpu::PollType::wait_indefinitely())
                .map(|_| ())
                .map_err(|e| GpuError::Wait(e.to_string()))
        }
        // Browser submission is asynchronous; blocking would prevent completion callbacks.
        #[cfg(target_arch = "wasm32")]
        {
            Ok(())
        }
    }

    /// Draw an already built `frame` into `off`: upload the atlas's new rects, encode
    /// and submit. Native targets block until completion; browsers must await
    /// [`read_offscreen_async`](Self::read_offscreen_async) when they need the pixels.
    pub fn draw_offscreen(
        &self,
        off: &mut Offscreen,
        frame: &Frame,
        text: &mut TextSystem,
    ) -> Result<(), GpuError> {
        self.upload_atlas(text);
        off.target.retained.active = false;
        self.upload(&mut off.target, frame);
        // The buffers now hold the caller's frame, not the target's own.
        off.target.uploaded = false;
        self.encode(&mut off.target, frame, &off.view);
        self.wait()
    }

    /// Build `dl` into `off`'s own frame and draw it, as [`render`](Self::render) does.
    pub fn render_offscreen(
        &self,
        off: &mut Offscreen,
        dl: &DisplayList,
        text: &mut TextSystem,
    ) -> Result<(), GpuError> {
        let target = &mut off.target;
        target.retained.active = false;
        target.frame.rebuild(dl, text, target.viewport);
        self.upload_atlas(text);
        let frame = std::mem::take(&mut target.frame);
        self.upload(target, &frame);
        self.encode(target, &frame, &off.view);
        target.frame = frame;
        target.uploaded = true;
        self.wait()
    }

    /// Submit the retained offscreen frame without a GPU fence (CPU frame-cost probes).
    /// Readback, or `redraw_offscreen`, waits when completion is required.
    pub fn submit_offscreen(&self, off: &mut Offscreen) -> Result<(), GpuError> {
        if !off.target.uploaded {
            return Err(GpuError::Surface("nothing rendered to redraw".into()));
        }
        let frame = std::mem::take(&mut off.target.frame);
        self.encode(&mut off.target, &frame, &off.view);
        off.target.frame = frame;
        Ok(())
    }

    /// Draw `off`'s last rendered frame again, as [`redraw`](Self::redraw) does.
    pub fn redraw_offscreen(&self, off: &mut Offscreen) -> Result<(), GpuError> {
        if !off.target.uploaded {
            return Err(GpuError::Surface("nothing rendered to redraw".into()));
        }
        let frame = std::mem::take(&mut off.target.frame);
        self.encode(&mut off.target, &frame, &off.view);
        off.target.frame = frame;
        self.wait()
    }

    /// Read `off`'s texture back as straight-alpha RGBA8, rows top first. Blocks until the
    /// GPU finishes.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn read_offscreen(&self, off: &Offscreen) -> Result<(u32, u32, Vec<u8>), GpuError> {
        block_on(self.read_offscreen_async(off))
    }

    /// Readback that yields to the browser event loop while mapping the GPU buffer.
    pub async fn read_offscreen_async(
        &self,
        off: &Offscreen,
    ) -> Result<(u32, u32, Vec<u8>), GpuError> {
        let (w, h) = (off.target.viewport.width_px, off.target.viewport.height_px);
        let row = (w * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT)
            * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("capture"),
            size: (row * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("capture"),
            });
        encoder.copy_texture_to_buffer(
            off.texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(h),
                },
            },
            wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([encoder.finish()]);
        let slice = buffer.slice(..);
        #[cfg(not(target_arch = "wasm32"))]
        let (tx, rx) = std::sync::mpsc::channel();
        #[cfg(target_arch = "wasm32")]
        let (tx, mut rx) = futures_channel::oneshot::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            // The receiver outlives the poll below; a send error cannot happen.
            let _ = tx.send(r);
        });
        #[cfg(not(target_arch = "wasm32"))]
        {
            self.device
                .poll(wgpu::PollType::wait_indefinitely())
                .map_err(|e| GpuError::Readback(e.to_string()))?;
            rx.recv()
                .map_err(|e| GpuError::Readback(e.to_string()))?
                .map_err(|e| GpuError::Readback(e.to_string()))?;
        }
        #[cfg(target_arch = "wasm32")]
        {
            // WebGL mapping callbacks advance on device.poll; WebGPU resolves a JS
            // promise. Yield a browser task between polls so neither backend deadlocks.
            loop {
                self.device
                    .poll(wgpu::PollType::Poll)
                    .map_err(|e| GpuError::Readback(e.to_string()))?;
                if let Some(result) = rx
                    .try_recv()
                    .map_err(|e| GpuError::Readback(e.to_string()))?
                {
                    result.map_err(|e| GpuError::Readback(e.to_string()))?;
                    break;
                }
                let task = js_sys::Promise::new(&mut |resolve, _| {
                    web_sys::window()
                        .expect("browser readback requires Window")
                        .set_timeout_with_callback_and_timeout_and_arguments_0(&resolve, 0)
                        .expect("schedule readback poll");
                });
                wasm_bindgen_futures::JsFuture::from(task)
                    .await
                    .map_err(|e| GpuError::Readback(format!("{e:?}")))?;
            }
        }
        let mapped = slice
            .get_mapped_range()
            .map_err(|e| GpuError::Readback(e.to_string()))?;
        let mut out = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h as usize {
            for p in mapped[y * row as usize..][..w as usize * 4].chunks_exact(4) {
                #[cfg(not(target_arch = "wasm32"))]
                let (b, g, r, a) = (p[0], p[1], p[2], p[3]);
                #[cfg(target_arch = "wasm32")]
                let (r, g, b, a) = (p[0], p[1], p[2], p[3]);
                let un = |c: u8| {
                    if a == 0 {
                        0
                    } else {
                        ((c as u32 * 255 + a as u32 / 2) / a as u32).min(255) as u8
                    }
                };
                out.extend_from_slice(&[un(r), un(g), un(b), a]);
            }
        }
        drop(mapped);
        buffer.unmap();
        Ok((w, h, out))
    }

    /// Render `dl` offscreen and read it back as straight-alpha RGBA8, rows top first
    /// (a debug capture, a golden). Blocks until the GPU finishes.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn render_to_rgba(
        &self,
        dl: &DisplayList,
        text: &mut TextSystem,
        width: f64,
        height: f64,
        scale: f64,
    ) -> Result<(u32, u32, Vec<u8>), GpuError> {
        let mut off = self.offscreen(Viewport {
            width_px: px(width, scale),
            height_px: px(height, scale),
            scale: scale as f32,
        });
        self.render_offscreen(&mut off, dl, text)?;
        self.read_offscreen(&off)
    }
}
