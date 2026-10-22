//! Ordered, keyed display lists on the existing target and pipelines.
//!
//! Preparation is independent of publication: replacement buffers never overwrite a
//! visible resource. Each list is self-contained (balanced clip/camera operations).
use crate::{Buffers, Frame, Gpu, GpuError, Target, Viewport};
use canvas_draw::{Camera, DisplayList, Follow, Point, Rect, Rgba};
use canvas_text::TextSystem;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

/// Host-owned stable key; revisions are represented by new display-list allocations.
pub type ChunkId = u64;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RetainedStats {
    pub uploads: u64,
    pub builds: u64,
    pub tessellations: u64,
    pub atlas_refreshes: u64,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct QuadInstance {
    quad: [f32; 4],
    shape: [f32; 4],
    fill: [f32; 4],
    border: [f32; 4],
    params: [f32; 4],
    uv: [f32; 4],
    tag: [u32; 2],
}

#[derive(Clone, Copy)]
struct RunBounds {
    follow: Follow,
    world: Rect,
    margin: Point,
}
pub(crate) struct BundleRun {
    bounds: Option<RunBounds>,
    pub scissor: [u32; 4],
    pub single: Option<wgpu::RenderBundle>,
    pub msaa: wgpu::RenderBundle,
}

struct Resource {
    quad_buffer: Option<crate::GrowBuffer>,
    follows: [bool; 4],
    bundles: Vec<BundleRun>,
    list: Arc<DisplayList>,
    frame: Frame,
    buffers: Buffers,
    generation: u64,
    atlas_dependent: bool,
    viewport: Viewport,
}

#[derive(Clone, Copy, Default)]
struct GridBounds {
    min: Point,
    max: Point,
}
impl GridBounds {
    fn intersects(self, other: Self) -> bool {
        self.min.x <= other.max.x
            && self.max.x >= other.min.x
            && self.min.y <= other.max.y
            && self.max.y >= other.min.y
    }
    fn union(self, other: Self) -> Self {
        Self {
            min: Point::new(self.min.x.min(other.min.x), self.min.y.min(other.min.y)),
            max: Point::new(self.max.x.max(other.max.x), self.max.y.max(other.max.y)),
        }
    }
}
struct Node {
    bounds: GridBounds,
    left: Option<usize>,
    right: Option<usize>,
    run: usize,
}
#[derive(Default)]
struct RunIndex {
    nodes: Vec<Node>,
    root: Option<usize>,
}
impl RunIndex {
    fn build(&mut self, entries: &mut [(GridBounds, usize)]) -> Option<usize> {
        if entries.is_empty() {
            return None;
        }
        let bounds = entries
            .iter()
            .map(|e| e.0)
            .reduce(GridBounds::union)
            .unwrap();
        let index = self.nodes.len();
        self.nodes.push(Node {
            bounds,
            left: None,
            right: None,
            run: entries[0].1,
        });
        if entries.len() > 1 {
            let x = bounds.max.x - bounds.min.x >= bounds.max.y - bounds.min.y;
            let middle = entries.len() / 2;
            entries.select_nth_unstable_by(middle, |a, b| {
                let centre = |v: &(GridBounds, usize)| {
                    if x {
                        v.0.min.x + v.0.max.x
                    } else {
                        v.0.min.y + v.0.max.y
                    }
                };
                centre(a).total_cmp(&centre(b)).then(a.1.cmp(&b.1))
            });
            let (a, b) = entries.split_at_mut(middle);
            let left = self.build(a);
            let right = self.build(b);
            self.nodes[index].left = left;
            self.nodes[index].right = right;
        }
        Some(index)
    }
    fn query(&self, index: usize, viewport: GridBounds, output: &mut Vec<usize>) {
        let node = &self.nodes[index];
        if !node.bounds.intersects(viewport) {
            return;
        }
        if let Some(left) = node.left {
            self.query(left, viewport, output);
            self.query(node.right.unwrap(), viewport, output);
        } else {
            output.push(node.run);
        }
    }
}
#[derive(Default)]
pub(crate) struct Scene {
    resources: BTreeMap<ChunkId, Arc<Resource>>,
    spare: BTreeMap<ChunkId, (Buffers, Option<crate::GrowBuffer>)>,
    overlay: Option<Arc<Resource>>,
    pending: Option<BTreeMap<ChunkId, Arc<Resource>>>,
    pending_overlay: Option<Option<Arc<Resource>>>,
    visible: Vec<Arc<Resource>>,
    clear: [f64; 4],
    pub(crate) active: bool,
    stats: RetainedStats,
    runs: Vec<(usize, usize)>,
    indices: [RunIndex; 4],
    margins: [Point; 4],
    unbounded: Vec<usize>,
    selected: Vec<usize>,
    cache_camera: Option<Camera>,
    follows: [bool; 4],
    animated: bool,
    paths: bool,
}

impl Scene {
    pub(crate) fn active(&self) -> bool {
        self.active
    }
    pub(crate) fn clear(&self) -> [f64; 4] {
        self.clear
    }
    pub(crate) fn frames(&self) -> impl Iterator<Item = (&Frame, &Buffers)> + Clone {
        self.visible.iter().map(|r| (&r.frame, &r.buffers))
    }
    pub(crate) fn bundle(&self, index: usize) -> &BundleRun {
        let (resource, run) = self.runs[index];
        &self.visible[resource].bundles[run]
    }
    pub(crate) fn run_count(&self) -> usize {
        self.runs.len()
    }
    pub(crate) fn selected(&self) -> &[usize] {
        &self.selected
    }
    pub(crate) fn follows(&self) -> [bool; 4] {
        self.follows
    }
    pub(crate) fn animated(&self) -> bool {
        self.animated
    }
    pub(crate) fn has_paths(&self) -> bool {
        self.paths
    }
    fn rebuild_index(&mut self) {
        self.runs.clear();
        self.unbounded.clear();
        self.cache_camera = None;
        self.follows = [false; 4];
        self.animated = false;
        self.paths = false;
        self.margins = [Point::ZERO; 4];
        let mut entries: [Vec<(GridBounds, usize)>; 4] = Default::default();
        for (resource, r) in self.visible.iter().enumerate() {
            self.animated |= r.frame.animated;
            self.paths |= r.frame.has_paths();
            for (dst, src) in self.follows.iter_mut().zip(r.follows) {
                *dst |= src;
            }
            for (run, bundle) in r.bundles.iter().enumerate() {
                let id = self.runs.len();
                self.runs.push((resource, run));
                if let Some(b) = bundle.bounds {
                    let i = b.follow.index();
                    self.margins[i].x = self.margins[i].x.max(b.margin.x);
                    self.margins[i].y = self.margins[i].y.max(b.margin.y);
                    entries[i].push((
                        GridBounds {
                            min: b.world.origin(),
                            max: Point::new(b.world.max_x(), b.world.max_y()),
                        },
                        id,
                    ));
                } else {
                    self.unbounded.push(id);
                }
            }
        }
        for (index, entries) in self.indices.iter_mut().zip(&mut entries) {
            index.nodes.clear();
            index.root = index.build(entries);
        }
    }
    pub(crate) fn select(&mut self, camera: Camera, vp: Viewport) {
        if self.cache_camera == Some(camera) {
            return;
        }
        self.selected.clear();
        self.selected.extend_from_slice(&self.unbounded);
        for follow in [Follow::NONE, Follow::X, Follow::Y, Follow::BOTH] {
            let i = follow.index();
            let c = follow.of(camera);
            let margin = self.margins[i];
            if c.scale.x <= 0.
                || c.scale.y <= 0.
                || !c.scale.x.is_finite()
                || !c.scale.y.is_finite()
                || !c.offset.x.is_finite()
                || !c.offset.y.is_finite()
            {
                self.selected.extend(
                    self.indices[i]
                        .nodes
                        .iter()
                        .filter(|n| n.left.is_none())
                        .map(|n| n.run),
                );
                continue;
            }
            let viewport = GridBounds {
                min: Point::new(
                    (-c.offset.x * vp.scale - margin.x) / c.scale.x,
                    (-c.offset.y * vp.scale - margin.y) / c.scale.y,
                ),
                max: Point::new(
                    (vp.width_px as f32 - c.offset.x * vp.scale + margin.x) / c.scale.x,
                    (vp.height_px as f32 - c.offset.y * vp.scale + margin.y) / c.scale.y,
                ),
            };
            if let Some(root) = self.indices[i].root {
                self.indices[i].query(root, viewport, &mut self.selected);
            }
        }
        self.selected.sort_unstable();
        self.cache_camera = Some(camera);
    }
}

impl Target {
    pub fn retained_stats(&self) -> RetainedStats {
        self.retained.stats
    }

    /// Start (or abandon and restart) a transaction from the last published set.
    pub fn begin_chunks(&mut self) {
        self.retained.pending = Some(self.retained.resources.clone());
        self.retained.pending_overlay = Some(self.retained.overlay.clone());
    }

    /// Remove from the transaction; the published set remains untouched.
    pub fn remove_chunk(&mut self, id: ChunkId) -> Result<(), GpuError> {
        self.retained
            .pending
            .as_mut()
            .ok_or_else(transaction_required)?
            .remove(&id);
        Ok(())
    }
}

fn run_bounds(
    batches: &[crate::Batch],
    quads: &[QuadInstance],
    frame: &Frame,
) -> Option<RunBounds> {
    let follow = batches.first()?.follow;
    let mut bounds: Option<GridBounds> = None;
    let mut margin = Point::new(1., 1.);
    let mut include = |rect: Rect, pad: Point| -> Option<()> {
        if [rect.x, rect.y, rect.w, rect.h, pad.x, pad.y]
            .iter()
            .any(|v| !v.is_finite())
            || rect.w < 0.
            || rect.h < 0.
        {
            return None;
        }
        let next = GridBounds {
            min: rect.origin(),
            max: Point::new(rect.max_x(), rect.max_y()),
        };
        bounds = Some(bounds.map_or(next, |old| old.union(next)));
        margin.x = margin.x.max(pad.x + 1.);
        margin.y = margin.y.max(pad.y + 1.);
        Some(())
    };
    for batch in batches {
        if batch.follow != follow {
            return None;
        }
        for i in batch.instances.clone() {
            match batch.pipeline {
                crate::Pipeline::Rect => {
                    let q = quads[i as usize];
                    if q.tag[0] == 0 {
                        let [x, y, w, h] = q.shape;
                        let mx = (x - q.quad[0]).abs();
                        let my = (y - q.quad[1]).abs();
                        if q.params[3] > 0.5 {
                            include(
                                Rect::new(x + w * 0.5, y + h * 0.5, 0., 0.),
                                Point::new(w.abs() * 0.5 + mx, h.abs() * 0.5 + my),
                            )?;
                        } else {
                            include(Rect::new(x, y, w, h), Point::new(mx, my))?;
                        }
                    } else if q.tag[1] & (crate::frame::GLYPH_STRETCH << 16) != 0 {
                        let [x, y, w, h] = q.quad;
                        include(Rect::new(x, y, w, h), Point::ZERO)?;
                    } else {
                        include(
                            Rect::new(q.params[0], q.params[1], 0., 0.),
                            Point::new(
                                q.quad[0].abs().max((q.quad[0] + q.quad[2]).abs()),
                                q.quad[1].abs().max((q.quad[1] + q.quad[3]).abs()),
                            ),
                        )?;
                    }
                }
                crate::Pipeline::Cell => {
                    let [x, y, w, h] = frame.cells[i as usize].quad;
                    include(Rect::new(x, y, w, h), Point::ZERO)?;
                }
                crate::Pipeline::Path => {
                    let p = frame.path_vertices[frame.path_indices[i as usize] as usize].pos;
                    include(Rect::new(p[0], p[1], 0., 0.), Point::ZERO)?;
                }
                crate::Pipeline::Glyph => return None,
            }
        }
    }
    let b = bounds?;
    Some(RunBounds {
        follow,
        world: Rect::from_corners(b.min, b.max),
        margin,
    })
}
fn atlas_dependent(list: &DisplayList) -> bool {
    list.ops.iter().any(|op| {
        matches!(
            op,
            canvas_draw::Op::Text(_)
                | canvas_draw::Op::Code(_)
                | canvas_draw::Op::Cells(_)
                | canvas_draw::Op::Image(_)
        )
    })
}

fn transaction_required() -> GpuError {
    GpuError::Surface("begin_chunks must precede retained edits".into())
}

impl Gpu {
    fn chunk_bundles(
        &self,
        target: &Target,
        frame: &Frame,
        buffers: &Buffers,
        mut quad_buffer: Option<crate::GrowBuffer>,
    ) -> (Vec<BundleRun>, Option<crate::GrowBuffer>) {
        let mut quads = Vec::new();
        let mut batches: Vec<crate::Batch> = Vec::new();
        for batch in &frame.batches {
            let mut next = batch.clone();
            if matches!(
                batch.pipeline,
                crate::Pipeline::Rect | crate::Pipeline::Glyph
            ) {
                let first = quads.len() as u32;
                for i in batch.instances.clone() {
                    quads.push(match batch.pipeline {
                        crate::Pipeline::Rect => {
                            let r = frame.rects[i as usize];
                            QuadInstance {
                                quad: r.quad,
                                shape: r.shape,
                                fill: r.fill,
                                border: r.border_color,
                                params: r.params,
                                uv: [0.0; 4],
                                tag: [0, 0],
                            }
                        }
                        _ => {
                            let g = frame.glyphs[i as usize];
                            QuadInstance {
                                quad: g.quad,
                                shape: [0.0; 4],
                                fill: g.color,
                                border: [0.0; 4],
                                params: [g.anchor[0], g.anchor[1], 0.0, 0.0],
                                uv: g.uv,
                                tag: [1, g.page[0] | (g.page[1] << 16)],
                            }
                        }
                    });
                }
                next.pipeline = crate::Pipeline::Rect;
                next.instances = first..quads.len() as u32;
            }
            if let Some(last) = batches.last_mut()
                && last.pipeline == next.pipeline
                && last.follow == next.follow
                && last.scissor == next.scissor
                && last.instances.end == next.instances.start
            {
                last.instances.end = next.instances.end;
            } else {
                batches.push(next);
            }
        }
        self.write_buffer(&mut quad_buffer, &quads, wgpu::BufferUsages::VERTEX);
        let mut runs = Vec::new();
        let mut start = 0;
        while start < batches.len() {
            let clip = batches[start].scissor;
            let mut end = start + 1;
            while end < batches.len() && batches[end].scissor == clip {
                end += 1;
            }
            let scissor =
                clip.unwrap_or([0, 0, target.viewport.width_px, target.viewport.height_px]);
            if scissor[2] != 0 && scissor[3] != 0 {
                let build = |samples| {
                    let pipes = if samples == 1 {
                        &self.single
                    } else {
                        self.multisampled()
                    };
                    let mut bundle = self.device.create_render_bundle_encoder(
                        &wgpu::RenderBundleEncoderDescriptor {
                            label: Some("retained chunk"),
                            color_formats: &[Some(crate::FORMAT)],
                            sample_count: samples,
                            ..Default::default()
                        },
                    );
                    bundle.set_bind_group(1, &self.atlas_bind, &[]);
                    let mut follow = None;
                    let mut pipeline = None;
                    for batch in &batches[start..end] {
                        let buffer = match batch.pipeline {
                            crate::Pipeline::Rect => &quad_buffer,
                            crate::Pipeline::Glyph => &buffers.glyphs,
                            crate::Pipeline::Cell => &buffers.cells,
                            crate::Pipeline::Path => &buffers.path_vertices,
                        };
                        let Some(buffer) = buffer else { continue };
                        if follow != Some(batch.follow) {
                            bundle.set_bind_group(
                                0,
                                &target.cameras[batch.follow.index()].bind,
                                &[],
                            );
                            follow = Some(batch.follow);
                        }
                        if pipeline != Some(batch.pipeline) {
                            match batch.pipeline {
                                crate::Pipeline::Rect => bundle.set_pipeline(&pipes.quad),
                                crate::Pipeline::Glyph => bundle.set_pipeline(&pipes.glyph),
                                crate::Pipeline::Cell => bundle.set_pipeline(&pipes.cell),
                                crate::Pipeline::Path => {
                                    bundle.set_pipeline(pipes.path.as_ref().expect("MSAA paths"));
                                    bundle.set_index_buffer(
                                        buffers
                                            .path_indices
                                            .as_ref()
                                            .expect("path indices")
                                            .buffer
                                            .slice(..),
                                        wgpu::IndexFormat::Uint32,
                                    );
                                }
                            }
                            bundle.set_vertex_buffer(0, buffer.buffer.slice(..));
                            pipeline = Some(batch.pipeline);
                        }
                        if batch.pipeline == crate::Pipeline::Path {
                            bundle.draw_indexed(batch.instances.clone(), 0, 0..1);
                        } else {
                            bundle.draw(0..4, batch.instances.clone());
                        }
                    }
                    bundle.finish(&wgpu::RenderBundleDescriptor {
                        label: Some("retained chunk"),
                    })
                };
                runs.push(BundleRun {
                    bounds: run_bounds(&batches[start..end], &quads, frame),
                    scissor,
                    single: (!frame.has_paths()).then(|| build(1)),
                    msaa: build(crate::PATH_SAMPLES),
                });
            }
            start = end;
        }
        (runs, quad_buffer)
    }

    fn chunk_resource(
        &self,
        target: &mut Target,
        list: Arc<DisplayList>,
        previous: Option<&Resource>,
        spare: Option<(Buffers, Option<crate::GrowBuffer>)>,
        text: &mut TextSystem,
    ) -> Arc<Resource> {
        let started = crate::Instant::now();
        let mut frame = previous.map_or_else(Frame::default, |r| r.frame.clone());
        let tessellations = frame.tessellations();
        // Across lists eviction would invalidate earlier chunks. A host may clear
        // the shared atlas explicitly; an oversized working set omits missing glyphs.
        frame.rebuild_retained(&list, text, target.viewport);
        target.profile.rebuild_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started = crate::Instant::now();
        let (mut buffers, quad_buffer) = spare.unwrap_or_default();
        self.upload_buffers(&mut buffers, &frame);
        target.retained.stats.uploads += 1;
        target.retained.stats.builds += 1;
        target.retained.stats.tessellations += frame.tessellations() - tessellations;
        target.stats.uploads += 1;
        let atlas_dependent = atlas_dependent(&list);
        target.profile.upload_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started = crate::Instant::now();
        let (bundles, quad_buffer) = self.chunk_bundles(target, &frame, &buffers, quad_buffer);
        target.profile.bundle_ms = started.elapsed().as_secs_f64() * 1000.0;
        let mut follows = [false; 4];
        for batch in &frame.batches {
            follows[batch.follow.index()] = true;
        }
        Arc::new(Resource {
            quad_buffer,
            follows,
            bundles,
            atlas_dependent,
            list,
            frame,
            buffers,
            generation: text.atlas().generation(),
            viewport: target.viewport,
        })
    }

    /// Prepare one replacement, leaving its previous version drawing until publish.
    /// Reusing the identical Arc is a no-op (except viewport/atlas invalidation).
    pub fn upsert_chunk(
        &self,
        target: &mut Target,
        id: ChunkId,
        list: Arc<DisplayList>,
        text: &mut TextSystem,
    ) -> Result<(), GpuError> {
        let pending = target
            .retained
            .pending
            .as_ref()
            .ok_or_else(transaction_required)?;
        if pending.get(&id).is_some_and(|r| {
            Arc::ptr_eq(&r.list, &list)
                && r.viewport == target.viewport
                && (!r.atlas_dependent || r.generation == text.atlas().generation())
        }) {
            return Ok(());
        }
        let previous = pending.get(&id).cloned();
        let spare = target.retained.spare.remove(&id);
        let resource = self.chunk_resource(target, list, previous.as_deref(), spare, text);
        target
            .retained
            .pending
            .as_mut()
            .expect("checked above")
            .insert(id, resource);
        self.upload_atlas(text);
        Ok(())
    }

    /// The overlay draws last, in the same pass, with its own balanced clips/camera.
    pub fn set_chunk_overlay(
        &self,
        target: &mut Target,
        list: Option<Arc<DisplayList>>,
        text: &mut TextSystem,
    ) -> Result<(), GpuError> {
        let previous = target
            .retained
            .pending_overlay
            .as_ref()
            .ok_or_else(transaction_required)?;
        if let (Some(old), Some(list)) = (previous, &list)
            && Arc::ptr_eq(&old.list, list)
            && old.viewport == target.viewport
            && (!old.atlas_dependent || old.generation == text.atlas().generation())
        {
            return Ok(());
        }
        let previous = previous.clone();
        let resource =
            list.map(|list| self.chunk_resource(target, list, previous.as_deref(), None, text));
        target.retained.pending_overlay = Some(resource);
        self.upload_atlas(text);
        Ok(())
    }

    /// Atomically publish exactly this painter order. Unknown or duplicate keys
    /// fail without changing the current publication or consuming the transaction.
    /// Each list's clear colour is ignored; `clear` belongs to the whole target.
    pub fn publish_chunks(
        &self,
        target: &mut Target,
        order: &[ChunkId],
        clear: Rgba,
        text: &mut TextSystem,
    ) -> Result<(), GpuError> {
        let pending = target
            .retained
            .pending
            .as_ref()
            .ok_or_else(transaction_required)?;
        let mut seen = BTreeSet::new();
        if order
            .iter()
            .any(|id| !pending.contains_key(id) || !seen.insert(*id))
        {
            return Err(GpuError::Surface(
                "unknown or duplicate retained chunk key".into(),
            ));
        }
        let resources = target.retained.pending.take().expect("checked above");
        let overlay = target
            .retained
            .pending_overlay
            .take()
            .expect("transaction overlay");
        let mut visible: Vec<_> = order.iter().map(|id| resources[id].clone()).collect();
        visible.extend(overlay.iter().cloned());
        target.retained.visible = visible;
        target.retained.rebuild_index();
        let old = std::mem::replace(&mut target.retained.resources, resources);
        for (id, resource) in old {
            if target
                .retained
                .resources
                .get(&id)
                .is_some_and(|current| !Arc::ptr_eq(current, &resource))
                && let Ok(resource) = Arc::try_unwrap(resource)
            {
                target
                    .retained
                    .spare
                    .insert(id, (resource.buffers, resource.quad_buffer));
            }
        }
        target
            .retained
            .spare
            .retain(|id, _| target.retained.resources.contains_key(id));
        target.retained.overlay = overlay;
        target.retained.clear = crate::frame::premul64(clear);
        target.retained.active = true;
        target.uploaded = true;
        self.refresh_chunks(target, text);
        Ok(())
    }

    /// Call before a retained redraw when another surface may have reset the shared
    /// atlas, or after resize. The normal camera-only path does no builds/uploads.
    pub fn refresh_chunks(&self, target: &mut Target, text: &mut TextSystem) {
        let mut scene = std::mem::take(&mut target.retained);
        // Map pointer identities once so visible and staged aliases stay shared.
        let mut replacements = BTreeMap::<usize, Arc<Resource>>::new();
        for resource in scene
            .resources
            .values_mut()
            .chain(scene.overlay.iter_mut())
            .chain(scene.pending.iter_mut().flat_map(|p| p.values_mut()))
            .chain(scene.pending_overlay.iter_mut().filter_map(|p| p.as_mut()))
            .chain(scene.visible.iter_mut())
        {
            let resized = resource.viewport != target.viewport;
            let stale =
                resource.generation != text.atlas().generation() && resource.atlas_dependent;
            if !resized && !stale {
                continue;
            }
            let key = Arc::as_ptr(resource) as usize;
            let replacement = replacements.entry(key).or_insert_with(|| {
                let mut frame = resource.frame.clone();
                let tessellations = frame.tessellations();
                frame.rebuild_retained(&resource.list, text, target.viewport);
                let mut buffers = if resized {
                    Buffers::default()
                } else {
                    resource.buffers.clone()
                };
                if resized {
                    self.upload_buffers(&mut buffers, &frame);
                } else {
                    self.write_buffer(
                        &mut buffers.glyphs,
                        &frame.glyphs,
                        wgpu::BufferUsages::VERTEX,
                    );
                }
                scene.stats.uploads += 1;
                scene.stats.builds += 1;
                scene.stats.tessellations += frame.tessellations() - tessellations;
                scene.stats.atlas_refreshes += u64::from(stale);
                target.stats.uploads += 1;
                let (bundles, quad_buffer) = self.chunk_bundles(target, &frame, &buffers, None);
                Arc::new(Resource {
                    quad_buffer,
                    follows: resource.follows,
                    bundles,
                    atlas_dependent: resource.atlas_dependent,
                    list: resource.list.clone(),
                    frame,
                    buffers,
                    generation: text.atlas().generation(),
                    viewport: target.viewport,
                })
            });
            *resource = replacement.clone();
        }
        if !replacements.is_empty() {
            scene.rebuild_index();
        }
        target.retained = scene;
        self.upload_atlas(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn spatial_query_preserves_order_and_reuses_unchanged_camera_selection() {
        let mut scene = Scene::default();
        let mut entries = vec![
            (
                GridBounds {
                    min: Point::new(8., 8.),
                    max: Point::new(48., 48.),
                },
                0,
            ),
            (
                GridBounds {
                    min: Point::new(90., 8.),
                    max: Point::new(130., 48.),
                },
                1,
            ),
            (
                GridBounds {
                    min: Point::new(500., 8.),
                    max: Point::new(540., 48.),
                },
                2,
            ),
        ];
        scene.indices[Follow::BOTH.index()].root =
            scene.indices[Follow::BOTH.index()].build(&mut entries);
        scene.margins[Follow::BOTH.index()] = Point::new(1., 1.);
        scene.unbounded.push(3);
        let vp = Viewport {
            width_px: 96,
            height_px: 64,
            scale: 1.,
        };
        scene.select(Camera::IDENTITY, vp);
        assert_eq!(scene.selected, [0, 1, 3]);
        let allocation = scene.selected.as_ptr();
        scene.select(Camera::IDENTITY, vp);
        assert_eq!(allocation, scene.selected.as_ptr());
        scene.select(
            Camera {
                offset: Point::new(-490., 0.),
                ..Camera::IDENTITY
            },
            vp,
        );
        assert_eq!(scene.selected, [2, 3]);
    }
    #[test]
    fn mixed_follow_runs_have_no_cull_bound_and_pinned_bounds_keep_pixel_margins() {
        let batches = [crate::Batch {
            pipeline: crate::Pipeline::Rect,
            instances: 0..1,
            scissor: None,
            follow: Follow::BOTH,
        }];
        let q = QuadInstance {
            quad: [99., 9., 42., 42.],
            shape: [100., 10., 40., 40.],
            fill: [0.; 4],
            border: [0.; 4],
            params: [0., 0., 0., 1.],
            uv: [0.; 4],
            tag: [0, 0],
        };
        let bound = run_bounds(&batches, &[q], &Frame::default()).unwrap();
        assert_eq!(bound.world, Rect::new(120., 30., 0., 0.));
        assert!(bound.margin.x >= 21.);
        let mut mixed = batches.to_vec();
        let mut next = batches[0].clone();
        next.follow = Follow::NONE;
        mixed.push(next);
        assert!(run_bounds(&mixed, &[q], &Frame::default()).is_none());
    }
    #[test]
    fn empty_transaction_requires_begin() {
        assert!(Scene::default().pending.is_none());
        assert!(transaction_required().to_string().contains("begin_chunks"));
    }

    #[test]
    fn atlas_dependency_tracks_ops_not_resolved_glyph_count() {
        let mut list = DisplayList::new(Rgba::BLACK);
        assert!(!atlas_dependent(&list));
        list.text(canvas_draw::TextRun::new(
            "Missing glyph",
            canvas_draw::Point::ZERO,
            12.0,
            Rgba::WHITE,
        ));
        assert!(
            atlas_dependent(&list),
            "even missing or currently omitted glyphs must be retried after reset"
        );
    }
}
