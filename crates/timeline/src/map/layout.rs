//! Semafor's graph layout (`web/src/components/graph/layout.ts`), ported number for number:
//! layered left → right, groups as compound nodes. Pure, so the same input always lands on the
//! same picture, and the goldens Semafor's own file produces hold it (`tests/map.rs`).
//!
//! 1. Ranks. Groups and top-level items are ranked by their constraining links: longest
//!    path, a cycle's back edge ignored, a source pulled right next to its nearest successor.
//! 2. Group interiors. Each group lays its members out the same way; members with no
//!    constraining link inside the group are packed into the columns like a grid, leaning
//!    toward the side their outside links come from.
//! 3. Order and coordinates. Barycentric sweeps (down and up, alternating) order each column
//!    to cut crossings; every item then sits as near its neighbours' centre as the spacing
//!    allows. Uniform group cards snap to rows, so a frame reads as a tidy grid.
//! 4. Edges ([`super::route`]). Cubic curves between facing sides; three or more edges on one
//!    side of a card share a trunk to a junction and fan out there.
//!
//! Units are world points (Semafor's CSS pixels at zoom 1), `f64` where layout.ts computes in
//! JS numbers, with its operations in its order, so the port rounds where it rounds. Maps keep
//! insertion order ([`Keyed`]) where layout.ts iterates a `Map`. Ids are unique.

use super::route::{EdgeRoute, route_edges};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point64 {
    pub x: f64,
    pub y: f64,
}

impl Point64 {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// A box in world points: its top-left corner and size.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect64 {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect64 {
    pub fn center(&self) -> Point64 {
        Point64::new(self.x + self.w / 2.0, self.y + self.h / 2.0)
    }
}

/// A card to place: its size is given, never measured (labels truncate).
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutItem {
    pub id: Arc<str>,
    /// The group (frame) holding it; `None`, or a group no [`LayoutGroup`] names: top level.
    pub group: Option<Arc<str>>,
    pub w: f64,
    pub h: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LayoutGroup {
    pub id: Arc<str>,
    /// Height of the frame's header row, points.
    pub header: f64,
}

/// A link between two items or groups (a link to a group attaches to its frame).
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutLink {
    pub id: Arc<str>,
    pub from: Arc<str>,
    pub to: Arc<str>,
    /// False: routed, but the ranking ignores it (feedback links such as telemetry).
    pub constrain: bool,
}

/// layout.ts's `LayoutOptions`, points unless said otherwise.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LayoutOptions {
    /// Gap between top-level columns.
    pub rank_gap: f64,
    /// Gap between columns inside a group.
    pub inner_rank_gap: f64,
    /// Gap between nodes stacked in a column.
    pub node_gap: f64,
    /// Gap next to a group stacked in a top-level column.
    pub group_gap: f64,
    /// Padding inside a frame (sides and bottom; the header sits on top).
    pub group_pad: f64,
    /// A group's packed members grow another column past this many rows (> 0).
    pub pack_rows: usize,
    /// Edges leaving or entering one side together that share a trunk.
    pub bundle_min: usize,
    /// Longest trunk before the fan-out.
    pub trunk: f64,
    /// Empty margin around the whole drawing.
    pub margin: f64,
}

/// layout.ts's `DEFAULT_LAYOUT`.
pub const DEFAULT_LAYOUT: LayoutOptions = LayoutOptions {
    rank_gap: 132.0,
    inner_rank_gap: 22.0,
    node_gap: 12.0,
    group_gap: 44.0,
    group_pad: 16.0,
    pack_rows: 9,
    bundle_min: 3,
    trunk: 40.0,
    margin: 40.0,
};

/// A frame never draws narrower than this (its header needs the room).
pub const MIN_GROUP_W: f64 = 240.0;

/// An insertion-ordered map by id, as a JS `Map` iterates: setting a known id keeps its place.
#[derive(Debug, Clone, PartialEq)]
pub struct Keyed<V> {
    entries: Vec<(Arc<str>, V)>,
    index: HashMap<Arc<str>, usize>,
}

impl<V> Default for Keyed<V> {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            index: HashMap::new(),
        }
    }
}

impl<V> Keyed<V> {
    pub fn get(&self, id: &str) -> Option<&V> {
        self.index.get(id).map(|&i| &self.entries[i].1)
    }

    pub fn contains(&self, id: &str) -> bool {
        self.index.contains_key(id)
    }

    pub fn insert(&mut self, id: Arc<str>, v: V) {
        match self.index.get(&id) {
            Some(&i) => self.entries[i].1 = v,
            None => {
                self.index.insert(id.clone(), self.entries.len());
                self.entries.push((id, v));
            }
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Arc<str>, &V)> {
        self.entries.iter().map(|(k, v)| (k, v))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// layout.ts's `GraphLayout`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GraphLayout {
    pub nodes: Keyed<Rect64>,
    pub groups: Keyed<Rect64>,
    pub edges: Keyed<EdgeRoute>,
    /// The whole drawing, margins included.
    pub width: f64,
    pub height: f64,
    /// Node ids in reading order: column by column, top to bottom, a group's members in its place.
    pub order: Vec<Arc<str>>,
}

/// One box being placed: an item, or a whole group at the top level.
#[derive(Debug, Clone, Copy)]
struct Bx<'a> {
    id: &'a str,
    w: f64,
    h: f64,
}

type Pair<'a> = (&'a str, &'a str);
type Gap<'g> = &'g dyn Fn(&Bx<'_>, &Bx<'_>) -> f64;

/// JS `Math.round`: halves round up (toward +∞), never away from zero.
pub(crate) fn js_round(x: f64) -> f64 {
    let f = x.floor();
    if x - f >= 0.5 { f + 1.0 } else { f }
}

/// A JS sort comparator's `a - b`.
fn by_num(a: f64, b: f64) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

/// layout.ts's `mean`: summed in order from 0 (NaN when empty, as there).
fn mean(xs: impl Iterator<Item = f64>) -> f64 {
    let (s, n) = xs.fold((0.0, 0usize), |(s, n), x| (s + x, n + 1));
    s / n as f64
}

// ── 1. ranks ─────────────────────────────────────────────────────────────────

fn ranks_of<'a>(ids: &[&'a str], links: &[Pair<'a>]) -> HashMap<&'a str, i64> {
    let at: HashMap<&str, usize> = ids.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let n = ids.len();
    let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n];
    for &(a, b) in links {
        if a == b {
            continue;
        }
        if let (Some(&ai), Some(&bi)) = (at.get(a), at.get(b))
            && !adj[ai].contains(&bi)
        {
            adj[ai].push(bi);
        }
    }

    // A DFS in input order keeps tree, forward and cross edges; a back edge closes a cycle and
    // is ignored. Iterative, visiting in exactly the recursive order.
    let mut state = vec![0u8; n];
    let mut succ: Vec<Vec<usize>> = vec![Vec::new(); n];
    let mut pred: Vec<Vec<usize>> = vec![Vec::new(); n];
    for start in 0..n {
        if state[start] != 0 {
            continue;
        }
        state[start] = 1;
        let mut stack = vec![(start, 0usize)];
        while let Some(top) = stack.last_mut() {
            let (v, next) = *top;
            if next == adj[v].len() {
                state[v] = 2;
                stack.pop();
                continue;
            }
            top.1 += 1;
            let w = adj[v][next];
            if state[w] == 1 {
                continue;
            }
            succ[v].push(w);
            pred[w].push(v);
            if state[w] == 0 {
                state[w] = 1;
                stack.push((w, 0));
            }
        }
    }

    // Longest path from the sources (Kahn order).
    let mut rank = vec![0i64; n];
    let mut indeg: Vec<usize> = pred.iter().map(Vec::len).collect();
    let mut topo: Vec<usize> = (0..n).filter(|&i| indeg[i] == 0).collect();
    let mut i = 0;
    while i < topo.len() {
        let v = topo[i];
        for &w in &succ[v] {
            rank[w] = rank[w].max(rank[v] + 1);
            indeg[w] -= 1;
            if indeg[w] == 0 {
                topo.push(w);
            }
        }
        i += 1;
    }
    // A source sits right before its nearest successor, not at the far left.
    for &v in topo.iter().rev() {
        if !pred[v].is_empty() {
            continue;
        }
        if let Some(m) = succ[v].iter().map(|&w| rank[w]).min() {
            rank[v] = m - 1;
        }
    }
    ids.iter()
        .enumerate()
        .map(|(i, id)| (*id, rank[i]))
        .collect()
}

// ── 3. order and coordinates ─────────────────────────────────────────────────

struct ColumnsInput<'a, 'g> {
    items: &'g [Bx<'a>],
    rank: &'g HashMap<&'a str, i64>,
    /// Every link between two items, either direction: the barycentre neighbours.
    links: &'g [Pair<'a>],
    /// Placed into free slots after the ordered items (a group's unlinked members).
    fill: &'g HashSet<&'a str>,
    col_gap: f64,
    /// Vertical gap between two stacked items.
    gap: Gap<'g>,
    /// Row pitch the ordered items snap to (uniform cards); 0 = free placement.
    pitch: f64,
}

#[derive(Default)]
struct Columns<'a> {
    /// Insertion order: column by column, a column's ordered items then its fillers.
    pos: Vec<(&'a str, Point64)>,
    w: f64,
    h: f64,
    /// Each column top to bottom, left to right.
    columns: Vec<Vec<&'a str>>,
}

/// Stacks a column's items in order, each as close to its wanted centre as the gaps allow: a
/// forward pass pushes overlaps down, then the block shifts back by its mean overshoot.
fn pack<'a>(
    col: &[Bx<'a>],
    want: &HashMap<&'a str, f64>,
    gap: Gap<'_>,
    cy: &mut HashMap<&'a str, f64>,
) {
    let wanted = |b: &Bx<'_>| want.get(b.id).copied().unwrap_or(0.0);
    let mut prev: Option<&Bx<'a>> = None;
    let mut bottom = f64::NEG_INFINITY;
    let mut tops = Vec::with_capacity(col.len());
    for b in col {
        let w = wanted(b) - b.h / 2.0;
        let top = match prev {
            None => w,
            Some(p) => w.max(bottom + gap(p, b)),
        };
        tops.push(top);
        bottom = top + b.h;
        prev = Some(b);
    }
    let shift = mean(
        col.iter()
            .zip(&tops)
            .map(|(b, t)| t + b.h / 2.0 - wanted(b)),
    );
    for (b, t) in col.iter().zip(&tops) {
        cy.insert(b.id, t - shift + b.h / 2.0);
    }
}

fn place_columns<'a>(i: ColumnsInput<'a, '_>) -> Columns<'a> {
    if i.items.is_empty() {
        return Columns::default();
    }
    let by_id: HashSet<&str> = i.items.iter().map(|b| b.id).collect();
    let rank_of = |id: &str| i.rank.get(id).copied().unwrap_or(0);
    let n = (i.items.iter().map(|b| rank_of(b.id)).max().unwrap_or(0) + 1).max(0) as usize;
    let mut ordered: Vec<Vec<Bx<'a>>> = vec![Vec::new(); n];
    let mut fillers: Vec<Vec<Bx<'a>>> = vec![Vec::new(); n];
    for b in i.items {
        let Ok(r) = usize::try_from(rank_of(b.id)) else {
            continue;
        };
        let into = if i.fill.contains(b.id) {
            &mut fillers
        } else {
            &mut ordered
        };
        if let Some(col) = into.get_mut(r) {
            col.push(*b);
        }
    }

    let mut near: HashMap<&str, Vec<&str>> = HashMap::new();
    for &(a, b) in i.links {
        if a == b || !by_id.contains(a) || !by_id.contains(b) {
            continue;
        }
        near.entry(a).or_default().push(b);
        near.entry(b).or_default().push(a);
    }

    // Start stacked from the top, then sweep: down from the left neighbours, up from the right.
    let mut cy: HashMap<&str, f64> = HashMap::new();
    for col in &ordered {
        let mut y = 0.0;
        let mut stacked = HashMap::new();
        for b in col {
            stacked.insert(b.id, y + b.h / 2.0);
            y += b.h + (i.gap)(b, b);
        }
        pack(col, &stacked, i.gap, &mut cy);
    }
    for it in 0..6 {
        let down = it % 2 == 0;
        for k in 0..n {
            let r = if down { k } else { n - 1 - k };
            if ordered[r].is_empty() {
                continue;
            }
            let ri = r as i64;
            let mut want = HashMap::new();
            for b in &ordered[r] {
                let all: Vec<&str> = near
                    .get(b.id)
                    .map(|v| v.iter().copied().filter(|o| rank_of(o) != ri).collect())
                    .unwrap_or_default();
                let side: Vec<&str> = all
                    .iter()
                    .copied()
                    .filter(|o| {
                        if down {
                            rank_of(o) < ri
                        } else {
                            rank_of(o) > ri
                        }
                    })
                    .collect();
                let used = if side.is_empty() { &all } else { &side };
                let w = if used.is_empty() {
                    cy.get(b.id).copied().unwrap_or(0.0)
                } else {
                    mean(used.iter().map(|o| cy.get(o).copied().unwrap_or(0.0)))
                };
                want.insert(b.id, w);
            }
            ordered[r].sort_by(|a, b| by_num(want[a.id], want[b.id]));
            pack(&ordered[r], &want, i.gap, &mut cy);
        }
    }

    let cy_of = |b: &Bx<'_>| cy.get(b.id).copied().unwrap_or(0.0);
    let mut top: HashMap<&str, f64> = HashMap::new();
    if i.pitch > 0.0 {
        // Uniform cards: snap to rows, then the unlinked members take the free rows from the top.
        let row_of = |b: &Bx<'_>| js_round((cy_of(b) - b.h / 2.0) / i.pitch) as i64;
        let first_row = ordered.iter().flatten().map(row_of).fold(0, i64::min);
        for (r, col) in ordered.iter().enumerate() {
            let mut used = HashSet::new();
            let mut last: Option<i64> = None;
            for b in col {
                let row = last.map_or(row_of(b), |l| row_of(b).max(l + 1));
                used.insert(row);
                last = Some(row);
                top.insert(b.id, row as f64 * i.pitch);
            }
            let mut row = first_row;
            for b in &fillers[r] {
                while used.contains(&row) {
                    row += 1;
                }
                used.insert(row);
                top.insert(b.id, row as f64 * i.pitch);
            }
        }
    } else {
        let first_top = ordered
            .iter()
            .flatten()
            .map(|b| cy_of(b) - b.h / 2.0)
            .fold(0.0, f64::min);
        for (r, col) in ordered.iter().enumerate() {
            let mut taken: Vec<(f64, f64)> = Vec::new();
            for b in col {
                let y = cy_of(b) - b.h / 2.0;
                top.insert(b.id, y);
                taken.push((y, b.h));
            }
            for b in &fillers[r] {
                // The first gap from the top that holds it.
                taken.sort_by(|a, c| by_num(a.0, c.0));
                let g = (i.gap)(b, b);
                let mut y = first_top;
                for &(ty, th) in &taken {
                    if y + b.h + g <= ty {
                        break;
                    }
                    y = y.max(ty + th + g);
                }
                top.insert(b.id, y);
                taken.push((y, b.h));
            }
        }
    }

    // Columns left to right; an empty rank takes no room.
    let top_of = |b: &Bx<'_>| top.get(b.id).copied().unwrap_or(0.0);
    let mut out = Columns::default();
    let mut x = 0.0;
    let mut min_y = f64::INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for r in 0..n {
        let mut col: Vec<Bx<'a>> = ordered[r].iter().chain(&fillers[r]).copied().collect();
        if col.is_empty() {
            continue;
        }
        let col_w = col.iter().map(|b| b.w).fold(f64::NEG_INFINITY, f64::max);
        for b in &col {
            let y = top_of(b);
            out.pos.push((b.id, Point64::new(x, y)));
            min_y = min_y.min(y);
            max_y = max_y.max(y + b.h);
        }
        col.sort_by(|a, b| by_num(top_of(a), top_of(b)));
        out.columns.push(col.iter().map(|b| b.id).collect());
        out.w = x + col_w;
        x += col_w + i.col_gap;
    }
    for (_, p) in &mut out.pos {
        p.y -= min_y;
    }
    out.h = max_y - min_y;
    out
}

// ── 2. group interiors ───────────────────────────────────────────────────────

fn layout_group<'a>(
    members: &[Bx<'a>],
    links: &'a [LayoutLink],
    lean: &HashMap<&'a str, i64>,
    o: &LayoutOptions,
) -> Columns<'a> {
    let ids: HashSet<&str> = members.iter().map(|m| m.id).collect();
    let inside: Vec<&LayoutLink> = links
        .iter()
        .filter(|l| l.from != l.to && ids.contains(&*l.from) && ids.contains(&*l.to))
        .collect();
    let constraining: Vec<Pair<'a>> = inside
        .iter()
        .filter(|l| l.constrain)
        .map(|l| (&*l.from, &*l.to))
        .collect();
    let linked: HashSet<&str> = constraining.iter().flat_map(|&(a, b)| [a, b]).collect();
    let linked_ids: Vec<&str> = members
        .iter()
        .map(|m| m.id)
        .filter(|id| linked.contains(id))
        .collect();
    let mut rank = ranks_of(&linked_ids, &constraining);
    let ranked = if linked.is_empty() {
        0
    } else {
        rank.values().copied().max().unwrap_or(0) + 1
    };
    let cols = ranked
        .max(members.len().div_ceil(o.pack_rows) as i64)
        .max(1) as usize;
    let mut count: Vec<usize> = (0..cols)
        .map(|c| rank.values().filter(|&&r| r == c as i64).count())
        .collect();
    let target = members.len().div_ceil(cols);
    let mut fill = HashSet::new();
    for m in members {
        if linked.contains(m.id) {
            continue;
        }
        fill.insert(m.id);
        let side = lean.get(m.id).copied().unwrap_or(0);
        let c = if side < 0 && count[0] < target {
            0
        } else if side > 0 && count[cols - 1] < target {
            cols - 1
        } else {
            let least = count.iter().copied().min().unwrap_or(0);
            count.iter().position(|&n| n == least).unwrap_or(0)
        };
        rank.insert(m.id, c as i64);
        count[c] += 1;
    }
    let h0 = members.first().map_or(0.0, |m| m.h);
    let uniform = members.iter().all(|m| m.h == h0);
    let pairs: Vec<Pair<'a>> = inside.iter().map(|l| (&*l.from, &*l.to)).collect();
    place_columns(ColumnsInput {
        items: members,
        rank: &rank,
        links: &pairs,
        fill: &fill,
        col_gap: o.inner_rank_gap,
        gap: &|_, _| o.node_gap,
        pitch: if uniform { h0 + o.node_gap } else { 0.0 },
    })
}

// ── the whole graph ──────────────────────────────────────────────────────────

/// layout.ts's `layoutGraph`.
pub fn layout_graph(
    items: &[LayoutItem],
    groups: &[LayoutGroup],
    links: &[LayoutLink],
    o: &LayoutOptions,
) -> GraphLayout {
    let group_ids: HashSet<&str> = groups.iter().map(|g| &*g.id).collect();
    let item_by_id: HashMap<&str, &LayoutItem> = items.iter().map(|i| (&*i.id, i)).collect();
    let group_of = |id: &str| -> Option<&str> {
        item_by_id
            .get(id)
            .and_then(|i| i.group.as_deref())
            .filter(|g| !g.is_empty() && group_ids.contains(g))
    };
    // The top-level box an id belongs to: its group, itself, or nothing (an unknown id).
    let top_of = |id: &'_ str| -> Option<&str> {
        if let Some(g) = group_ids.get(id) {
            Some(*g)
        } else if let Some(i) = item_by_id.get(id) {
            Some(group_of(id).unwrap_or(&i.id))
        } else {
            None
        }
    };

    let mut top_pairs: Vec<Pair<'_>> = Vec::new();
    let mut top_constrain: Vec<Pair<'_>> = Vec::new();
    for l in links {
        let (Some(a), Some(b)) = (top_of(&l.from), top_of(&l.to)) else {
            continue;
        };
        if a == b {
            continue;
        }
        top_pairs.push((a, b));
        if l.constrain {
            top_constrain.push((a, b));
        }
    }
    let loose: Vec<&LayoutItem> = items.iter().filter(|i| group_of(&i.id).is_none()).collect();
    let top_ids: Vec<&str> = groups
        .iter()
        .map(|g| &*g.id)
        .chain(loose.iter().map(|i| &*i.id))
        .collect();
    let top_rank = ranks_of(&top_ids, &top_constrain);
    let rank_of = |id: &str| top_rank.get(id).copied().unwrap_or(0);

    // Group interiors, each member leaning toward the side its outside links come from.
    let mut interiors: HashMap<&str, Columns<'_>> = HashMap::new();
    let mut boxes: Vec<Bx<'_>> = Vec::new();
    for g in groups {
        let members: Vec<Bx<'_>> = items
            .iter()
            .filter(|i| group_of(&i.id) == Some(&*g.id))
            .map(|i| Bx {
                id: &i.id,
                w: i.w,
                h: i.h,
            })
            .collect();
        let mut lean: HashMap<&str, i64> = HashMap::new();
        for l in links {
            for (mine, other) in [(&*l.from, &*l.to), (&*l.to, &*l.from)] {
                if group_of(mine) != Some(&*g.id) {
                    continue;
                }
                let Some(t) = top_of(other) else {
                    continue;
                };
                if t == &*g.id {
                    continue;
                }
                *lean.entry(mine).or_insert(0) += (rank_of(t) - rank_of(&g.id)).signum();
            }
        }
        let inner = layout_group(&members, links, &lean, o);
        boxes.push(Bx {
            id: &g.id,
            w: (inner.w + 2.0 * o.group_pad).max(MIN_GROUP_W),
            h: g.header + inner.h + if members.is_empty() { 0.0 } else { o.group_pad },
        });
        interiors.insert(&g.id, inner);
    }
    for i in &loose {
        boxes.push(Bx {
            id: &i.id,
            w: i.w,
            h: i.h,
        });
    }

    let gap = |a: &Bx<'_>, b: &Bx<'_>| {
        if group_ids.contains(a.id) || group_ids.contains(b.id) {
            o.group_gap
        } else {
            o.node_gap
        }
    };
    let top = place_columns(ColumnsInput {
        items: &boxes,
        rank: &top_rank,
        links: &top_pairs,
        fill: &HashSet::new(),
        col_gap: o.rank_gap,
        gap: &gap,
        pitch: 0.0,
    });

    let m = o.margin;
    let mut out = GraphLayout {
        width: top.w + 2.0 * m,
        height: top.h + 2.0 * m,
        ..GraphLayout::default()
    };
    let top_pos: HashMap<&str, Point64> = top.pos.iter().copied().collect();
    let box_by_id: HashMap<&str, Bx<'_>> = boxes.iter().map(|b| (b.id, *b)).collect();
    for g in groups {
        let (Some(p), Some(b)) = (top_pos.get(&*g.id), box_by_id.get(&*g.id)) else {
            continue;
        };
        out.groups.insert(
            g.id.clone(),
            Rect64 {
                x: p.x + m,
                y: p.y + m,
                w: b.w,
                h: b.h,
            },
        );
        for (id, q) in interiors.get(&*g.id).map_or(&[][..], |c| &c.pos[..]) {
            if let Some(it) = item_by_id.get(id) {
                out.nodes.insert(
                    it.id.clone(),
                    Rect64 {
                        x: p.x + m + o.group_pad + q.x,
                        y: p.y + m + g.header + q.y,
                        w: it.w,
                        h: it.h,
                    },
                );
            }
        }
    }
    for i in &loose {
        if let Some(p) = top_pos.get(&*i.id) {
            out.nodes.insert(
                i.id.clone(),
                Rect64 {
                    x: p.x + m,
                    y: p.y + m,
                    w: i.w,
                    h: i.h,
                },
            );
        }
    }

    let id_of = |id: &str| -> Arc<str> {
        item_by_id
            .get(id)
            .map_or_else(|| id.into(), |i| i.id.clone())
    };
    for col in &top.columns {
        for id in col {
            match interiors.get(id) {
                Some(inner) => out
                    .order
                    .extend(inner.columns.iter().flatten().map(|c| id_of(c))),
                None => out.order.push(id_of(id)),
            }
        }
    }

    let header_of: HashMap<&str, f64> = groups.iter().map(|g| (&*g.id, g.header)).collect();
    let mut frames: HashMap<&str, (&str, f64)> = HashMap::new();
    for i in items {
        if let Some(g) = group_of(&i.id)
            && let Some(r) = out.groups.get(g)
        {
            frames.insert(&i.id, (g, r.y + header_of[g] - 6.0));
        }
    }
    out.edges = route_edges(links, &out.nodes, &out.groups, &frames, o);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_halves_up_as_js_does() {
        assert_eq!(js_round(2.5), 3.0);
        assert_eq!(js_round(-2.5), -2.0);
        assert_eq!(js_round(-2.6), -3.0);
        assert_eq!(js_round(0.49999999999999994), 0.0);
    }

    #[test]
    fn a_cycle_ranks_by_its_tree_and_a_source_moves_right() {
        // a → b → c → a: the back edge c → a is ignored; s → c pulls s to just before c.
        let ids = ["a", "b", "c", "s"];
        let r = ranks_of(&ids, &[("a", "b"), ("b", "c"), ("c", "a"), ("s", "c")]);
        assert_eq!((r["a"], r["b"], r["c"], r["s"]), (0, 1, 2, 1));
    }
}
