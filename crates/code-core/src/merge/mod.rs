//! The three-way merge both apps read (vt-7968, decisions M2, M5, M6 in
//! `docs/specs/2026-10-18-merge-view-decisions.md`): a merge base and two sides into one
//! result, as regions a merge view draws side by side.
//!
//! Two layers. The line merge ([`lines`]) is git's own (`xdl_merge` at `ll_merge`'s zealous
//! level, on git's histogram diff), so a region git merges cleanly merges identically — the
//! oracle test holds it over real merges (`corpus/merge/`). Then, for a language with a
//! grammar, each conflict the line merge leaves goes to the structural resolvers
//! ([`structure`]): an import union, both sides adding items to one list or body, edits to
//! different lines or words, one side reordering a list the other edited. A resolution is kept
//! only when the merged file parses with no more errors than either side's choice would leave;
//! it carries what it did ([`Resolution`]), and the app words it. A text without a grammar is
//! merged by lines alone.
//!
//! Lines are `\n`-ended, as git compares them (a last line without one differs from the same
//! line with one). Ranges are line indices, end-exclusive; the regions tile all four texts in
//! order, so a region's ranges are where its stretch sits in each.

mod lines;
mod structure;

#[cfg(test)]
mod tests;

use crate::syntax::Language;
use lines::{Change, Mode, Tokens};
use std::ops::Range;

/// What a region of the result is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RegionKind {
    /// Neither side changed it.
    Unchanged,
    /// Only ours changed it: the result takes ours.
    Ours,
    /// Only theirs changed it: the result takes theirs.
    Theirs,
    /// Both sides changed it alike.
    Both,
    /// The sides changed it differently, and a structural resolver merged them
    /// ([`Region::resolution`] says how).
    Resolved,
    /// The sides changed it differently and nothing resolved it: the result holds the base's
    /// lines, as a merge tool's result pane starts.
    Conflict,
}

/// How a structural resolver merged a conflict.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResolutionKind {
    /// Both sides changed one import block: every import either side added is kept, none
    /// either removed comes back.
    Imports,
    /// Both sides added items (functions, members, entries) at one place in a list or body:
    /// ours first, then theirs.
    BothAdded,
    /// The sides edited different lines next to each other (git calls touching edits a
    /// conflict).
    Lines,
    /// The sides edited different words of the same lines.
    Words,
    /// One side reordered a list; the other's edits to its entries are applied in the new order.
    Reordered,
}

/// One side of a merge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Side {
    Base,
    Ours,
    Theirs,
}

/// What a structural resolver did, for the app to word.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Resolution {
    pub kind: ResolutionKind,
    /// The item the region sits in — a function's, type's or section's name — where the
    /// grammar names one.
    pub scope: Option<String>,
    /// [`ResolutionKind::Reordered`]: the side that reordered.
    pub reordered: Option<Side>,
}

/// A past merge's text where it differs from the engine's (a conflict someone resolved, or an
/// edit made in the merge commit itself).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Committed {
    /// The commit took ours' lines.
    Ours,
    /// The commit took theirs' lines.
    Theirs,
    /// The commit kept the base's lines.
    Base,
    /// The commit wrote lines of its own.
    Hand,
}

/// One stretch of the merge: where it sits in each text and what it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Region {
    pub kind: RegionKind,
    pub base: Range<usize>,
    pub ours: Range<usize>,
    pub theirs: Range<usize>,
    pub result: Range<usize>,
    pub resolution: Option<Resolution>,
    /// Set only on a past merge ([`Merge::against`]).
    pub committed: Option<Committed>,
}

impl Region {
    /// The stretch's lines in `side`'s text.
    pub fn range(&self, side: Side) -> &Range<usize> {
        match side {
            Side::Base => &self.base,
            Side::Ours => &self.ours,
            Side::Theirs => &self.theirs,
        }
    }
}

/// A merge: the result text and its regions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Merge {
    pub result: String,
    pub regions: Vec<Region>,
}

impl Merge {
    /// `ours` and `theirs` merged over `base`: the line merge, then — with a `language` —
    /// the structural resolvers on every conflict it leaves.
    pub fn new(base: &str, ours: &str, theirs: &str, language: Option<Language>) -> Self {
        let sides = [lines::lines(base), lines::lines(ours), lines::lines(theirs)];
        let tokens = Tokens::new(&sides[0], &sides[1], &sides[2]);
        let changes = lines::merge(&tokens);
        let Some(language) = language.filter(|_| changes.iter().any(|c| c.mode == Mode::Conflict))
        else {
            return finish(&sides, assemble(&tokens, &lines::simplify(changes)));
        };
        // Each conflict as git's walk found it goes to the resolvers; those left are joined as
        // git writes them.
        let mut drafts = assemble(&tokens, &changes);
        structure::resolve(language, &sides, &mut drafts);
        finish(&sides, rejoin(drafts))
    }

    /// The conflicts nothing resolved.
    pub fn conflicts(&self) -> usize {
        self.regions
            .iter()
            .filter(|r| r.kind == RegionKind::Conflict)
            .count()
    }

    /// The regions a reader steps through (⇥): every one but the unchanged.
    pub fn changes(&self) -> impl Iterator<Item = (usize, &Region)> {
        self.regions
            .iter()
            .enumerate()
            .filter(|(_, r)| r.kind != RegionKind::Unchanged)
    }

    /// This merge set against what a merge commit committed (`committed`, the commit's file):
    /// the result becomes the committed text, each region's result range moves to where its
    /// stretch landed there, and a region whose committed lines differ from the engine's says
    /// what the commit took ([`Region::committed`]).
    pub fn against(mut self, base: &str, ours: &str, theirs: &str, committed: &str) -> Self {
        let sides = [lines::lines(base), lines::lines(ours), lines::lines(theirs)];
        let engine = lines::lines(&self.result);
        let landed = lines::lines(committed);
        let tokens = Tokens::new(&engine, &landed, &[]);
        let hunks = lines::hunks(&tokens.base, &tokens.ours, tokens.count);
        let mut floor = 0;
        let count = self.regions.len();
        for (k, r) in self.regions.iter_mut().enumerate() {
            let from = lines::carry(&hunks, r.result.start, false).max(floor);
            let to = if k + 1 == count {
                landed.len()
            } else {
                lines::carry(&hunks, r.result.end, false).max(from)
            };
            floor = to;
            let mine = &engine[r.result.clone()];
            let theirs_text = &landed[from..to];
            if mine != theirs_text || r.kind == RegionKind::Conflict {
                let same =
                    |side: usize, range: &Range<usize>| sides[side][range.clone()] == *theirs_text;
                r.committed = Some(if same(1, &r.ours) {
                    Committed::Ours
                } else if same(2, &r.theirs) {
                    Committed::Theirs
                } else if same(0, &r.base) {
                    Committed::Base
                } else {
                    Committed::Hand
                });
            }
            r.result = from..to;
        }
        self.result = committed.to_owned();
        self
    }
}

/// A region on its way to the result: a resolver's lines, when one merged it.
#[derive(Clone)]
pub(crate) struct Draft {
    pub region: Region,
    pub text: Option<String>,
}

/// The changes as regions tiling the three texts: between two changes, ours and theirs agree,
/// so a stretch there is unchanged, or changed alike by both where it differs from the base.
fn assemble(t: &Tokens, changes: &[Change]) -> Vec<Draft> {
    let mut out = Vec::with_capacity(2 * changes.len() + 1);
    let region = |kind, base, ours, theirs| Draft {
        region: Region {
            kind,
            base,
            ours,
            theirs,
            result: 0..0,
            resolution: None,
            committed: None,
        },
        text: None,
    };
    let gap =
        |out: &mut Vec<Draft>, base: Range<usize>, ours: Range<usize>, theirs: Range<usize>| {
            if base.is_empty() && ours.is_empty() && theirs.is_empty() {
                return;
            }
            if ours.len() != theirs.len() {
                // Never meant to happen: ours and theirs agree between changes. Say so rather than
                // claim a merge.
                debug_assert!(false, "ours and theirs differ between two changes");
                out.push(region(RegionKind::Conflict, base, ours, theirs));
                return;
            }
            let (b, o) = (&t.base[base.clone()], &t.ours[ours.clone()]);
            if b == o {
                out.push(region(RegionKind::Unchanged, base, ours, theirs));
                return;
            }
            let shift = theirs.start as isize - ours.start as isize;
            let theirs_of = |r: &Range<usize>| {
                (r.start as isize + shift) as usize..(r.end as isize + shift) as usize
            };
            let (mut bi, mut oi) = (base.start, ours.start);
            for h in lines::hunks(b, o, t.count) {
                let (hb, ho) = (
                    base.start + h.before.start as usize..base.start + h.before.end as usize,
                    ours.start + h.after.start as usize..ours.start + h.after.end as usize,
                );
                if oi < ho.start {
                    let o = oi..ho.start;
                    out.push(region(
                        RegionKind::Unchanged,
                        bi..hb.start,
                        o.clone(),
                        theirs_of(&o),
                    ));
                }
                out.push(region(
                    RegionKind::Both,
                    hb.clone(),
                    ho.clone(),
                    theirs_of(&ho),
                ));
                (bi, oi) = (hb.end, ho.end);
            }
            if oi < ours.end || bi < base.end {
                let o = oi..ours.end;
                out.push(region(
                    RegionKind::Unchanged,
                    bi..base.end,
                    o.clone(),
                    theirs_of(&o),
                ));
            }
        };
    let (mut b, mut o, mut th) = (0, 0, 0);
    for c in changes {
        gap(
            &mut out,
            b..c.base.start,
            o..c.ours.start,
            th..c.theirs.start,
        );
        let kind = match c.mode {
            Mode::Conflict => RegionKind::Conflict,
            Mode::Ours => RegionKind::Ours,
            Mode::Theirs => RegionKind::Theirs,
            Mode::Same => RegionKind::Both,
        };
        out.push(region(
            kind,
            c.base.clone(),
            c.ours.clone(),
            c.theirs.clone(),
        ));
        (b, o, th) = (c.base.end, c.ours.end, c.theirs.end);
    }
    gap(
        &mut out,
        b..t.base.len(),
        o..t.ours.len(),
        th..t.theirs.len(),
    );
    out
}

/// git's join of conflicts [`lines::JOIN`] lines or fewer apart, over the conflicts no
/// resolver took: the unchanged (or alike) stretches between them join the conflict.
fn rejoin(drafts: Vec<Draft>) -> Vec<Draft> {
    let mut out: Vec<Draft> = Vec::with_capacity(drafts.len());
    for d in drafts {
        if d.region.kind == RegionKind::Conflict
            && let Some(j) = out.iter().rposition(|p| {
                p.region.kind != RegionKind::Unchanged && p.region.kind != RegionKind::Both
            })
            && out[j].region.kind == RegionKind::Conflict
            && d.region.ours.start - out[j].region.ours.end <= lines::JOIN
        {
            let joined = &mut out[j].region;
            joined.base.end = d.region.base.end;
            joined.ours.end = d.region.ours.end;
            joined.theirs.end = d.region.theirs.end;
            out.truncate(j + 1);
            continue;
        }
        out.push(d);
    }
    out
}

/// Each region's result lines, in order: ours' where ours' stand, theirs' where theirs
/// changed, the base's in a conflict, a resolver's where one merged.
fn finish(sides: &[Vec<&str>; 3], drafts: Vec<Draft>) -> Merge {
    let mut result = String::new();
    let mut line = 0;
    let mut regions = Vec::with_capacity(drafts.len());
    for Draft { mut region, text } in drafts {
        let start = line;
        match &text {
            Some(text) => {
                line += lines::lines(text).len();
                result.push_str(text);
            }
            None => {
                let (side, range) = source(&region);
                for l in &sides[side][range] {
                    result.push_str(l);
                    line += 1;
                }
            }
        }
        region.result = start..line;
        regions.push(region);
    }
    Merge { result, regions }
}

/// The side (0 base, 1 ours, 2 theirs) and lines an unresolved region's result reads.
fn source(r: &Region) -> (usize, Range<usize>) {
    match r.kind {
        RegionKind::Theirs => (2, r.theirs.clone()),
        RegionKind::Conflict => (0, r.base.clone()),
        _ => (1, r.ours.clone()),
    }
}
