//! The estate map (D11): Semafor's live map — every box a frame holding its apps, the stores,
//! GitHub and trezorlinka around them, joined by the topology's links (WireGuard, telemetry,
//! deploys, backups, keys, restore drills) — laid out by a faithful port of Semafor's
//! `layout.ts` and drawn on the canvas crates, pannable and pinchable, its arrows walking the
//! cards.
//!
//! [`Estate`] is what Semafor serves (`/estate/map`, `/estate/topology`, and the backup copies
//! of `/estate/backups`), in plain Rust names. [`Graph::build`] turns it into cards, frames
//! and links exactly as Semafor's Estate map does (`buildEstateGraph`), [`layout`] places them
//! and [`scene::MapScene`] draws, hits and walks them.
//!
//! Units: world points, Semafor's CSS pixels at zoom 1, from the drawing's top-left (its
//! margin included); ages in seconds.
//!
//! | Module | Is |
//! |---|---|
//! | [`layout`] | Ranks, packed group grids, barycentric order, coordinates (`layoutGraph`) |
//! | [`route`] | Edge routes: facing cubics, bundled trunks, stems, same-column loops |
//! | [`scene`] | The drawn map: emission, hit testing, arrow walking, fitting the camera |

pub mod layout;
pub mod route;
pub mod scene;

pub use layout::{
    DEFAULT_LAYOUT, GraphLayout, Keyed, LayoutGroup, LayoutItem, LayoutLink, LayoutOptions,
    Point64, Rect64, layout_graph,
};
pub use route::{EdgeRoute, RouteVerb};
pub use scene::{Dir, LinkKinds, MapHit, MapScene};

use std::cmp::Ordering;
use std::collections::HashSet;
use std::sync::Arc;

/// Semafor's words for a state, parsed (`None` for a word it does not know yet).
pub trait Wire: Sized {
    fn from_wire(s: &str) -> Option<Self>;
}

macro_rules! wire_enum {
    ($(#[$m:meta])* $name:ident { $($variant:ident = $word:literal),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[repr(u8)]
        pub enum $name { $($variant),+ }

        impl Wire for $name {
            fn from_wire(s: &str) -> Option<Self> {
                match s { $($word => Some($name::$variant),)+ _ => None }
            }
        }
    };
}

wire_enum! {
    /// A box's reconciler state (`/estate/map` `boxes[].sync`).
    BoxSync { Synced = "synced", Seeded = "seeded", Rolling = "rolling", Pending = "pending",
        Held = "held", Errors = "errors", Pinned = "pinned", Unreachable = "unreachable" }
}

wire_enum! {
    /// An app's convergence on its box (`apps[].sync`).
    AppSync { Synced = "synced", Pending = "pending", Held = "held", CertHeld = "cert_held",
        Roll = "roll", Error = "error", Live = "live", Elsewhere = "elsewhere" }
}

wire_enum! {
    Health { Healthy = "healthy", Degraded = "degraded", Down = "down", Unknown = "unknown" }
}

wire_enum! {
    /// A topology node's kind; boxes become frames, the rest cards.
    NodeKind { Box = "box", ExternalBox = "external-box", External = "external", Storage = "storage" }
}

wire_enum! {
    /// Where a backup copy lives (a storage node's `place`).
    CopyPlace { StorageBox = "storage_box", S3 = "s3", Vault = "vault" }
}

wire_enum! {
    /// A topology link's kind, in Semafor's legend order.
    LinkKind { Wireguard = "wireguard", Telemetry = "telemetry", Observe = "observe", Ci = "ci",
        Deploy = "deploy", Backup = "backup", Data = "data", Keystore = "keystore",
        Restore = "restore", Errors = "errors" }
}

wire_enum! {
    /// A backup copy's age against its pipeline's max age.
    Freshness { Fresh = "fresh", Near = "near", Stale = "stale" }
}

impl LinkKind {
    pub const ALL: [LinkKind; 10] = [
        LinkKind::Wireguard,
        LinkKind::Telemetry,
        LinkKind::Observe,
        LinkKind::Ci,
        LinkKind::Deploy,
        LinkKind::Backup,
        LinkKind::Data,
        LinkKind::Keystore,
        LinkKind::Restore,
        LinkKind::Errors,
    ];

    /// Links that place things left to right; the rest (feedback, tunnels, drills) are drawn
    /// but never rank.
    pub fn ranks(self) -> bool {
        matches!(
            self,
            LinkKind::Ci
                | LinkKind::Deploy
                | LinkKind::Backup
                | LinkKind::Data
                | LinkKind::Keystore
        )
    }

    /// Semafor's `LINK_STYLE`: dashed or solid, and its arrowheads.
    pub fn style(self) -> (bool, Arrow) {
        match self {
            LinkKind::Wireguard => (true, Arrow::None),
            LinkKind::Observe | LinkKind::Restore => (true, Arrow::End),
            _ => (false, Arrow::End),
        }
    }
}

impl Freshness {
    fn rank(self) -> u8 {
        self as u8
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arrow {
    End,
    Both,
    None,
}

/// One app on a box (`boxes[].apps[]`).
#[derive(Debug, Clone, PartialEq)]
pub struct MapApp {
    pub name: Arc<str>,
    pub sync: AppSync,
    pub health: Health,
    /// Why it is in its state ("compose converged, container not recreated").
    pub note: Option<Arc<str>>,
}

/// A rollout running on a box now (`boxes[].live_rollouts[]`).
#[derive(Debug, Clone, PartialEq)]
pub struct Rollout {
    /// A deploy-gateway verb (`kind == "gateway"`): what flows along deploy links.
    pub gateway: bool,
    /// The gateway target it runs, what a deploy link's `targets` lists.
    pub target: Option<Arc<str>>,
    /// The app it converges or deploys.
    pub app: Option<Arc<str>>,
}

/// One box the live map observes (`boxes[]`).
#[derive(Debug, Clone, PartialEq)]
pub struct MapBox {
    pub name: Arc<str>,
    pub sync: BoxSync,
    /// Its admin address, shown beside its name.
    pub addr: Option<Arc<str>>,
    /// The header's second line, set by the host: the pin, the live rollout or the applied
    /// commit's subject (Semafor's `FrameHeader`).
    pub line: Option<Arc<str>>,
    pub apps: Vec<MapApp>,
    pub rollouts: Vec<Rollout>,
}

/// A node of the topology manifest (`/estate/topology` `nodes[]`).
#[derive(Debug, Clone, PartialEq)]
pub struct TopologyNode {
    /// `box:<name>`, `store:<…>`, `ext:<…>`.
    pub id: Arc<str>,
    pub kind: NodeKind,
    pub label: Arc<str>,
    pub detail: Arc<str>,
    /// Where its backup copies are counted, for a storage node.
    pub place: Option<CopyPlace>,
}

/// A link of the topology manifest (`edges[]`); `app:<box>/<app>` ends resolve against the map.
#[derive(Debug, Clone, PartialEq)]
pub struct TopologyEdge {
    pub id: Arc<str>,
    pub from: Arc<str>,
    pub to: Arc<str>,
    pub kind: LinkKind,
    /// `direction == "both"`: drawn without arrowheads.
    pub both: bool,
    pub label: Arc<str>,
    /// The deploy-gateway targets a deploy link carries; `None`: every one (the CI hop).
    pub targets: Option<Vec<Arc<str>>>,
}

/// One backup pipeline's copy at one place (`/estate/backups` `pipelines[].places[place]`,
/// only those whose state is not `none`).
#[derive(Debug, Clone, PartialEq)]
pub struct BackupCopy {
    pub box_name: Arc<str>,
    pub pipeline: Arc<str>,
    pub place: CopyPlace,
    pub state: Freshness,
    /// Since its last good write, seconds.
    pub age_s: Option<f64>,
    /// Where the copy says it is (a bucket's name for S3).
    pub location: Option<Arc<str>>,
}

/// Everything the map is drawn from.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Estate {
    pub boxes: Vec<MapBox>,
    pub nodes: Vec<TopologyNode>,
    pub edges: Vec<TopologyEdge>,
    /// `None`: the backups did not load (backup links and stores keep their neutral tone).
    pub copies: Option<Vec<BackupCopy>>,
}

/// The backup copies one store, or one box's backup link, carries (Semafor's `Copies`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Copies {
    /// The worst among them; `None` when none is there.
    pub state: Option<Freshness>,
    pub pipelines: usize,
    /// The oldest last-good write among them, seconds.
    pub worst_age_s: Option<f64>,
    /// Every one was matched by its bucket (not only by its place).
    pub by_bucket: bool,
}

/// Card and frame sizes, Semafor's Estate map's.
pub const APP_W: f64 = 188.0;
pub const APP_H: f64 = 46.0;
pub const HEADER_H: f64 = 76.0;

/// The Estate map's layout: `DEFAULT_LAYOUT` with that screen's `MAP_LAYOUT` over it.
pub const MAP_LAYOUT: LayoutOptions = LayoutOptions {
    rank_gap: 120.0,
    inner_rank_gap: 16.0,
    node_gap: 10.0,
    group_gap: 40.0,
    pack_rows: 9,
    margin: 32.0,
    ..DEFAULT_LAYOUT
};

/// What a card shows.
#[derive(Debug, Clone, PartialEq)]
pub enum CardKind {
    /// An app on a box. `app` is `None` for one the topology names but the live map lacks (a
    /// dashed "declared" card).
    App {
        box_name: Arc<str>,
        name: Arc<str>,
        app: Option<MapApp>,
        /// Its box answered (an unreachable box's apps fade, "last known").
        reachable: bool,
    },
    /// A store, GitHub, trezorlinka: a topology node outside the boxes.
    Place {
        node: TopologyNode,
        copies: Option<Copies>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Card {
    pub id: Arc<str>,
    /// The frame holding it.
    pub frame: Option<Arc<str>>,
    pub w: f64,
    pub h: f64,
    pub what: CardKind,
}

/// A box's frame.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    /// `box:<name>`.
    pub id: Arc<str>,
    pub name: Arc<str>,
    pub header: f64,
    /// `None`: the topology declares the box but the live map does not show it.
    pub live: Option<MapBox>,
    pub topo: Option<TopologyNode>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Link {
    pub id: Arc<str>,
    pub from: Arc<str>,
    pub to: Arc<str>,
    pub kind: LinkKind,
    /// Ranks its ends left to right.
    pub constrain: bool,
    pub dashed: bool,
    pub arrow: Arrow,
    /// A backup link's copies: its colour is their worst freshness.
    pub copies: Option<Copies>,
    /// A deploy rolls one of its targets now: it flows.
    pub deploying: bool,
    pub label: Arc<str>,
}

/// The cards, frames and links of one map, in Semafor's order (which the layout reads).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Graph {
    pub cards: Vec<Card>,
    pub frames: Vec<Frame>,
    pub links: Vec<Link>,
}

/// What the layout reads of a graph: its structure, never a state colour.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LayoutInput {
    pub items: Vec<LayoutItem>,
    pub groups: Vec<LayoutGroup>,
    pub links: Vec<LayoutLink>,
}

impl LayoutInput {
    pub fn layout(&self, o: &LayoutOptions) -> GraphLayout {
        layout_graph(&self.items, &self.groups, &self.links, o)
    }
}

/// `app:<box>/<app>` split, else `None`.
pub fn app_endpoint(id: &str) -> Option<(&str, &str)> {
    let rest = id.strip_prefix("app:")?;
    let (b, a) = rest.split_once('/')?;
    (!b.is_empty() && !a.is_empty()).then_some((b, a))
}

impl Graph {
    /// Semafor's `buildEstateGraph`: a frame per live box (its apps sorted by name, owned
    /// elsewhere last, so a card keeps its place when its state changes), an empty frame per
    /// box only the topology knows, a card per other topology node, a dashed card per app a
    /// link names that the map lacks, and every link whose both ends exist.
    pub fn build(e: &Estate) -> Graph {
        let mut g = Graph::default();
        let mut ids: HashSet<Arc<str>> = HashSet::new();
        for b in &e.boxes {
            let id: Arc<str> = format!("box:{}", b.name).into();
            g.frames.push(Frame {
                id: id.clone(),
                name: b.name.clone(),
                header: HEADER_H,
                live: Some(b.clone()),
                topo: e.nodes.iter().find(|n| n.id == id).cloned(),
            });
            ids.insert(id.clone());
            let reachable = b.sync != BoxSync::Unreachable;
            let mut apps: Vec<&MapApp> = b.apps.iter().collect();
            apps.sort_by(|x, y| by_place(x, y));
            for a in apps {
                let nid: Arc<str> = format!("app:{}/{}", b.name, a.name).into();
                g.cards.push(Card {
                    id: nid.clone(),
                    frame: Some(id.clone()),
                    w: APP_W,
                    h: APP_H,
                    what: CardKind::App {
                        box_name: b.name.clone(),
                        name: a.name.clone(),
                        app: Some(a.clone()),
                        reachable,
                    },
                });
                ids.insert(nid);
            }
        }
        // A box the manifest knows but the live map does not: an empty frame that says so.
        for t in &e.nodes {
            if t.kind != NodeKind::Box || ids.contains(&t.id) {
                continue;
            }
            g.frames.push(Frame {
                id: t.id.clone(),
                name: t.id.chars().skip(4).collect::<String>().into(),
                header: HEADER_H,
                live: None,
                topo: Some(t.clone()),
            });
            ids.insert(t.id.clone());
        }
        for t in &e.nodes {
            if t.kind == NodeKind::Box {
                continue;
            }
            let copies = match (&e.copies, t.place) {
                (Some(c), Some(_)) => Some(copies_in(c, t, None)),
                _ => None,
            };
            let (w, h) = match t.kind {
                NodeKind::Storage => (240.0, 58.0),
                NodeKind::ExternalBox => (228.0, 62.0),
                _ => (208.0, 58.0),
            };
            g.cards.push(Card {
                id: t.id.clone(),
                frame: None,
                w,
                h,
                what: CardKind::Place {
                    node: t.clone(),
                    copies,
                },
            });
            ids.insert(t.id.clone());
        }

        for edge in &e.edges {
            // An app the manifest names but the live map lacks: a dashed card in its box.
            for end in [&edge.from, &edge.to] {
                if ids.contains(end) {
                    continue;
                }
                let Some((bx, app)) = app_endpoint(end) else {
                    continue;
                };
                let frame: Arc<str> = format!("box:{bx}").into();
                g.cards.push(Card {
                    id: end.clone(),
                    frame: ids.contains(&frame).then_some(frame),
                    w: APP_W,
                    h: APP_H,
                    what: CardKind::App {
                        box_name: bx.into(),
                        name: app.into(),
                        app: None,
                        reachable: true,
                    },
                });
                ids.insert(end.clone());
            }
            if !ids.contains(&edge.from) || !ids.contains(&edge.to) {
                continue;
            }
            let (dashed, arrow) = edge.kind.style();
            let from_box = edge.from.strip_prefix("box:").filter(|b| !b.is_empty());
            let target = e.nodes.iter().find(|n| n.id == edge.to);
            let copies = match (edge.kind, from_box, target, &e.copies) {
                (LinkKind::Backup, Some(fb), Some(t), Some(c)) if t.place.is_some() => {
                    Some(copies_in(c, t, Some(fb)))
                }
                _ => None,
            };
            g.links.push(Link {
                id: edge.id.clone(),
                from: edge.from.clone(),
                to: edge.to.clone(),
                kind: edge.kind,
                constrain: edge.kind.ranks()
                    && !(edge.from.starts_with("store:") && edge.to.starts_with("store:")),
                dashed,
                arrow: if edge.both { Arrow::None } else { arrow },
                copies,
                deploying: edge.kind == LinkKind::Deploy && deploying_now(edge, &e.boxes),
                label: edge.label.clone(),
            });
        }
        g
    }

    /// The layout's input, as Semafor's `GraphCanvas` hands it to `layoutGraph`.
    pub fn layout_input(&self) -> LayoutInput {
        LayoutInput {
            items: self
                .cards
                .iter()
                .map(|c| LayoutItem {
                    id: c.id.clone(),
                    group: c.frame.clone(),
                    w: c.w,
                    h: c.h,
                })
                .collect(),
            groups: self
                .frames
                .iter()
                .map(|f| LayoutGroup {
                    id: f.id.clone(),
                    header: f.header,
                })
                .collect(),
            links: self
                .links
                .iter()
                .map(|l| LayoutLink {
                    id: l.id.clone(),
                    from: l.from.clone(),
                    to: l.to.clone(),
                    constrain: l.constrain,
                })
                .collect(),
        }
    }

    /// How many links of each kind (a legend's counts), by [`LinkKind`] index.
    pub fn kinds(&self) -> [usize; 10] {
        let mut n = [0; 10];
        for l in &self.links {
            n[l.kind as usize] += 1;
        }
        n
    }
}

/// Apps sort by name, owned-elsewhere last.
fn by_place(a: &MapApp, b: &MapApp) -> Ordering {
    let ea = a.sync == AppSync::Elsewhere;
    let eb = b.sync == AppSync::Elsewhere;
    ea.cmp(&eb).then_with(|| collate(&a.name, &b.name))
}

/// Semafor's `pipelinesIn` + `worstOf`: the copies at `node`'s place (one box's, for a backup
/// link). S3 has several buckets, so on a bucket's node ("S3 · example-exampleapp-backups") a copy
/// counts when its location names that bucket or names none, never when it names another.
fn copies_in(copies: &[BackupCopy], node: &TopologyNode, box_name: Option<&str>) -> Copies {
    let place = node.place;
    let placed = copies
        .iter()
        .filter(|c| Some(c.place) == place && box_name.is_none_or(|b| *c.box_name == *b));
    let bucket = node
        .label
        .split(" · ")
        .nth(1)
        .map(str::trim)
        .filter(|b| !b.is_empty());
    let hits: Vec<&BackupCopy> = match bucket {
        None => placed.collect(),
        Some(b) => placed
            .filter(|c| c.location.as_deref().is_none_or(|l| l.contains(b)))
            .collect(),
    };
    Copies {
        state: hits.iter().map(|c| c.state).max_by_key(|s| s.rank()),
        pipelines: hits.len(),
        worst_age_s: hits
            .iter()
            .filter_map(|c| c.age_s)
            .fold(None, |m: Option<f64>, a| Some(m.map_or(a, |m| m.max(a)))),
        by_bucket: bucket.is_some() && hits.iter().all(|c| c.location.is_some()),
    }
}

/// A deploy link flows while deploy-gateway rolls one of its targets or the app it lands on,
/// matched on the rollout's own target and app; a link listing no targets carries them all.
fn deploying_now(edge: &TopologyEdge, boxes: &[MapBox]) -> bool {
    let mut running = boxes
        .iter()
        .flat_map(|b| b.rollouts.iter().filter(|r| r.gateway).map(move |r| (b, r)))
        .peekable();
    if running.peek().is_none() {
        return false;
    }
    let Some(targets) = &edge.targets else {
        return true;
    };
    running.any(|(b, r)| {
        r.target.as_ref().is_some_and(|t| targets.contains(t))
            || r.app
                .as_ref()
                .is_some_and(|a| *edge.to == *format!("app:{}/{a}", b.name))
    })
}

/// `String.prototype.localeCompare` as Semafor's browser runs it (ICU's root collation) for
/// the names a map holds: punctuation before digits before letters, in ICU's order; letters
/// compared without case first, lowercase first on a tie. Outside ASCII, by code point after
/// the letters (an approximation: Semafor's names are ASCII slugs).
pub fn collate(a: &str, b: &str) -> Ordering {
    const PUNCT: &str = "\t\n\u{b}\u{c}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$";
    let primary = |c: char| -> u32 {
        if let Some(i) = PUNCT.find(c) {
            i as u32
        } else if c.is_ascii_digit() {
            100 + (c as u32 - '0' as u32)
        } else if c.is_ascii_alphabetic() {
            200 + (c.to_ascii_lowercase() as u32 - 'a' as u32)
        } else {
            1000 + c.to_lowercase().next().map_or(c as u32, |l| l as u32)
        }
    };
    let keys = |s: &str| s.chars().map(primary).collect::<Vec<_>>();
    let upper = |s: &str| s.chars().map(char::is_uppercase).collect::<Vec<_>>();
    keys(a)
        .cmp(&keys(b))
        .then_with(|| upper(a).cmp(&upper(b)))
        .then_with(|| a.cmp(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collates_as_icu_root() {
        // bun's own `localeCompare` order for these (2026-10-16).
        let want = [
            "~a", "$a", "a", "A", "a b", "a_b", "a-b", "a.b", "a~", "a0", "a1", "a10", "a2", "ab",
            "aB", "Ab", "b", "web", "web-a", "weba", "wg-dns", "x_1", "x-1", "x.1", "x1",
        ];
        let mut got = want.to_vec();
        got.reverse();
        got.sort_by(|a, b| collate(a, b));
        assert_eq!(got, want);
    }

    fn copy(
        box_name: &str,
        place: CopyPlace,
        state: Freshness,
        location: Option<&str>,
    ) -> BackupCopy {
        BackupCopy {
            box_name: box_name.into(),
            pipeline: "p".into(),
            place,
            state,
            age_s: Some(60.0),
            location: location.map(Into::into),
        }
    }

    #[test]
    fn a_bucket_counts_its_own_copies_and_the_unplaced_ones() {
        let node = TopologyNode {
            id: "store:s3-eve".into(),
            kind: NodeKind::Storage,
            label: "S3 · example-eve-backups".into(),
            detail: "".into(),
            place: Some(CopyPlace::S3),
        };
        let copies = [
            copy(
                "build-server",
                CopyPlace::S3,
                Freshness::Fresh,
                Some("s3://example-eve-backups/x"),
            ),
            copy(
                "build-server",
                CopyPlace::S3,
                Freshness::Stale,
                Some("s3://example-exampleapp-backups/x"),
            ),
            copy("app-server", CopyPlace::S3, Freshness::Near, None),
            copy("app-server", CopyPlace::Vault, Freshness::Stale, None),
        ];
        let all = copies_in(&copies, &node, None);
        assert_eq!(
            (all.state, all.pipelines, all.by_bucket),
            (Some(Freshness::Near), 2, false)
        );
        let dev = copies_in(&copies, &node, Some("build-server"));
        assert_eq!(
            (dev.state, dev.pipelines, dev.by_bucket),
            (Some(Freshness::Fresh), 1, true)
        );
    }
}
