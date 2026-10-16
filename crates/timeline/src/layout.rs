//! A timeline's lanes: groups (an organisation, a box) of rows (a CI lane, Rollouts / Backups /
//! Cleanups), stacked under the axis. A group says its height and its rows' centres in base
//! points; the size's `k` scales all of it. Each row owns a horizontal band it answers hits in.

use crate::geometry::AXIS_PT;
use canvas_draw::Rgba;
use std::collections::HashMap;
use std::sync::Arc;

/// A row's height in a stacked group, base points.
pub const ROW_PITCH: f32 = 22.0;
const STACK_HEAD: f32 = 26.0;
const STACK_FOOT: f32 = 6.0;

#[derive(Debug, Clone, PartialEq)]
pub struct RowSpec {
    pub key: Arc<str>,
    pub label: Arc<str>,
    /// Centre from the group's top, base points.
    pub y: f32,
    /// The identity tint of the row's glyph (a lane's repository), if any.
    pub tint: Option<Rgba>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GroupSpec {
    pub key: Arc<str>,
    pub label: Arc<str>,
    pub h: f32,
    pub rows: Vec<RowSpec>,
    /// A stacked group's header and foot: its rows re-stack when one opens into tracks.
    pub stack: Option<(f32, f32)>,
}

/// A group whose rows stack at [`ROW_PITCH`] under a header (the CI and Backups lenses' shape).
pub fn stacked_group(
    key: &str,
    label: &str,
    rows: &[(Arc<str>, Arc<str>, Option<Rgba>)],
    foot: f32,
) -> GroupSpec {
    GroupSpec {
        key: key.into(),
        label: label.into(),
        h: STACK_HEAD + rows.len() as f32 * ROW_PITCH + STACK_FOOT + foot,
        rows: rows
            .iter()
            .enumerate()
            .map(|(i, (key, label, tint))| RowSpec {
                key: key.clone(),
                label: label.clone(),
                y: STACK_HEAD + ROW_PITCH / 2.0 + i as f32 * ROW_PITCH,
                tint: *tint,
            })
            .collect(),
        stack: Some((STACK_HEAD, STACK_FOOT + foot)),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LaidRow {
    pub key: Arc<str>,
    pub label: Arc<str>,
    pub tint: Option<Rgba>,
    pub index: usize,
    pub group: usize,
    /// Centre, points from the content top (unscrolled).
    pub y: f32,
    /// The band it answers hits in.
    pub top: f32,
    pub bottom: f32,
    /// A stacked row's slot height (taller once it opened into tracks).
    pub h: f32,
    /// Where its label sits: its centre, or its first pitch when it opened into tracks.
    pub label_y: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LaidGroup {
    pub key: Arc<str>,
    pub label: Arc<str>,
    pub top: f32,
    pub h: f32,
    pub rows: std::ops::Range<usize>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Layout {
    pub k: f32,
    pub groups: Vec<LaidGroup>,
    pub rows: Vec<LaidRow>,
    pub by_key: HashMap<Arc<str>, usize>,
    /// The content's height, the axis included.
    pub height: f32,
}

impl Layout {
    /// Lay `groups` out at size `k`. `row_h` (base points) opens a stacked group's rows into
    /// taller slots (a CI lane's tracks) and its group grows to hold them.
    pub fn of(groups: &[GroupSpec], k: f32, row_h: impl Fn(&str) -> Option<f32>) -> Layout {
        let mut out = Layout {
            k,
            ..Layout::default()
        };
        let mut top = AXIS_PT;
        for g in groups {
            let slots: Option<Vec<f32>> = g.stack.map(|_| {
                g.rows
                    .iter()
                    .map(|r| ROW_PITCH.max(row_h(&r.key).unwrap_or(ROW_PITCH)))
                    .collect()
            });
            let gh = match (&slots, g.stack) {
                (Some(s), Some((head, foot))) => head + s.iter().sum::<f32>() + foot,
                _ => g.h,
            };
            let h = (gh * k).round();
            let first = out.rows.len();
            let mut at = g.stack.map_or(0.0, |(head, _)| head);
            for (i, r) in g.rows.iter().enumerate() {
                let index = out.rows.len();
                let row = match &slots {
                    Some(s) => {
                        let slot = s[i];
                        let row_top = top + at * k;
                        at += slot;
                        LaidRow {
                            key: r.key.clone(),
                            label: r.label.clone(),
                            tint: r.tint,
                            index,
                            group: out.groups.len(),
                            y: row_top + slot * k / 2.0,
                            top: row_top,
                            bottom: row_top + slot * k,
                            h: slot * k,
                            label_y: row_top + ROW_PITCH * k / 2.0,
                        }
                    }
                    None => LaidRow {
                        key: r.key.clone(),
                        label: r.label.clone(),
                        tint: r.tint,
                        index,
                        group: out.groups.len(),
                        y: top + r.y * k,
                        top,
                        bottom: top + h,
                        h: ROW_PITCH * k,
                        label_y: top + r.y * k,
                    },
                };
                out.by_key.insert(r.key.clone(), index);
                out.rows.push(row);
            }
            // An unstacked group's rows answer half way to their neighbours.
            if slots.is_none() {
                let rows = &mut out.rows[first..];
                for i in 0..rows.len() {
                    if i > 0 {
                        rows[i].top = (rows[i - 1].y + rows[i].y) / 2.0;
                    }
                    if i + 1 < rows.len() {
                        rows[i].bottom = (rows[i].y + rows[i + 1].y) / 2.0;
                    }
                }
            }
            out.groups.push(LaidGroup {
                key: g.key.clone(),
                label: g.label.clone(),
                top,
                h,
                rows: first..out.rows.len(),
            });
            top += h;
        }
        out.height = top;
        out
    }

    /// The row whose band holds content point `y`.
    pub fn row_at(&self, y: f32) -> Option<&LaidRow> {
        self.rows.iter().find(|r| y >= r.top && y < r.bottom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(n: usize) -> Vec<(Arc<str>, Arc<str>, Option<Rgba>)> {
        (0..n)
            .map(|i| (format!("r{i}").into(), format!("lane {i}").into(), None))
            .collect()
    }

    #[test]
    fn a_stacked_group_grows_when_a_row_opens_into_tracks() {
        let g = [stacked_group("org", "Org", &rows(3), 0.0)];
        let plain = Layout::of(&g, 1.0, |_| None);
        assert_eq!(plain.groups[0].h, 26.0 + 3.0 * 22.0 + 6.0);
        let opened = Layout::of(&g, 1.0, |k| (k == "r1").then_some(60.0));
        assert_eq!(opened.groups[0].h, plain.groups[0].h + 38.0);
        let r1 = &opened.rows[1];
        assert_eq!(
            (r1.top, r1.bottom),
            (AXIS_PT + 26.0 + 22.0, AXIS_PT + 26.0 + 82.0)
        );
        assert_eq!(opened.row_at(r1.top + 50.0).map(|r| r.index), Some(1));
        assert_eq!(
            opened.rows[2].top, r1.bottom,
            "the next row stacks under it"
        );
    }
}
