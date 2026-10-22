//! Ordered, keyed display lists on the existing target and pipelines.
//!
//! Preparation is independent of publication: replacement buffers never overwrite a
//! visible resource. Each list is self-contained (balanced clip/camera operations).
use crate::{Buffers, Frame, Gpu, GpuError, Target, Viewport};
use canvas_draw::{Camera, DisplayList, Follow, Point, Rect, Rgba};
use canvas_text::TextSystem;
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
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

/// CPU bookkeeping for the last successful publication, excluding resource preparation.
#[derive(Debug, Clone, Copy, Default)]
pub struct RetainedPublishProfile {
    pub validation_ms: f64,
    pub index_ms: f64,
    pub swap_spare_ms: f64,
    pub refresh_ms: f64,
    pub index_rebuilt: bool,
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
    index: ChunkIndex,
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
    fn query(&self, index: usize, viewport: GridBounds, visit: &mut impl FnMut(usize)) {
        let node = &self.nodes[index];
        if !node.bounds.intersects(viewport) {
            return;
        }
        if let Some(left) = node.left {
            self.query(left, viewport, visit);
            self.query(node.right.unwrap(), viewport, visit);
        } else {
            visit(node.run);
        }
    }
    fn leaves(&self) -> impl Iterator<Item = usize> + '_ {
        self.nodes
            .iter()
            .filter(|n| n.left.is_none())
            .map(|n| n.run)
    }
    fn bounds(&self) -> Option<GridBounds> {
        self.root.map(|root| self.nodes[root].bounds)
    }
}

/// One chunk's runs, indexed per Follow class while its bundles are prepared, so a
/// publication indexes only chunk bounds (the top level), never every run.
#[derive(Default)]
struct ChunkIndex {
    runs: [RunIndex; 4],
    margins: [Point; 4],
    unbounded: Vec<usize>,
}
impl ChunkIndex {
    fn new(runs: impl Iterator<Item = Option<RunBounds>>) -> Self {
        let mut index = Self::default();
        let mut entries: [Vec<(GridBounds, usize)>; 4] = Default::default();
        for (run, bounds) in runs.enumerate() {
            let Some(b) = bounds else {
                index.unbounded.push(run);
                continue;
            };
            let i = b.follow.index();
            index.margins[i].x = index.margins[i].x.max(b.margin.x);
            index.margins[i].y = index.margins[i].y.max(b.margin.y);
            entries[i].push((
                GridBounds {
                    min: b.world.origin(),
                    max: Point::new(b.world.max_x(), b.world.max_y()),
                },
                run,
            ));
        }
        for (tree, entries) in index.runs.iter_mut().zip(&mut entries) {
            tree.root = tree.build(entries);
        }
        index
    }
}

enum Retired {
    /// A published resource some publication replaced or removed.
    Resource(ChunkId, Arc<Resource>),
    /// A removed key's spare buffers, held only to be dropped.
    Spare {
        _buffers: Box<(Buffers, Option<crate::GrowBuffer>)>,
    },
}

/// Retired entries each building upsert reclaims: preparation pays for the drops a
/// publication deferred, a little per chunk, so the queue never outgrows the work.
const RECLAIM_PER_UPSERT: usize = 2;

#[derive(Default)]
pub(crate) struct Scene {
    resources: HashMap<ChunkId, Arc<Resource>>,
    spare: HashMap<ChunkId, (Buffers, Option<crate::GrowBuffer>)>,
    overlay: Option<Arc<Resource>>,
    pending: Option<HashMap<ChunkId, Arc<Resource>>>,
    /// Published resources this transaction replaced: their buffers become spares.
    retiring: Vec<(ChunkId, Arc<Resource>)>,
    /// Keys this transaction removed: their spares go unless the key returns.
    removed: Vec<ChunkId>,
    /// What publications retired, recycled or dropped a few at a time by later
    /// preparation (`reclaim`): dropping 1,000 replaced chunks inside the swap cost
    /// 5.6 ms native.
    retired: VecDeque<Retired>,
    pending_overlay: Option<Option<Arc<Resource>>>,
    visible: Vec<Arc<Resource>>,
    visible_scratch: Vec<Arc<Resource>>,
    seen: HashSet<ChunkId>,
    refreshed: Option<(Viewport, u64)>,
    clear: [f64; 4],
    pub(crate) active: bool,
    stats: RetainedStats,
    publish_profile: RetainedPublishProfile,
    run_count: usize,
    /// Per Follow class, a hierarchy over the visible chunks' bounds (leaf = position
    /// in `visible`); each chunk's own `ChunkIndex` narrows to runs.
    chunks: [RunIndex; 4],
    chunk_entries: [Vec<(GridBounds, usize)>; 4],
    margins: [Point; 4],
    /// Positions in `visible` holding runs without a cull bound.
    unbounded: Vec<usize>,
    /// (position in `visible`, run): sorted, this is painter order.
    selected: Vec<(usize, usize)>,
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
    pub(crate) fn bundle(&self, (resource, run): (usize, usize)) -> &BundleRun {
        &self.visible[resource].bundles[run]
    }
    pub(crate) fn run_count(&self) -> usize {
        self.run_count
    }
    pub(crate) fn selected(&self) -> &[(usize, usize)] {
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
    fn validate_order(&mut self, order: &[ChunkId]) -> Result<bool, GpuError> {
        let pending = self.pending.as_ref().ok_or_else(transaction_required)?;
        let overlay = self.pending_overlay.as_ref().expect("transaction overlay");
        let mut unchanged = self.visible.len() == order.len() + usize::from(overlay.is_some());
        self.seen.clear();
        self.seen.reserve(order.len());
        for (position, id) in order.iter().enumerate() {
            let Some(resource) = pending.get(id).filter(|_| self.seen.insert(*id)) else {
                return Err(GpuError::Surface(
                    "unknown or duplicate retained chunk key".into(),
                ));
            };
            unchanged &= self
                .visible
                .get(position)
                .is_some_and(|old| Arc::ptr_eq(old, resource));
        }
        if let Some(overlay) = overlay {
            unchanged &= self
                .visible
                .last()
                .is_some_and(|old| Arc::ptr_eq(old, overlay));
        }
        Ok(unchanged)
    }
    fn publish_order(&mut self, order: &[ChunkId], unchanged: bool) {
        if !unchanged {
            let pending = self.pending.as_ref().expect("validated transaction");
            self.visible_scratch
                .extend(order.iter().map(|id| pending[id].clone()));
            self.visible_scratch.extend(
                self.pending_overlay
                    .as_ref()
                    .expect("transaction overlay")
                    .iter()
                    .cloned(),
            );
            std::mem::swap(&mut self.visible, &mut self.visible_scratch);
            self.visible_scratch.clear();
            self.rebuild_index();
        }
    }
    fn begin(&mut self) {
        self.pending = Some(self.resources.clone());
        self.retiring.clear();
        self.removed.clear();
        self.pending_overlay = Some(self.overlay.clone());
    }
    /// Stage a prepared resource, remembering the published one it replaces.
    fn stage(&mut self, id: ChunkId, resource: Arc<Resource>) {
        let old = self
            .pending
            .as_mut()
            .expect("checked transaction")
            .insert(id, resource);
        self.retire(id, old);
    }
    fn remove(&mut self, id: ChunkId) -> Result<(), GpuError> {
        let pending = self.pending.as_mut().ok_or_else(transaction_required)?;
        if let Some(old) = pending.remove(&id) {
            self.removed.push(id);
            self.retire(id, Some(old));
        }
        Ok(())
    }
    /// A published resource leaves the transaction at most once: a key removed and
    /// staged again still recycles it.
    fn retire(&mut self, id: ChunkId, old: Option<Arc<Resource>>) {
        if let Some(old) = old
            && self
                .resources
                .get(&id)
                .is_some_and(|published| Arc::ptr_eq(published, &old))
        {
            self.retiring.push((id, old));
        }
    }
    /// Touches only what the transaction staged or removed, never the whole map, and
    /// drops nothing: retired resources and orphaned spares wait for `reclaim`.
    fn commit_resources(&mut self) {
        let resources = self.pending.take().expect("validated transaction");
        drop(std::mem::replace(&mut self.resources, resources));
        self.retired.extend(
            self.retiring
                .drain(..)
                .map(|(id, resource)| Retired::Resource(id, resource)),
        );
        for id in self.removed.drain(..) {
            if !self.resources.contains_key(&id)
                && let Some(spare) = self.spare.remove(&id)
            {
                self.retired.push_back(Retired::Spare {
                    _buffers: Box::new(spare),
                });
            }
        }
        self.overlay = self.pending_overlay.take().expect("transaction overlay");
    }
    /// Recycle (a replaced key's buffers become its spare) or drop up to `max`
    /// retired entries, oldest first; answers how many remain. A retired resource is
    /// never visible, so its buffers are safe to overwrite once it is unshared.
    fn reclaim(&mut self, max: usize) -> usize {
        for _ in 0..max {
            let Some(retired) = self.retired.pop_front() else {
                break;
            };
            if let Retired::Resource(id, resource) = retired
                && self
                    .resources
                    .get(&id)
                    .is_some_and(|current| !Arc::ptr_eq(current, &resource))
                && let Ok(resource) = Arc::try_unwrap(resource)
            {
                self.spare
                    .insert(id, (resource.buffers, resource.quad_buffer));
            }
        }
        self.retired.len()
    }
    fn needs_refresh(&self, viewport: Viewport, generation: u64) -> bool {
        self.refreshed != Some((viewport, generation))
    }
    /// O(chunks): runs were indexed when each chunk was prepared.
    fn rebuild_index(&mut self) {
        self.run_count = 0;
        self.unbounded.clear();
        self.cache_camera = None;
        self.follows = [false; 4];
        self.animated = false;
        self.paths = false;
        self.margins = [Point::ZERO; 4];
        for entries in &mut self.chunk_entries {
            entries.clear();
        }
        for (position, r) in self.visible.iter().enumerate() {
            self.animated |= r.frame.animated;
            self.paths |= r.frame.has_paths();
            for (dst, src) in self.follows.iter_mut().zip(r.follows) {
                *dst |= src;
            }
            self.run_count += r.bundles.len();
            if !r.index.unbounded.is_empty() {
                self.unbounded.push(position);
            }
            for (i, runs) in r.index.runs.iter().enumerate() {
                if let Some(bounds) = runs.bounds() {
                    let margin = r.index.margins[i];
                    self.margins[i].x = self.margins[i].x.max(margin.x);
                    self.margins[i].y = self.margins[i].y.max(margin.y);
                    self.chunk_entries[i].push((bounds, position));
                }
            }
        }
        for (index, entries) in self.chunks.iter_mut().zip(&mut self.chunk_entries) {
            index.nodes.clear();
            index.root = index.build(entries);
        }
    }
    pub(crate) fn select(&mut self, camera: Camera, vp: Viewport) {
        if self.cache_camera == Some(camera) {
            return;
        }
        self.selected.clear();
        for &position in &self.unbounded {
            self.selected.extend(
                self.visible[position]
                    .index
                    .unbounded
                    .iter()
                    .map(|&run| (position, run)),
            );
        }
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
                for position in self.chunks[i].leaves() {
                    self.selected.extend(
                        self.visible[position].index.runs[i]
                            .leaves()
                            .map(|run| (position, run)),
                    );
                }
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
            if let Some(root) = self.chunks[i].root {
                let (visible, selected) = (&self.visible, &mut self.selected);
                self.chunks[i].query(root, viewport, &mut |position| {
                    let runs = &visible[position].index.runs[i];
                    if let Some(root) = runs.root {
                        runs.query(root, viewport, &mut |run| selected.push((position, run)));
                    }
                });
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

    pub fn retained_publish_profile(&self) -> RetainedPublishProfile {
        self.retained.publish_profile
    }

    /// Start (or abandon and restart) a transaction from the last published set.
    pub fn begin_chunks(&mut self) {
        self.retained.begin();
    }

    /// Remove from the transaction; the published set remains untouched.
    pub fn remove_chunk(&mut self, id: ChunkId) -> Result<(), GpuError> {
        self.retained.remove(id)
    }

    /// Recycle or drop up to `max` resources earlier publications retired; answers how
    /// many remain. Publication only queues them and each building upsert reclaims a
    /// few; a host calls this from its idle or reclaim budget to finish sooner.
    pub fn reclaim_chunks(&mut self, max: usize) -> usize {
        self.retained.reclaim(max)
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
        let index = ChunkIndex::new(bundles.iter().map(|b| b.bounds));
        target.profile.bundle_ms = started.elapsed().as_secs_f64() * 1000.0;
        let mut follows = [false; 4];
        for batch in &frame.batches {
            follows[batch.follow.index()] = true;
        }
        Arc::new(Resource {
            quad_buffer,
            follows,
            bundles,
            index,
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
        target.retained.reclaim(RECLAIM_PER_UPSERT);
        let spare = target.retained.spare.remove(&id);
        let resource = self.chunk_resource(target, list, previous.as_deref(), spare, text);
        target.retained.stage(id, resource);
        target.retained.refreshed = None;
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
        if previous.is_none() && list.is_none() {
            return Ok(());
        }
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
        target.retained.refreshed = None;
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
        let started = crate::Instant::now();
        let mut profile = RetainedPublishProfile::default();
        let unchanged = target.retained.validate_order(order)?;
        profile.validation_ms = started.elapsed().as_secs_f64() * 1000.;
        let started = crate::Instant::now();
        target.retained.publish_order(order, unchanged);
        profile.index_ms = started.elapsed().as_secs_f64() * 1000.;
        profile.index_rebuilt = !unchanged;
        let started = crate::Instant::now();
        target.retained.commit_resources();
        target.retained.clear = crate::frame::premul64(clear);
        target.retained.active = true;
        target.uploaded = true;
        profile.swap_spare_ms = started.elapsed().as_secs_f64() * 1000.;
        let started = crate::Instant::now();
        self.refresh_chunks(target, text);
        profile.refresh_ms = started.elapsed().as_secs_f64() * 1000.;
        target.retained.publish_profile = profile;
        Ok(())
    }

    /// Call before a retained redraw when another surface may have reset the shared
    /// atlas, or after resize. The normal camera-only path does no builds/uploads.
    pub fn refresh_chunks(&self, target: &mut Target, text: &mut TextSystem) {
        if !target
            .retained
            .needs_refresh(target.viewport, text.atlas().generation())
        {
            self.upload_atlas(text);
            return;
        }
        let mut scene = std::mem::take(&mut target.retained);
        // Map pointer identities once so visible and staged aliases stay shared.
        let mut replacements = BTreeMap::<usize, Arc<Resource>>::new();
        for resource in scene
            .resources
            .values_mut()
            .chain(scene.overlay.iter_mut())
            .chain(scene.pending.iter_mut().flat_map(|p| p.values_mut()))
            .chain(scene.pending_overlay.iter_mut().filter_map(|p| p.as_mut()))
            .chain(scene.retiring.iter_mut().map(|(_, r)| r))
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
                    index: ChunkIndex::new(bundles.iter().map(|b| b.bounds)),
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
        scene.refreshed = Some((target.viewport, text.atlas().generation()));
        target.retained = scene;
        self.upload_atlas(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn bounds(x: f32, y: f32, w: f32, h: f32) -> GridBounds {
        GridBounds {
            min: Point::new(x, y),
            max: Point::new(x + w, y + h),
        }
    }
    fn bounded(world: Rect) -> Option<RunBounds> {
        Some(RunBounds {
            follow: Follow::BOTH,
            world,
            margin: Point::new(1., 1.),
        })
    }
    fn resource(runs: &[Option<RunBounds>], viewport: Viewport) -> Arc<Resource> {
        Arc::new(Resource {
            quad_buffer: None,
            follows: [false, false, false, true],
            bundles: Vec::new(),
            index: ChunkIndex::new(runs.iter().copied()),
            list: Arc::new(DisplayList::new(Rgba::BLACK)),
            frame: Frame::default(),
            buffers: Buffers::default(),
            generation: 7,
            atlas_dependent: true,
            viewport,
        })
    }

    #[test]
    fn two_level_query_preserves_painter_order_and_reuses_unchanged_camera_selection() {
        let vp = Viewport {
            width_px: 96,
            height_px: 64,
            scale: 1.,
        };
        let mut scene = Scene::default();
        // Chunk 0's second run lies left of its first: painter order is never spatial.
        scene.visible.push(resource(
            &[
                bounded(Rect::new(90., 8., 40., 40.)),
                bounded(Rect::new(8., 8., 40., 40.)),
            ],
            vp,
        ));
        scene.visible.push(resource(
            &[bounded(Rect::new(500., 8., 40., 40.)), None],
            vp,
        ));
        scene.rebuild_index();
        scene.select(Camera::IDENTITY, vp);
        assert_eq!(scene.selected, [(0, 0), (0, 1), (1, 1)]);
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
        assert_eq!(scene.selected, [(1, 0), (1, 1)]);
        scene.select(
            Camera {
                scale: Point::new(0., 1.),
                ..Camera::IDENTITY
            },
            vp,
        );
        assert_eq!(scene.selected, [(0, 0), (0, 1), (1, 0), (1, 1)]);
    }
    #[test]
    fn median_index_matches_brute_force_and_reuses_nodes() {
        let mut entries: Vec<_> = (0..1000)
            .map(|i| {
                let x = ((i * 7919) % 997) as f32 - 500.;
                let y = ((i * 104729) % 991) as f32 - 500.;
                (bounds(x, y, (i % 53) as f32, (i % 37) as f32), i)
            })
            .collect();
        entries.push((
            GridBounds {
                min: Point::new(-f32::MAX, -f32::MAX),
                max: Point::new(f32::MAX, f32::MAX),
            },
            entries.len(),
        ));
        let mut index = RunIndex::default();
        index.root = index.build(&mut entries);
        assert_eq!(index.nodes.len(), entries.len() * 2 - 1);
        let allocation = index.nodes.as_ptr();
        index.nodes.clear();
        entries.reverse();
        index.root = index.build(&mut entries);
        assert_eq!(allocation, index.nodes.as_ptr());
        for i in 0..100 {
            let x = (i * 17 % 1000) as f32 - 500.;
            let y = (i * 29 % 1000) as f32 - 500.;
            let viewport = bounds(x, y, 80., 60.);
            let mut selected = Vec::new();
            index.query(index.root.unwrap(), viewport, &mut |run| selected.push(run));
            selected.sort_unstable();
            let mut expected: Vec<_> = entries
                .iter()
                .filter(|(bounds, _)| bounds.intersects(viewport))
                .map(|(_, run)| *run)
                .collect();
            expected.sort_unstable();
            assert_eq!(selected, expected);
        }
        for entry in &mut entries {
            entry.0 = GridBounds::default();
        }
        index.nodes.clear();
        index.root = index.build(&mut entries);
        let mut selected = Vec::new();
        index.query(index.root.unwrap(), GridBounds::default(), &mut |run| {
            selected.push(run)
        });
        assert_eq!(selected.len(), entries.len());
        assert!(index.build(&mut []).is_none());
    }

    /// Chunk `id`'s three runs on a 40-column grid, `shift` along x.
    fn resident_runs(id: ChunkId, shift: f32) -> [GridBounds; 3] {
        let x = (id % 40) as f32 * 72. + shift;
        let y = (id / 40) as f32 * 32.;
        [0., 1., 2.].map(|run| bounds(x, y + run, 68., 28. - run))
    }
    fn resident(id: ChunkId, shift: f32, viewport: Viewport) -> Arc<Resource> {
        let runs = resident_runs(id, shift).map(|b| bounded(Rect::from_corners(b.min, b.max)));
        resource(&runs, viewport)
    }
    fn resident_scene() -> (Scene, Viewport, Vec<ChunkId>) {
        let viewport = Viewport {
            width_px: 320,
            height_px: 180,
            scale: 1.,
        };
        let mut scene = Scene::default();
        let order: Vec<_> = (0..1000).collect();
        for id in &order {
            scene.resources.insert(*id, resident(*id, 0., viewport));
        }
        scene
            .visible
            .extend(order.iter().map(|id| scene.resources[id].clone()));
        scene.rebuild_index();
        scene.refreshed = Some((viewport, 7));
        (scene, viewport, order)
    }

    #[test]
    fn two_level_selection_matches_every_run_and_same_order_keeps_the_index() {
        let (mut scene, viewport, order) = resident_scene();
        scene.begin();
        assert!(scene.validate_order(&[0, 0]).is_err());
        assert!(scene.validate_order(&[u64::MAX]).is_err());
        let unchanged = scene.validate_order(&order).unwrap();
        assert!(unchanged);
        let nodes = scene.chunks[3].nodes.as_ptr();
        let visible = scene.visible.as_ptr();
        scene.publish_order(&order, unchanged);
        scene.commit_resources();
        assert_eq!(nodes, scene.chunks[3].nodes.as_ptr());
        assert_eq!(visible, scene.visible.as_ptr());
        assert!(!scene.needs_refresh(viewport, 7));
        assert!(scene.needs_refresh(viewport, 8));
        assert!(scene.needs_refresh(
            Viewport {
                scale: 2.,
                ..viewport
            },
            7
        ));

        let mut reversed = order.clone();
        reversed.reverse();
        scene.begin();
        let unchanged = scene.validate_order(&reversed).unwrap();
        assert!(!unchanged);
        scene.publish_order(&reversed, unchanged);
        scene.commit_resources();
        assert_eq!(scene.run_count, 0, "test resources carry no bundles");
        let mut hits = 0;
        for i in 0..100 {
            let camera = Camera {
                scale: Point::new(1. + (i % 4) as f32 * 0.5, 1. + (i % 3) as f32 * 0.5),
                offset: Point::new(i as f32 * -19., i as f32 * -3.),
            };
            scene.select(camera, viewport);
            let (s, o) = (camera.scale, camera.offset);
            let view = GridBounds {
                min: Point::new((-o.x - 1.) / s.x, (-o.y - 1.) / s.y),
                max: Point::new(
                    (viewport.width_px as f32 - o.x + 1.) / s.x,
                    (viewport.height_px as f32 - o.y + 1.) / s.y,
                ),
            };
            let mut expected = Vec::new();
            for (position, id) in reversed.iter().enumerate() {
                for (run, b) in resident_runs(*id, 0.).iter().enumerate() {
                    if b.intersects(view) {
                        expected.push((position, run));
                    }
                }
            }
            assert_eq!(scene.selected, expected, "camera {i}");
            hits += expected.len();
        }
        assert!(hits > 1000);
    }

    #[test]
    fn commit_recycles_only_replaced_buffers_and_drops_removed_spares() {
        let (mut scene, viewport, order) = resident_scene();
        scene.spare.insert(2, Default::default());
        scene.spare.insert(3, Default::default());
        scene.begin();
        scene.stage(1, resident(1, 5., viewport));
        let staged = resident(1, 9., viewport);
        scene.stage(1, staged.clone());
        assert_eq!(scene.retiring.len(), 1, "a staged version retires nothing");
        scene.remove(2).unwrap();
        scene.remove(2).unwrap();
        scene.remove(5).unwrap();
        scene.stage(5, resident(5, 5., viewport));
        assert_eq!(scene.removed, [2, 5]);
        assert_eq!(
            scene.retiring.len(),
            3,
            "each published resource retires once"
        );
        let order: Vec<_> = order.into_iter().filter(|id| *id != 2).collect();
        let unchanged = scene.validate_order(&order).unwrap();
        scene.publish_order(&order, unchanged);
        scene.commit_resources();
        let spares = |scene: &Scene| {
            let mut spares: Vec<_> = scene.spare.keys().copied().collect();
            spares.sort_unstable();
            spares
        };
        assert_eq!(spares(&scene), [3], "commit drops and recycles nothing");
        assert_eq!(
            scene.retired.len(),
            4,
            "1, 2 and 5 retired; 2's spare orphaned"
        );
        assert!(Arc::ptr_eq(&scene.resources[&1], &staged));
        assert!(scene.retiring.is_empty() && scene.removed.is_empty());
        assert_eq!(scene.reclaim(1), 3, "oldest first, a bounded step");
        assert_eq!(spares(&scene), [1, 3]);
        assert_eq!(scene.reclaim(usize::MAX), 0);
        assert_eq!(
            spares(&scene),
            [1, 3, 5],
            "a removed and restaged key recycles too"
        );

        scene.begin();
        scene.stage(4, resident(4, 5., viewport));
        scene.begin();
        assert!(
            scene.retiring.is_empty(),
            "an abandoned transaction retires nothing"
        );
        assert!(scene.remove(4).is_ok());
        scene.pending = None;
        assert!(scene.remove(4).is_err());
    }

    #[test]
    fn retained_resident_bookkeeping_cost() {
        for mode in ["same-order", "band-change"] {
            let (mut scene, viewport, order) = resident_scene();
            let mut samples = Vec::new();
            let mut phases: [Vec<f64>; 4] = Default::default();
            for iteration in 0..140 {
                scene.begin();
                if mode == "band-change" {
                    // Prepared outside the timer, as budgeted upserts are.
                    let shift = (iteration % 2 + 1) as f32;
                    for id in &order {
                        scene.stage(*id, resident(*id, shift, viewport));
                    }
                }
                let started = std::time::Instant::now();
                let unchanged = scene.validate_order(&order).unwrap();
                let validation = started.elapsed().as_secs_f64() * 1000.;
                assert_eq!(unchanged, mode == "same-order");
                let phase = std::time::Instant::now();
                scene.publish_order(&order, unchanged);
                let index = phase.elapsed().as_secs_f64() * 1000.;
                let phase = std::time::Instant::now();
                scene.commit_resources();
                let swap = phase.elapsed().as_secs_f64() * 1000.;
                let phase = std::time::Instant::now();
                assert!(!std::hint::black_box(scene.needs_refresh(viewport, 7)));
                let refresh = phase.elapsed().as_secs_f64() * 1000.;
                // The next preparation's work, outside the publication.
                scene.reclaim(usize::MAX);
                if iteration >= 20 {
                    samples.push(started.elapsed().as_secs_f64() * 1000.);
                    for (values, value) in phases.iter_mut().zip([validation, index, swap, refresh])
                    {
                        values.push(value);
                    }
                }
            }
            if mode == "band-change" {
                assert_eq!(
                    scene.spare.len(),
                    order.len(),
                    "every replaced chunk recycles"
                );
            }
            samples.sort_by(f64::total_cmp);
            let p99 = samples[samples.len() * 99 / 100];
            println!(
                "resident_cpu mode={mode} chunks=1000 synthetic_runs=3000 p50_ms={:.3} p99_ms={p99:.3}",
                samples[samples.len() / 2]
            );
            for (name, values) in ["validation", "index", "swap_spare", "refresh_skip"]
                .into_iter()
                .zip(&mut phases)
            {
                values.sort_by(f64::total_cmp);
                println!(
                    "{name}_p50_ms={:.3} {name}_p99_ms={:.3}",
                    values[values.len() / 2],
                    values[values.len() * 99 / 100]
                );
            }
            assert!(p99 < 20., "{mode} bookkeeping p99 {p99:.3} ms >= 20 ms");
        }
    }

    #[test]
    #[ignore = "CPU-only index measurement: --profile perf -- --ignored --nocapture"]
    fn retained_index_build_cost() {
        for count in [1000, 10000] {
            let mut entries: Vec<_> = (0..count)
                .map(|i| {
                    let x = ((i * 7919) % 997) as f32 * 10.;
                    let y = ((i * 104729) % 991) as f32 * 10.;
                    (
                        GridBounds {
                            min: Point::new(x, y),
                            max: Point::new(x + 68., y + 28.),
                        },
                        i,
                    )
                })
                .collect();
            let mut index = RunIndex::default();
            let mut samples = Vec::new();
            for iteration in 0..140 {
                index.nodes.clear();
                let started = std::time::Instant::now();
                index.root = std::hint::black_box(index.build(&mut entries));
                let ms = started.elapsed().as_secs_f64() * 1000.;
                if iteration >= 20 {
                    samples.push(ms);
                }
            }
            samples.sort_by(f64::total_cmp);
            println!(
                "index_runs={count} p50_ms={:.3} p99_ms={:.3}",
                samples[samples.len() / 2],
                samples[samples.len() * 99 / 100],
            );
            assert!(samples[samples.len() * 99 / 100] < 20.);
        }
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
