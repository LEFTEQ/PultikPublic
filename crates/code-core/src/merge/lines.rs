//! The line merge: git's `xdl_merge` at the level `ll_merge` asks for (zealous), on git's
//! histogram diff and its slider rule (`merge-ort` merges with histogram; sliders go as far
//! down as they can unless they line up with the other side's change). Changes are walked as
//! git walks them, so a change that touches the other side's (adjacent, not only overlapping)
//! is a conflict, a conflict is refined against itself (lines both sides wrote alike leave
//! it) and conflicts three lines or fewer apart are joined again. Every region git merges
//! cleanly, this merges identically: the oracle test holds it over real merges.

use imara_diff::{Algorithm, Diff, Hunk, NoSliderHeuristic, Token};
use std::collections::HashMap;
use std::ops::Range;

/// A text's lines, each with its `\n`: git compares them so, and a last line without one
/// differs from the same line with one.
pub(crate) fn lines(text: &str) -> Vec<&str> {
    text.split_inclusive('\n').collect()
}

/// Three texts' lines as tokens of one interner, so equal lines are equal tokens across all.
pub(crate) struct Tokens {
    pub base: Vec<Token>,
    pub ours: Vec<Token>,
    pub theirs: Vec<Token>,
    pub count: u32,
}

impl Tokens {
    pub fn new<'a>(base: &[&'a str], ours: &[&'a str], theirs: &[&'a str]) -> Self {
        fn intern<'a>(map: &mut HashMap<&'a str, u32>, lines: &[&'a str]) -> Vec<Token> {
            lines
                .iter()
                .map(|l| {
                    let next = map.len() as u32;
                    Token(*map.entry(l).or_insert(next))
                })
                .collect()
        }
        let mut map = HashMap::new();
        let (base, ours, theirs) = (
            intern(&mut map, base),
            intern(&mut map, ours),
            intern(&mut map, theirs),
        );
        Self {
            base,
            ours,
            theirs,
            count: map.len() as u32,
        }
    }
}

/// `before` → `after` as hunks: git's histogram diff with its sliders placed.
pub(crate) fn hunks(before: &[Token], after: &[Token], count: u32) -> Vec<Hunk> {
    let mut diff = Diff::default();
    diff.compute_with(Algorithm::Histogram, before, after, count);
    diff.postprocess_with(before, after, NoSliderHeuristic);
    diff.hunks().collect()
}

/// What a stretch of the merge is, git's `xdmerge_t.mode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    Conflict,
    /// Only ours changed it.
    Ours,
    /// Only theirs changed it.
    Theirs,
    /// A conflict whose two sides turned out equal (zealous refinement).
    Same,
}

/// One change of the merge: its lines in each text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Change {
    pub mode: Mode,
    pub base: Range<usize>,
    pub ours: Range<usize>,
    pub theirs: Range<usize>,
}

/// A stretch as git's merge walk carries it: a signed start and count, since a conflict's
/// start can run before the line it ends up at until the next change joins it (`int` in C).
type Span = (isize, isize);

/// `xdl_append_merge`: a change touching the last one (in ours' or theirs' lines) joins it,
/// and a join of two modes is a conflict.
fn append(changes: &mut Vec<Change>, mode: Mode, base: Span, ours: Span, theirs: Span) {
    let at = |(start, count): Span| start.max(0) as usize..(start + count).max(0) as usize;
    if let Some(m) = changes.last_mut()
        && (ours.0 <= m.ours.end as isize || theirs.0 <= m.theirs.end as isize)
    {
        if mode != m.mode {
            m.mode = Mode::Conflict;
        }
        m.base.end = at(base).end;
        m.ours.end = at(ours).end;
        m.theirs.end = at(theirs).end;
        return;
    }
    changes.push(Change {
        mode,
        base: at(base),
        ours: at(ours),
        theirs: at(theirs),
    });
}

/// The changes of merging `t.ours` and `t.theirs` over `t.base`, in order (`xdl_do_merge`).
pub(crate) fn merge(t: &Tokens) -> Vec<Change> {
    let one = hunks(&t.base, &t.ours, t.count);
    let two = hunks(&t.base, &t.theirs, t.count);
    let len = |r: &Range<u32>| r.len() as isize;
    let start = |r: &Range<u32>| r.start as isize;
    let mut changes = Vec::new();
    let (mut a, mut b) = (0, 0);
    while a < one.len() && b < two.len() {
        let (x, y) = (&one[a], &two[b]);
        // Ours ends before theirs starts (strictly: touching is a conflict). Theirs runs
        // `y.after - y.before` ahead of the base up to its next change.
        if x.before.end < y.before.start {
            let i0 = start(&x.before);
            let i2 = start(&y.after) - start(&y.before) + i0;
            append(
                &mut changes,
                Mode::Ours,
                (i0, len(&x.before)),
                (start(&x.after), len(&x.after)),
                (i2, len(&x.before)),
            );
            a += 1;
            continue;
        }
        if y.before.end < x.before.start {
            let i0 = start(&y.before);
            let i1 = start(&x.after) - start(&x.before) + i0;
            append(
                &mut changes,
                Mode::Theirs,
                (i0, len(&y.before)),
                (i1, len(&y.before)),
                (start(&y.after), len(&y.after)),
            );
            b += 1;
            continue;
        }
        let same = x.before == y.before
            && x.after.len() == y.after.len()
            && t.ours[x.after.start as usize..x.after.end as usize]
                == t.theirs[y.after.start as usize..y.after.end as usize];
        if !same {
            // The conflict spans both changes: the later one's start moves back to the
            // earlier's, the shorter one's end on to the longer's.
            let off = start(&x.before) - start(&y.before);
            let ffo = off + len(&x.before) - len(&y.before);
            let (mut i0, mut i1, mut i2) = (start(&x.before), start(&x.after), start(&y.after));
            if off > 0 {
                i0 -= off;
                i1 -= off;
            } else {
                i2 += off;
            }
            let mut chg0 = x.before.end as isize - i0;
            let mut chg1 = x.after.end as isize - i1;
            let mut chg2 = y.after.end as isize - i2;
            if ffo < 0 {
                chg0 -= ffo;
                chg1 -= ffo;
            } else {
                chg2 += ffo;
            }
            append(
                &mut changes,
                Mode::Conflict,
                (i0, chg0),
                (i1, chg1),
                (i2, chg2),
            );
        }
        let (e1, e2) = (x.before.end, y.before.end);
        if e1 >= e2 {
            b += 1;
        }
        if e2 >= e1 {
            a += 1;
        }
    }
    let (nb, no, nt) = (
        t.base.len() as isize,
        t.ours.len() as isize,
        t.theirs.len() as isize,
    );
    for x in &one[a..] {
        let i0 = start(&x.before);
        let i2 = i0 + nt - nb;
        append(
            &mut changes,
            Mode::Ours,
            (i0, len(&x.before)),
            (start(&x.after), len(&x.after)),
            (i2, len(&x.before)),
        );
    }
    for y in &two[b..] {
        let i0 = start(&y.before);
        let i1 = i0 + no - nb;
        append(
            &mut changes,
            Mode::Theirs,
            (i0, len(&y.before)),
            (i1, len(&y.before)),
            (start(&y.after), len(&y.after)),
        );
    }
    refine(t, &one, changes)
}

/// Where line boundary `line` of a diff's before side lands on its after side (`back`: the
/// other way). Inside a hunk it keeps its offset into the hunk, as far as the other side's
/// lines reach: a changed line pairs with the line at its place.
pub(crate) fn carry(hunks: &[Hunk], line: usize, back: bool) -> usize {
    let mut offset: isize = 0;
    for h in hunks {
        let (from, to) = match back {
            false => (&h.before, &h.after),
            true => (&h.after, &h.before),
        };
        let (a, b) = (from.start as usize, from.end as usize);
        if line <= a {
            break;
        }
        if line < b {
            return to.start as usize + (line - a).min(to.len());
        }
        offset = to.end as isize - b as isize;
    }
    (line as isize + offset).max(0) as usize
}

/// `xdl_refine_conflicts`: each conflict whose sides are both non-empty is diffed against
/// itself, and what both sides wrote alike leaves it; equal sides make it `Same`. A piece's
/// base lines are where its ours lines came from, kept in order inside the conflict's.
fn refine(t: &Tokens, one: &[Hunk], changes: Vec<Change>) -> Vec<Change> {
    let mut out = Vec::with_capacity(changes.len());
    for c in changes {
        if c.mode != Mode::Conflict || c.ours.is_empty() || c.theirs.is_empty() {
            out.push(c);
            continue;
        }
        let (o, th) = (&t.ours[c.ours.clone()], &t.theirs[c.theirs.clone()]);
        let pieces = hunks(o, th, t.count);
        if pieces.is_empty() {
            out.push(Change {
                mode: Mode::Same,
                ..c
            });
            continue;
        }
        let mut floor = c.base.start;
        let count = pieces.len();
        for (k, p) in pieces.iter().enumerate() {
            let ours = c.ours.start + p.before.start as usize..c.ours.start + p.before.end as usize;
            let theirs =
                c.theirs.start + p.after.start as usize..c.theirs.start + p.after.end as usize;
            let from = carry(one, ours.start, true).clamp(floor, c.base.end);
            let to = if k + 1 == count {
                c.base.end
            } else {
                carry(one, ours.end, true).clamp(from, c.base.end)
            };
            floor = to;
            out.push(Change {
                mode: Mode::Conflict,
                base: from..to,
                ours,
                theirs,
            });
        }
    }
    out
}

/// Conflicts this many of ours' lines apart or closer read as one (git's zealous level).
pub(crate) const JOIN: usize = 3;

/// `xdl_simplify_non_conflicts` (zealous): two conflicts in a row with [`JOIN`] lines or fewer
/// between them become one, those lines in both sides. [`merge`] leaves them apart, so the
/// structural resolvers see each conflict as the walk found it.
pub(crate) fn simplify(changes: Vec<Change>) -> Vec<Change> {
    let mut out: Vec<Change> = Vec::with_capacity(changes.len());
    for c in changes {
        if let Some(m) = out.last_mut()
            && m.mode == Mode::Conflict
            && c.mode == Mode::Conflict
            && c.ours.start - m.ours.end <= JOIN
        {
            m.base.end = c.base.end;
            m.ours.end = c.ours.end;
            m.theirs.end = c.theirs.end;
            continue;
        }
        out.push(c);
    }
    out
}
