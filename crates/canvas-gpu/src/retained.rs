//! Ordered, keyed display lists on the existing target and pipelines.
//!
//! Preparation is independent of publication: replacement buffers never overwrite a
//! visible resource. Each list is self-contained (balanced clip/camera operations).
use crate::{Buffers, Frame, Gpu, GpuError, Target, Viewport};
use canvas_draw::{DisplayList, Rgba};
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

pub(crate) struct BundleRun {
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
    pub(crate) fn bundles(&self) -> impl Iterator<Item = &BundleRun> {
        self.visible.iter().flat_map(|r| &r.bundles)
    }
    pub(crate) fn follows(&self) -> [bool; 4] {
        let mut mask = [false; 4];
        for r in &self.visible {
            for (dst, src) in mask.iter_mut().zip(r.follows) {
                *dst |= src;
            }
        }
        mask
    }
    pub(crate) fn animated(&self) -> bool {
        self.visible.iter().any(|r| r.frame.animated)
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
        target.retained = scene;
        self.upload_atlas(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
