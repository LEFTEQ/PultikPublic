//! The agents lens: what agents did over time. A turn is a bar from its first working moment to
//! its end, a wait on the person a bar from its question to its answer, a job a bar from its start
//! to its end, a sleep or a hold a quiet bar, and an exit a point. Colour means status as the rest
//! of the host's screens say it: a wait is always the palette's `warning` (the host's "needs you"),
//! a failure `danger`, a running item carries the `ok` head and reaches now, an interrupted or
//! stopped one is an outline. One lens draws both shapes ([`Rows`]): an agent's own history, one
//! row per kind, and a fleet, one row per agent. Items never fold; a row opens into a track per
//! item running at once (a job beside a job).

use super::{Lens, LensSpec, Palette};
use crate::density::FoldRules;
use crate::geometry::ZoomPolicy;
use crate::mark::{Inset, Mark, Paint, Shape, Span};
use crate::time::{DAY_MS, HOUR_MS, Ms, SECOND_MS, Words};
use crate::tracks::Tracking;
use canvas_draw::Rgba;
use std::sync::Arc;

/// The row an agent's own turns are drawn on ([`Rows::Kinds`]).
pub const ROW_TURNS: &str = "turns";
/// Its waits on the person.
pub const ROW_WAITS: &str = "waits";
/// Its jobs.
pub const ROW_JOBS: &str = "jobs";
/// Its sleeps, holds and exits.
pub const ROW_LIFE: &str = "life";

/// What one item of an agent's history is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentKind {
    /// From its first working moment to the turn's end.
    Turn,
    /// From a question it raised to the person's answer (or its withdrawal).
    Wait,
    /// A job it ran (a workflow, a background command, a monitor, a sub-agent).
    Job,
    /// Asleep (hibernated) until it was woken.
    Sleep,
    /// A person held it: nothing wakes or respawns it.
    Held,
    /// Its process ended: a point.
    Exit,
}

impl AgentKind {
    /// Its row on an agent's own timeline.
    pub fn row(self) -> &'static str {
        match self {
            AgentKind::Turn => ROW_TURNS,
            AgentKind::Wait => ROW_WAITS,
            AgentKind::Job => ROW_JOBS,
            AgentKind::Sleep | AgentKind::Held | AgentKind::Exit => ROW_LIFE,
        }
    }

    /// What a cluster counts it by.
    pub fn word(self) -> &'static str {
        match self {
            AgentKind::Turn => "turn",
            AgentKind::Wait => "wait",
            AgentKind::Job => "job",
            AgentKind::Sleep => "sleep",
            AgentKind::Held => "held",
            AgentKind::Exit => "exit",
        }
    }
}

/// How an item ended, or that it has not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AgentOutcome {
    /// Still running, waiting, asleep or held: drawn to now.
    Open,
    /// Ended as it should: a turn's end, an answered wait, a completed job, a clean exit.
    Done,
    Failed,
    /// Cut short by something else: a restart, an exit mid-turn, a person's stop.
    Interrupted,
    /// Its end was never said.
    Unknown,
}

impl AgentOutcome {
    pub fn open(self) -> bool {
        self == AgentOutcome::Open
    }
}

/// One item of an agent's history, times in ms.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentItem {
    /// Unique across the timeline.
    pub id: Arc<str>,
    /// Its agent's key: its row in a fleet ([`Rows::Agents`]).
    pub agent: Arc<str>,
    pub kind: AgentKind,
    pub start: Ms,
    /// `None`: still open, it reaches now.
    pub end: Option<Ms>,
    pub outcome: AgentOutcome,
    /// What it is, as the host words it ("Turn", a job's name).
    pub label: Arc<str>,
}

/// Which rows a timeline of agents has.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Rows {
    /// One agent: a row per kind ([`ROW_TURNS`], [`ROW_WAITS`], [`ROW_JOBS`], [`ROW_LIFE`]).
    #[default]
    Kinds,
    /// A fleet: a row per agent, its key the item's `agent`.
    Agents,
}

/// An agent's turns are minutes long and a busy one runs a few hundred a day: marks hold out to
/// a fortnight per screen, as far as the daemon's bounded read reaches, and bins take over past it.
pub const ZOOM: ZoomPolicy = ZoomPolicy {
    from_days: 14.0,
    full_days: 21.0,
    bucket: |days| {
        if days <= 30.0 { 6.0 * HOUR_MS } else { DAY_MS }
    },
};

#[derive(Debug, Clone, Copy, Default)]
pub struct AgentsLens {
    pub rows: Rows,
}

impl AgentsLens {
    pub const fn new(rows: Rows) -> AgentsLens {
        AgentsLens { rows }
    }
}

impl Lens for AgentsLens {
    type Item = AgentItem;

    fn spec(&self) -> LensSpec {
        LensSpec {
            key: "agents",
            zoom: ZOOM,
            fold: FoldRules {
                folds: false,
                // A sleep or a hold can last weeks.
                reach: 30.0 * DAY_MS,
            },
            tracks: Tracking::Zoomed,
            future: 60.0 * SECOND_MS,
        }
    }

    fn mark(&self, a: &AgentItem, p: &Palette) -> Mark {
        self.mark_in(a, p, Words::english())
    }
}

impl AgentsLens {
    /// `a` as the engine draws it, its durations in `words`.
    pub fn mark_in(&self, a: &AgentItem, p: &Palette, words: &Words) -> Mark {
        let open = a.outcome.open();
        let point = a.kind == AgentKind::Exit;
        let mut text: Vec<Arc<str>> = vec![a.label.clone()];
        if let Some(end) = a.end.filter(|_| !point) {
            text.push(format!("{} · {}", a.label, words.duration(end - a.start)).into());
        }
        let fill = match a.kind {
            // Red in the host's words: the person is waited on, open or answered.
            AgentKind::Wait => p.warning,
            AgentKind::Sleep => p.muted.with_alpha(0.35),
            AgentKind::Held => p.muted.with_alpha(0.2),
            AgentKind::Turn | AgentKind::Job | AgentKind::Exit => p.data,
        };
        let mut paint = Paint {
            shape: if point { Shape::Diamond } else { Shape::Rect },
            w: 9.0,
            h: 9.0,
            r: if point { 0.0 } else { 2.5 },
            dy: 0.0,
            fill: Some(fill),
            inset: None,
            ring: None,
            glyph: None,
            above: None,
            beside: None,
            live: open.then_some(match a.kind {
                AgentKind::Wait => p.warning,
                AgentKind::Turn | AgentKind::Job => p.ok,
                AgentKind::Sleep | AgentKind::Held | AgentKind::Exit => p.muted,
            }),
            span: (!point).then(|| Span {
                run: Some(a.start),
                end: a.end,
                lead: p.foreground.with_alpha(0.5),
                wait: None,
                core: None,
                text,
                ink: p.background,
                stretches: Vec::new(),
                cap: None,
            }),
        };
        match a.outcome {
            AgentOutcome::Failed => {
                paint.fill = Some(p.danger);
                if let Some(s) = &mut paint.span {
                    s.ink = Rgba::WHITE;
                }
            }
            AgentOutcome::Interrupted if a.kind != AgentKind::Wait => {
                paint.fill = None;
                paint.inset = Some(Inset {
                    color: p.foreground.with_alpha(0.45),
                    width: 1.5,
                });
                if let Some(s) = &mut paint.span {
                    s.ink = p.foreground;
                }
            }
            AgentOutcome::Unknown if a.kind != AgentKind::Wait => {
                paint.fill = Some(fill.with_alpha(0.45));
            }
            _ => {}
        }
        if matches!(a.kind, AgentKind::Sleep | AgentKind::Held)
            && let Some(s) = &mut paint.span
        {
            s.ink = p.foreground;
        }
        let row = match self.rows {
            Rows::Kinds => Arc::from(a.kind.row()),
            Rows::Agents => a.agent.clone(),
        };
        Mark {
            id: a.id.clone(),
            row,
            start: a.start,
            outcome: if point {
                a.start
            } else {
                a.end.unwrap_or(a.start)
            },
            end: if point { Some(a.start) } else { a.end },
            scheduled: false,
            live: open,
            stands_out: open || a.kind == AgentKind::Wait || a.outcome == AgentOutcome::Failed,
            steppable: !open,
            snap_weight: 1.0,
            sort: Arc::from(a.kind.word()),
            schedule: None,
            paint,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: Ms = 60.0 * SECOND_MS;

    fn item(kind: AgentKind, outcome: AgentOutcome) -> AgentItem {
        AgentItem {
            id: format!("{}-1", kind.word()).into(),
            agent: "a1".into(),
            kind,
            start: 10.0 * MIN,
            end: (!outcome.open()).then_some(14.0 * MIN + 12.0 * SECOND_MS),
            outcome,
            label: "Turn".into(),
        }
    }

    /// A host palette whose "needs you" (`warning`) is red and whose failure (`danger`) is amber.
    fn agent_os() -> Palette {
        Palette {
            warning: Rgba::hex(0xff5d63),
            danger: Rgba::hex(0xffb547),
            ..Palette::default()
        }
    }

    #[test]
    fn each_kind_lands_on_its_row_on_a_page_and_on_its_agent_in_a_fleet() {
        let p = Palette::default();
        let page = AgentsLens::new(Rows::Kinds);
        let fleet = AgentsLens::new(Rows::Agents);
        for (kind, row) in [
            (AgentKind::Turn, ROW_TURNS),
            (AgentKind::Wait, ROW_WAITS),
            (AgentKind::Job, ROW_JOBS),
            (AgentKind::Sleep, ROW_LIFE),
            (AgentKind::Held, ROW_LIFE),
            (AgentKind::Exit, ROW_LIFE),
        ] {
            let it = item(kind, AgentOutcome::Done);
            assert_eq!(&*page.mark(&it, &p).row, row, "{kind:?}");
            assert_eq!(&*fleet.mark(&it, &p).row, "a1", "{kind:?}");
        }
    }

    #[test]
    fn a_wait_is_red_and_a_failed_turn_amber() {
        let p = agent_os();
        let lens = AgentsLens::default();
        for outcome in [AgentOutcome::Open, AgentOutcome::Done] {
            let wait = lens.mark(&item(AgentKind::Wait, outcome), &p);
            assert_eq!(wait.paint.fill, Some(Rgba::hex(0xff5d63)), "{outcome:?}");
            assert!(wait.stands_out);
        }
        let failed = lens.mark(&item(AgentKind::Turn, AgentOutcome::Failed), &p);
        assert_eq!(failed.paint.fill, Some(Rgba::hex(0xffb547)));
        assert!(failed.stands_out && failed.steppable);
        let done = lens.mark(&item(AgentKind::Turn, AgentOutcome::Done), &p);
        assert_eq!(done.paint.fill, Some(p.data));
        assert!(!done.stands_out);
    }

    #[test]
    fn a_turn_spans_to_its_end_and_a_running_one_reaches_now() {
        let p = Palette::default();
        let lens = AgentsLens::default();
        let done = lens.mark(&item(AgentKind::Turn, AgentOutcome::Done), &p);
        assert_eq!(
            (done.start, done.end),
            (10.0 * MIN, Some(14.0 * MIN + 12_000.0))
        );
        assert_eq!(done.outcome, 14.0 * MIN + 12_000.0);
        let span = done.paint.span.as_ref().expect("a turn is a span");
        assert_eq!(&*span.text[1], "Turn · 4 min 12 s");
        let running = lens.mark(&item(AgentKind::Turn, AgentOutcome::Open), &p);
        assert_eq!(running.end, None);
        assert_eq!(running.paint.live, Some(p.ok));
        assert!(running.live && running.stands_out && !running.steppable);
        let open_wait = lens.mark(&item(AgentKind::Wait, AgentOutcome::Open), &p);
        assert_eq!(open_wait.paint.live, Some(p.warning));
    }

    #[test]
    fn an_interrupted_turn_is_an_outline_and_an_exit_a_point() {
        let p = Palette::default();
        let lens = AgentsLens::default();
        let cut = lens.mark(&item(AgentKind::Turn, AgentOutcome::Interrupted), &p);
        assert_eq!(cut.paint.fill, None);
        assert!(cut.paint.inset.is_some());
        let exit = lens.mark(&item(AgentKind::Exit, AgentOutcome::Done), &p);
        assert_eq!(exit.paint.shape, Shape::Diamond);
        assert_eq!(exit.end, Some(exit.start));
        assert!(exit.paint.span.is_none());
        let crashed = lens.mark(&item(AgentKind::Exit, AgentOutcome::Failed), &p);
        assert_eq!(crashed.paint.fill, Some(p.danger));
    }
}
