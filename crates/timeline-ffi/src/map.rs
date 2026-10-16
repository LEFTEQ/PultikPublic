//! The estate map's C ABI (D11): Swift hands the map Semafor's boxes, apps, topology and backup
//! copies, gestures and arrow walks; the map lays out (a port of Semafor's `layout.ts`), hit-tests
//! and draws into the host's `CAMetalLayer`. Enum fields cross as Semafor's own words (`synced`,
//! `wireguard`, `storagebox`), parsed by the map: an unknown word is an error, never a guess.

use super::{
    Failure, TimelineHit, TimelinePalette, TimelineStatus, TimelineStr, call, owned, slice,
};
use canvas_draw::{Camera, Point, Size};
use canvas_gpu::{FrameOutcome, Gpu, Target};
use canvas_text::TextSystem;
use std::ffi::{c_char, c_void};
use std::sync::Arc;
use timeline::Palette;
use timeline::map::scene::{MAX_ZOOM, MIN_ZOOM, zoom_band};
use timeline::map::{
    BackupCopy, Dir, Estate, MapApp, MapBox, MapHit, MapScene, Rollout, TopologyEdge, TopologyNode,
    Wire,
};

/// A hit on a card (`id` its id), a link or a box's frame.
pub const TIMELINE_HIT_CARD: u8 = 5;
pub const TIMELINE_HIT_LINK: u8 = 6;
pub const TIMELINE_HIT_FRAME: u8 = 7;

/// An app on a box (`/api/v1/estate/map` `boxes[].apps`): `sync` and `health` in Semafor's words,
/// an empty `note` when none.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapApp {
    pub name: TimelineStr,
    pub sync: TimelineStr,
    pub health: TimelineStr,
    pub note: TimelineStr,
}

/// A rollout running on a box: through the gateway or not, its target and app (empty: none).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapRollout {
    pub gateway: bool,
    pub target: TimelineStr,
    pub app: TimelineStr,
}

/// A box: its name, `sync` word, address and header line (empty: none), apps and rollouts.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapBox {
    pub name: TimelineStr,
    pub sync: TimelineStr,
    pub addr: TimelineStr,
    pub line: TimelineStr,
    pub apps: *const TimelineMapApp,
    pub app_count: usize,
    pub rollouts: *const TimelineMapRollout,
    pub rollout_count: usize,
}

/// A topology node (`/api/v1/estate/topology` `nodes`): `kind` and `place` (empty: none) in
/// Semafor's words.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapNode {
    pub id: TimelineStr,
    pub kind: TimelineStr,
    pub label: TimelineStr,
    pub detail: TimelineStr,
    pub place: TimelineStr,
}

/// A topology edge: `kind` in Semafor's words; `targets` only when `has_targets`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapEdge {
    pub id: TimelineStr,
    pub from: TimelineStr,
    pub to: TimelineStr,
    pub kind: TimelineStr,
    pub label: TimelineStr,
    pub both: bool,
    pub has_targets: bool,
    pub targets: *const TimelineStr,
    pub target_count: usize,
}

/// One backup pipeline's copy at one place, whose state is not `none`: `place` and `state` in
/// Semafor's words, `age_s` NaN when unknown, an empty `location` when none.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct TimelineMapCopy {
    pub box_name: TimelineStr,
    pub pipeline: TimelineStr,
    pub place: TimelineStr,
    pub state: TimelineStr,
    pub location: TimelineStr,
    pub age_s: f64,
}

/// One map on screen.
pub struct TimelineMapHandle {
    palette: Palette,
    scene: Option<MapScene>,
    text: TextSystem,
    renderer: Option<(Gpu, Target)>,
    size: Size,
    camera: Camera,
    fitted: bool,
    selected: Option<Arc<str>>,
    /// Bumped when the estate, palette or selection changes: what was emitted is stale.
    generation: u64,
    /// The zoom band and generation last emitted, and the camera last drawn.
    emitted: Option<(f32, u64)>,
    drawn: Option<Camera>,
}

/// # Safety
/// `h` is null (refused) or a live map handle used by this thread alone.
unsafe fn map<'a>(h: *mut TimelineMapHandle) -> Result<&'a mut TimelineMapHandle, Failure> {
    // SAFETY: per this function's contract.
    unsafe { h.as_mut() }.ok_or(Failure::Invalid("a null map handle"))
}

/// # Safety
/// As [`TimelineStr::text`].
unsafe fn word<T: Wire>(s: TimelineStr, what: &str) -> Result<T, Failure> {
    // SAFETY: per this function's contract.
    let w = unsafe { s.text() }?;
    T::from_wire(&w).ok_or_else(|| Failure::Engine(format!("an unknown {what} '{w}'")))
}

/// # Safety
/// As [`TimelineStr::text`].
unsafe fn some(s: TimelineStr) -> Result<Option<Arc<str>>, Failure> {
    // SAFETY: per this function's contract.
    let t = unsafe { s.text() }?;
    Ok((!t.is_empty()).then_some(t))
}

/// A new, empty map drawn in `palette`. Free it with timeline_map_free.
///
/// # Safety
/// `palette` and `out` are valid; `error` is null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_new(
    palette: *const TimelinePalette,
    out: *mut *mut TimelineMapHandle,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let palette = unsafe { palette.as_ref() }.ok_or(Failure::Invalid("a null palette"))?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let h = Box::new(TimelineMapHandle {
            palette: (*palette).into(),
            scene: None,
            text: TextSystem::new(),
            renderer: None,
            size: Size::new(800.0, 600.0),
            camera: Camera::IDENTITY,
            fitted: false,
            selected: None,
            generation: 0,
            emitted: None,
            drawn: None,
        });
        // SAFETY: checked non-null above.
        unsafe { *out = Box::into_raw(h) };
        Ok(())
    })
}

/// Free a map (and its GPU device, when attached).
///
/// # Safety
/// `h` is null or a map handle, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_free(h: *mut TimelineMapHandle) {
    if !h.is_null() {
        // SAFETY: per this function's contract.
        drop(unsafe { Box::from_raw(h) });
    }
}

/// Draw into `layer` (a `CAMetalLayer *`), `width` × `height` points at `scale`.
///
/// # Safety
/// `h` is a live map; `layer` is a valid CAMetalLayer that outlives the attachment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_attach(
    h: *mut TimelineMapHandle,
    layer: *mut c_void,
    width: f64,
    height: f64,
    scale: f64,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { map(h) }?;
        if layer.is_null() {
            return Err(Failure::Invalid("a null layer"));
        }
        let gpu = Gpu::new().map_err(|e| Failure::Engine(e.to_string()))?;
        #[cfg(target_vendor = "apple")]
        // SAFETY: the caller's contract: a valid CAMetalLayer that outlives the target.
        let target = unsafe {
            gpu.create_layer_target(layer, canvas_gpu::Compositing::Opaque, width, height, scale)
        }
        .map_err(|e| Failure::Engine(e.to_string()))?;
        #[cfg(not(target_vendor = "apple"))]
        let target: Target = {
            let _ = (width, height, scale);
            return Err(Failure::Engine("layers are Apple-only".into()));
        };
        h.size = Size::new(width as f32, height as f32);
        let mut target = target;
        // As the timeline's: the host's display link paces frames (AC 8).
        gpu.set_vsync(&mut target, false);
        h.renderer = Some((gpu, target));
        h.emitted = None;
        h.drawn = None;
        Ok(())
    })
}

/// Release the GPU device; the estate and the camera stay.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_detach(h: *mut TimelineMapHandle) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.renderer = None;
        h.emitted = None;
        h.drawn = None;
    }
}

/// The surface is now `width` × `height` points at `scale`.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_resize(
    h: *mut TimelineMapHandle,
    width: f64,
    height: f64,
    scale: f64,
) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.size = Size::new(width as f32, height as f32);
        if let Some((gpu, target)) = &mut h.renderer {
            gpu.resize(target, width, height, scale);
        }
        h.drawn = None;
        h.emitted = None;
    }
}

/// Replace the estate the map draws. `copies_loaded` false: the backups did not load (their
/// cards say so). The camera fits the map the first time it has one.
///
/// # Safety
/// `h` is a live map; every array is valid for its count, every text for the call.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn timeline_map_set_estate(
    h: *mut TimelineMapHandle,
    boxes: *const TimelineMapBox,
    box_count: usize,
    nodes: *const TimelineMapNode,
    node_count: usize,
    edges: *const TimelineMapEdge,
    edge_count: usize,
    copies: *const TimelineMapCopy,
    copy_count: usize,
    copies_loaded: bool,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract, for every read below.
        unsafe {
            let h = map(h)?;
            let mut estate = Estate {
                boxes: Vec::with_capacity(box_count),
                nodes: Vec::with_capacity(node_count),
                edges: Vec::with_capacity(edge_count),
                copies: None,
            };
            for b in slice(boxes, box_count)? {
                let mut apps = Vec::with_capacity(b.app_count);
                for a in slice(b.apps, b.app_count)? {
                    apps.push(MapApp {
                        name: a.name.text()?,
                        sync: word(a.sync, "app sync")?,
                        health: word(a.health, "health")?,
                        note: some(a.note)?,
                    });
                }
                let mut rollouts = Vec::with_capacity(b.rollout_count);
                for r in slice(b.rollouts, b.rollout_count)? {
                    rollouts.push(Rollout {
                        gateway: r.gateway,
                        target: some(r.target)?,
                        app: some(r.app)?,
                    });
                }
                estate.boxes.push(MapBox {
                    name: b.name.text()?,
                    sync: word(b.sync, "box sync")?,
                    addr: some(b.addr)?,
                    line: some(b.line)?,
                    apps,
                    rollouts,
                });
            }
            for n in slice(nodes, node_count)? {
                let place = match some(n.place)? {
                    Some(p) => Some(word(n.place, &format!("copy place '{p}' of"))?),
                    None => None,
                };
                estate.nodes.push(TopologyNode {
                    id: n.id.text()?,
                    kind: word(n.kind, "node kind")?,
                    label: n.label.text()?,
                    detail: n.detail.text()?,
                    place,
                });
            }
            for e in slice(edges, edge_count)? {
                let targets = if e.has_targets {
                    let mut t = Vec::with_capacity(e.target_count);
                    for s in slice(e.targets, e.target_count)? {
                        t.push(s.text()?);
                    }
                    Some(t)
                } else {
                    None
                };
                estate.edges.push(TopologyEdge {
                    id: e.id.text()?,
                    from: e.from.text()?,
                    to: e.to.text()?,
                    kind: word(e.kind, "link kind")?,
                    both: e.both,
                    label: e.label.text()?,
                    targets,
                });
            }
            if copies_loaded {
                let mut out = Vec::with_capacity(copy_count);
                for c in slice(copies, copy_count)? {
                    out.push(BackupCopy {
                        box_name: c.box_name.text()?,
                        pipeline: c.pipeline.text()?,
                        place: word(c.place, "copy place")?,
                        state: word(c.state, "copy state")?,
                        age_s: c.age_s.is_finite().then_some(c.age_s),
                        location: some(c.location)?,
                    });
                }
                estate.copies = Some(out);
            }
            match &mut h.scene {
                Some(scene) => {
                    scene.update(&estate);
                }
                None => h.scene = Some(MapScene::new(&estate)),
            }
            h.generation += 1;
            Ok(())
        }
    })
}

/// Recolour (the host's theme changed).
///
/// # Safety
/// `h` is null or a live map; `palette` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_set_palette(
    h: *mut TimelineMapHandle,
    palette: *const TimelinePalette,
) {
    // SAFETY: per this function's contract.
    if let (Some(h), Some(p)) = unsafe { (h.as_mut(), palette.as_ref()) } {
        h.palette = (*p).into();
        h.generation += 1;
    }
}

/// Two fingers moved the map by (`dx`, `dy`) points.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_scroll(h: *mut TimelineMapHandle, dx: f64, dy: f64) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        h.camera.offset = Point::new(h.camera.offset.x + dx as f32, h.camera.offset.y + dy as f32);
    }
}

/// A pinch by `factor` around view point (`x`, `y`).
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_magnify(
    h: *mut TimelineMapHandle,
    factor: f64,
    x: f64,
    y: f64,
) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() } {
        let at = Point::new(x as f32, y as f32);
        let world = h.camera.unapply(at);
        let k = (h.camera.scale.x * factor as f32).clamp(MIN_ZOOM, MAX_ZOOM);
        h.camera = Camera {
            scale: Point::new(k, k),
            offset: Point::new(at.x - world.x * k, at.y - world.y * k),
        };
    }
}

/// Fit the whole map in the view again.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_fit(h: *mut TimelineMapHandle) {
    // SAFETY: per this function's contract.
    if let Some(h) = unsafe { h.as_mut() }
        && let Some(scene) = &h.scene
    {
        h.camera = scene.fit(h.size);
        h.fitted = true;
    }
}

/// An arrow: walk to the nearest card that way (`dir` 0 up, 1 down, 2 left, 3 right), from the
/// selection or the first card, and bring it into view.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_walk(h: *mut TimelineMapHandle, dir: u8) {
    // SAFETY: per this function's contract.
    let Some(h) = (unsafe { h.as_mut() }) else {
        return;
    };
    let Some(scene) = &h.scene else {
        return;
    };
    let dir = match dir {
        0 => Dir::Up,
        1 => Dir::Down,
        2 => Dir::Left,
        _ => Dir::Right,
    };
    let next = match &h.selected {
        Some(from) => scene.walk(from, dir).or_else(|| Some(from.clone())),
        None => scene.first().cloned(),
    };
    if let Some(id) = next {
        h.camera = scene.reveal(h.camera, h.size, &id);
        h.selected = Some(id);
        h.generation += 1;
    }
}

/// Select the card `id` (empty: clear it).
///
/// # Safety
/// `h` is a live map; `id` is valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_select(
    h: *mut TimelineMapHandle,
    id: TimelineStr,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let (h, id) = unsafe { (map(h)?, id.text()?) };
        h.selected = (!id.is_empty()).then_some(id);
        h.generation += 1;
        Ok(())
    })
}

/// The selected card's id as an owned string (free with timeline_string_free), or null.
///
/// # Safety
/// `h` is null or a live map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_selected(h: *mut TimelineMapHandle) -> *mut c_char {
    // SAFETY: per this function's contract.
    unsafe { h.as_ref() }
        .and_then(|h| h.selected.as_deref())
        .map_or(std::ptr::null_mut(), owned)
}

/// What ↵ opens: the selected card's live app, as owned `box_name` and `app` strings (free
/// both with timeline_string_free). False, and both null, when the selection is no live app.
///
/// # Safety
/// `h` is null or a live map; `box_name` and `app` are valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_selected_app(
    h: *mut TimelineMapHandle,
    box_name: *mut *mut c_char,
    app: *mut *mut c_char,
) -> bool {
    if box_name.is_null() || app.is_null() {
        return false;
    }
    // SAFETY: checked non-null; the caller's contract for `h`.
    unsafe {
        *box_name = std::ptr::null_mut();
        *app = std::ptr::null_mut();
        let Some(h) = h.as_ref() else { return false };
        let Some((name, live)) = h
            .selected
            .as_deref()
            .and_then(|id| h.scene.as_ref()?.app_of(id))
        else {
            return false;
        };
        *box_name = owned(name);
        *app = owned(&live.name);
        true
    }
}

/// What view point (`x`, `y`) is on: a card, a link or a frame (their id in `id`).
///
/// # Safety
/// `h` is a live map; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_hit(
    h: *mut TimelineMapHandle,
    x: f64,
    y: f64,
    out: *mut TimelineHit,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { map(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let world = h.camera.unapply(Point::new(x as f32, y as f32));
        let hit = h
            .scene
            .as_ref()
            .and_then(|s| s.hit(world, h.camera.scale.x));
        let (kind, id) = match hit {
            None => (super::TIMELINE_HIT_NONE, std::ptr::null_mut()),
            Some(MapHit::Card(id)) => (TIMELINE_HIT_CARD, owned(&id)),
            Some(MapHit::Link(id)) => (TIMELINE_HIT_LINK, owned(&id)),
            Some(MapHit::Frame(id)) => (TIMELINE_HIT_FRAME, owned(&id)),
        };
        // SAFETY: checked non-null above.
        unsafe {
            out.write(TimelineHit {
                kind,
                id,
                from: f64::NAN,
                to: f64::NAN,
            })
        };
        Ok(())
    })
}

/// Draw a frame if anything changed: emit the map again when the zoom band, the estate or the
/// selection changed, else move the camera. `animating` keeps the display link running (a
/// deploy flows).
///
/// # Safety
/// `h` is a live map; `out` is valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timeline_map_frame(
    h: *mut TimelineMapHandle,
    out: *mut super::TimelineFrame,
    error: *mut *mut c_char,
) -> TimelineStatus {
    call(error, || {
        // SAFETY: per this function's contract.
        let h = unsafe { map(h) }?;
        if out.is_null() {
            return Err(Failure::Invalid("a null out parameter"));
        }
        let mut frame = super::TimelineFrame::default();
        if let (Some(scene), Some((gpu, target))) = (&h.scene, &mut h.renderer) {
            if !h.fitted {
                h.camera = scene.fit(h.size);
                h.fitted = true;
            }
            let band = zoom_band(h.camera.scale.x);
            if h.emitted != Some((band, h.generation)) {
                let dl = scene.emit(&h.palette, &mut h.text, band, h.selected.as_deref());
                gpu.set_camera(target, h.camera);
                frame.built = true;
                frame.presented = gpu
                    .render(target, &dl, &mut h.text)
                    .map_err(|e| Failure::Engine(e.to_string()))?
                    == FrameOutcome::Presented;
                h.emitted = Some((band, h.generation));
                h.drawn = Some(h.camera);
            } else if h.drawn != Some(h.camera) || target.animating() {
                gpu.set_camera(target, h.camera);
                frame.presented = gpu
                    .redraw(target)
                    .map_err(|e| Failure::Engine(e.to_string()))?
                    == FrameOutcome::Presented;
                h.drawn = Some(h.camera);
            }
            frame.animating = target.animating();
        }
        // SAFETY: checked non-null above.
        unsafe { out.write(frame) };
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(text: &'static str) -> TimelineStr {
        TimelineStr {
            ptr: text.as_ptr(),
            len: text.len(),
        }
    }

    fn palette() -> TimelinePalette {
        let c = super::super::TimelineRgba {
            r: 0.5,
            g: 0.5,
            b: 0.5,
            a: 1.0,
        };
        TimelinePalette {
            background: c,
            band: c,
            foreground: c,
            muted: c,
            grid: c,
            data: c,
            ok: c,
            danger: c,
            warning: c,
            accent: c,
        }
    }

    #[test]
    fn a_map_takes_an_estate_walks_its_cards_and_refuses_an_unknown_word() {
        let apps = [
            TimelineMapApp {
                name: s("exampleapp"),
                sync: s("synced"),
                health: s("healthy"),
                note: s(""),
            },
            TimelineMapApp {
                name: s("vitrinka"),
                sync: s("synced"),
                health: s("healthy"),
                note: s(""),
            },
        ];
        let mut b = TimelineMapBox {
            name: s("app-server"),
            sync: s("synced"),
            addr: s(""),
            line: s(""),
            apps: apps.as_ptr(),
            app_count: 2,
            rollouts: std::ptr::null(),
            rollout_count: 0,
        };
        let mut h = std::ptr::null_mut();
        let none: *const u8 = std::ptr::null();
        // SAFETY: valid pointers for every call below.
        unsafe {
            assert_eq!(
                timeline_map_new(&palette(), &mut h, std::ptr::null_mut()),
                0
            );
            let ok = timeline_map_set_estate(
                h,
                &b,
                1,
                none.cast(),
                0,
                none.cast(),
                0,
                none.cast(),
                0,
                false,
                std::ptr::null_mut(),
            );
            assert_eq!(ok, 0);
            timeline_map_walk(h, 3);
            let first = timeline_map_selected(h);
            assert!(
                !first.is_null(),
                "a walk from nothing lands on the first card"
            );
            super::super::timeline_string_free(first);
            let (mut bx, mut app) = (std::ptr::null_mut(), std::ptr::null_mut());
            assert!(timeline_map_selected_app(h, &mut bx, &mut app));
            assert_eq!(std::ffi::CStr::from_ptr(bx).to_str(), Ok("app-server"));
            super::super::timeline_string_free(bx);
            super::super::timeline_string_free(app);
            b.sync = s("sideways");
            let mut err = std::ptr::null_mut();
            let bad = timeline_map_set_estate(
                h,
                &b,
                1,
                none.cast(),
                0,
                none.cast(),
                0,
                none.cast(),
                0,
                false,
                &mut err,
            );
            assert_ne!(bad, 0);
            assert!(
                std::ffi::CStr::from_ptr(err)
                    .to_string_lossy()
                    .contains("sideways")
            );
            super::super::timeline_string_free(err);
            timeline_map_free(h);
        }
    }
}
