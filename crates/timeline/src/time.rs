//! Time on the axis: milliseconds since the Unix epoch (`f64`, exact far past any date drawn),
//! the wall clock the labels read and the axis's ticks.
//!
//! The clock is the host's ([`Clock`]): a [`Zone`] (an offset source, never an IANA database)
//! and a [`Words`] table (every weekday, month, tick, span and duration word). The default is
//! Prague (CET, CEST from the last Sunday of March to the last Sunday of October, both at 01:00
//! UTC, the EU rule) in English, what both native apps draw; a browser host hands the
//! viewer's zone as a transition table and its locale's words.

use std::sync::{Arc, OnceLock};

pub type Ms = f64;

pub const SECOND_MS: Ms = 1_000.0;
pub const MIN_MS: Ms = 60_000.0;
pub const HOUR_MS: Ms = 60.0 * MIN_MS;
pub const DAY_MS: Ms = 24.0 * HOUR_MS;

/// Days since 1970-01-01 of a civil date (proleptic Gregorian; Hinnant's algorithm).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (i64::from(m) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of a day number: (year, month 1–12, day 1–31).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 0 = Sunday.
fn weekday(days: i64) -> u32 {
    (days + 4).rem_euclid(7) as u32
}

/// The day number of the last Sunday of `month` in `year`.
fn last_sunday(year: i64, month: u32) -> i64 {
    let first_of_next = if month == 12 {
        days_from_civil(year + 1, 1, 1)
    } else {
        days_from_civil(year, month + 1, 1)
    };
    let last = first_of_next - 1;
    last - i64::from(weekday(last))
}

/// Prague's offset from UTC at instant `t`, minutes: 120 in summer time, 60 otherwise.
pub fn prague_offset_min(t: Ms) -> i32 {
    let days = (t / DAY_MS).floor() as i64;
    let (year, _, _) = civil_from_days(days);
    let start = last_sunday(year, 3) as f64 * DAY_MS + HOUR_MS;
    let end = last_sunday(year, 10) as f64 * DAY_MS + HOUR_MS;
    if t >= start && t < end { 120 } else { 60 }
}

/// Wall-clock fields of an instant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Local {
    pub year: i64,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    /// 0 = Sunday.
    pub weekday: u32,
}

/// Prague wall-clock fields of `t`.
pub fn local(t: Ms) -> Local {
    local_in(t, &Zone::Prague)
}

/// `zone`'s wall-clock fields of `t`.
pub fn local_in(t: Ms, zone: &Zone) -> Local {
    let lt = t + f64::from(zone.offset_min(t)) * MIN_MS;
    let days = (lt / DAY_MS).floor() as i64;
    let (year, month, day) = civil_from_days(days);
    let in_day = (lt - days as f64 * DAY_MS).max(0.0);
    let secs = (in_day / SECOND_MS).floor() as u32;
    Local {
        year,
        month,
        day,
        hour: secs / 3600,
        minute: secs / 60 % 60,
        second: secs % 60,
        weekday: weekday(days),
    }
}

/// Where the wall clock stands against UTC: the offset source a host supplies. The engine holds
/// no zone database; a browser host builds a [`ZoneTable`] for the viewer's IANA zone (through
/// `Intl`) over the range it shows.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum Zone {
    /// The EU rule at CET (the default: both native apps' clock).
    #[default]
    Prague,
    /// A fixed offset from UTC, minutes (UTC is 0).
    Fixed(i32),
    /// Offsets that change at listed instants.
    Table(ZoneTable),
}

/// A zone as its offset changes: `initial` before the first change, then each change's offset
/// from its instant on.
#[derive(Debug, Clone, PartialEq)]
pub struct ZoneTable {
    initial: i32,
    changes: Arc<[(Ms, i32)]>,
}

/// The most a real zone is off UTC, minutes (±18 h, as ECMAScript and ISO 8601 allow).
pub const MAX_OFFSET_MIN: i32 = 18 * 60;

/// Why a zone table was refused.
#[derive(Debug, Clone, PartialEq)]
pub enum ZoneError {
    /// An offset beyond ±[`MAX_OFFSET_MIN`]; `at` is its change's instant (`None`: the initial).
    Offset { at: Option<Ms>, minutes: i32 },
    /// Change `index`'s instant is not finite or not after the one before it.
    Order { index: usize },
}

impl std::fmt::Display for ZoneError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ZoneError::Offset { at: None, minutes } => write!(
                f,
                "the initial offset {minutes} min is beyond ±{MAX_OFFSET_MIN} min"
            ),
            ZoneError::Offset {
                at: Some(at),
                minutes,
            } => write!(
                f,
                "the offset {minutes} min from {at} ms is beyond ±{MAX_OFFSET_MIN} min"
            ),
            ZoneError::Order { index } => write!(
                f,
                "change {index} is not a finite instant after the change before it; list changes in time order"
            ),
        }
    }
}

impl std::error::Error for ZoneError {}

impl ZoneTable {
    /// A table of `(instant, offset minutes)` changes in strictly increasing time.
    pub fn new(initial: i32, changes: Vec<(Ms, i32)>) -> Result<ZoneTable, ZoneError> {
        let possible = -MAX_OFFSET_MIN..=MAX_OFFSET_MIN;
        if !possible.contains(&initial) {
            return Err(ZoneError::Offset {
                at: None,
                minutes: initial,
            });
        }
        let mut last = f64::NEG_INFINITY;
        for (index, &(at, minutes)) in changes.iter().enumerate() {
            if !at.is_finite() || at <= last {
                return Err(ZoneError::Order { index });
            }
            if !possible.contains(&minutes) {
                return Err(ZoneError::Offset {
                    at: Some(at),
                    minutes,
                });
            }
            last = at;
        }
        Ok(ZoneTable {
            initial,
            changes: changes.into(),
        })
    }
}

impl Zone {
    /// The offset from UTC at instant `t`, minutes.
    pub fn offset_min(&self, t: Ms) -> i32 {
        match self {
            Zone::Prague => prague_offset_min(t),
            Zone::Fixed(m) => *m,
            Zone::Table(z) => match z.changes.partition_point(|&(at, _)| at <= t) {
                0 => z.initial,
                i => z.changes[i - 1].1,
            },
        }
    }
}

/// Every word the engine writes, as the host's locale says it. Templates name their fields in
/// braces: `{wd}` weekday, `{d}` day, `{dd}` two-digit day, `{mon}` month name, `{m}` month
/// number, `{y}` year, `{H}` / `{HH}` the 24-hour hour, `{h}` the 12-hour hour, `{ap}` its day
/// period, `{mm}` minutes; a span or period template's `{n}` is its number and a duration's
/// `{h}`, `{m}`, `{s}` its parts. An unknown field is written as it stands.
#[derive(Debug, Clone, PartialEq)]
pub struct Words {
    /// Sunday first.
    pub weekdays: [Arc<str>; 7],
    /// January first.
    pub months: [Arc<str>; 12],
    /// Before and after noon.
    pub day_periods: [Arc<str>; 2],
    /// The decimal separator of a span's number.
    pub decimal: char,
    /// A tick inside a day ("14:05").
    pub tick_time: Arc<str>,
    /// A local midnight between time ticks ("Sun 25 Oct").
    pub tick_midnight: Arc<str>,
    /// A tick a day or more apart ("Sun 25").
    pub tick_day: Arc<str>,
    /// A tick a week or more apart ("25 Oct").
    pub tick_week: Arc<str>,
    /// The zoom: minutes, hours or days per screen.
    pub span_min: Arc<str>,
    pub span_h: Arc<str>,
    pub span_d: Arc<str>,
    /// A cadence rail's period: seconds, minutes or hours.
    pub every_s: Arc<str>,
    pub every_min: Arc<str>,
    pub every_h: Arc<str>,
    /// A duration: `{s}`; `{m}`; `{m}` `{s}`; `{h}`; `{h}` `{m}`.
    pub dur_s: Arc<str>,
    pub dur_min: Arc<str>,
    pub dur_min_s: Arc<str>,
    pub dur_h: Arc<str>,
    pub dur_h_min: Arc<str>,
    /// A job still running, and the wait before it ran (`{d}`: a duration).
    pub running: Arc<str>,
    pub waited: Arc<str>,
}

impl Words {
    /// The English the engine wrote before words were the host's: the default.
    pub fn english() -> &'static Words {
        static EN: OnceLock<Words> = OnceLock::new();
        EN.get_or_init(|| {
            let a = |s: &str| -> Arc<str> { s.into() };
            Words {
                weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map(a),
                months: [
                    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
                    "Dec",
                ]
                .map(a),
                day_periods: ["AM", "PM"].map(a),
                decimal: '.',
                tick_time: a("{HH}:{mm}"),
                tick_midnight: a("{wd} {d} {mon}"),
                tick_day: a("{wd} {d}"),
                tick_week: a("{d} {mon}"),
                span_min: a("{n} min per screen"),
                span_h: a("{n} h per screen"),
                span_d: a("{n} d per screen"),
                every_s: a("every {n} s"),
                every_min: a("every {n} min"),
                every_h: a("every {n} h"),
                dur_s: a("{s} s"),
                dur_min: a("{m} min"),
                dur_min_s: a("{m} min {s} s"),
                dur_h: a("{h} h"),
                dur_h_min: a("{h} h {m} min"),
                running: a("running"),
                waited: a("waited {d}"),
            }
        })
    }

    /// `l` written by `template`.
    pub fn date(&self, template: &str, l: &Local) -> String {
        let h12 = match l.hour % 12 {
            0 => 12,
            h => h,
        };
        fill(template, |field, out| {
            match field {
                "wd" => out.push_str(&self.weekdays[l.weekday as usize % 7]),
                "d" => push_num(out, l.day, 1),
                "dd" => push_num(out, l.day, 2),
                "mon" => out.push_str(&self.months[(l.month as usize + 11) % 12]),
                "m" => push_num(out, l.month, 1),
                "y" => out.push_str(&l.year.to_string()),
                "H" => push_num(out, l.hour, 1),
                "HH" => push_num(out, l.hour, 2),
                "h" => push_num(out, h12, 1),
                "ap" => out.push_str(&self.day_periods[usize::from(l.hour >= 12)]),
                "mm" => push_num(out, l.minute, 2),
                _ => return false,
            }
            true
        })
    }

    fn number(&self, template: &str, n: &str) -> String {
        let n = if self.decimal == '.' {
            n.to_string()
        } else {
            n.replace('.', &self.decimal.to_string())
        };
        fill(template, |field, out| {
            match field {
                "n" => out.push_str(&n),
                _ => return false,
            }
            true
        })
    }

    /// "waited 41 s" for a wait.
    pub fn waited_for(&self, ms: Ms) -> String {
        let d = self.duration(ms);
        fill(&self.waited, |field, out| {
            match field {
                "d" => out.push_str(&d),
                _ => return false,
            }
            true
        })
    }

    /// "15 min per screen", "6 h per screen", "3.5 d per screen".
    pub fn span(&self, ms: Ms) -> String {
        let m = ms / MIN_MS;
        let short = |v: f64| {
            if v < 10.0 {
                let r = (v * 10.0).round() / 10.0;
                if r.fract() == 0.0 {
                    format!("{r:.0}")
                } else {
                    format!("{r:.1}")
                }
            } else {
                format!("{:.0}", v.round())
            }
        };
        if m < 90.0 {
            self.number(&self.span_min, &format!("{:.0}", m.round()))
        } else if m < 2880.0 {
            self.number(&self.span_h, &short(m / 60.0))
        } else {
            self.number(&self.span_d, &short(m / 1440.0))
        }
    }

    /// "every 5 min" for a period.
    pub fn every(&self, period: Ms) -> String {
        let s = period / SECOND_MS;
        if s < 60.0 {
            self.number(&self.every_s, &s.round().to_string())
        } else if s < 3600.0 {
            self.number(&self.every_min, &(s / 60.0).round().to_string())
        } else {
            self.number(&self.every_h, &format!("{:.1}", s / 3600.0))
        }
    }

    /// "4 min 12 s" for a duration.
    pub fn duration(&self, ms: Ms) -> String {
        let s = (ms / SECOND_MS).round().max(0.0) as u64;
        let (template, h, m, sec) = match s {
            0..60 => (&self.dur_s, 0, 0, s),
            60..3600 if s.is_multiple_of(60) => (&self.dur_min, 0, s / 60, 0),
            60..3600 => (&self.dur_min_s, 0, s / 60, s % 60),
            _ if s % 3600 / 60 == 0 => (&self.dur_h, s / 3600, 0, 0),
            _ => (&self.dur_h_min, s / 3600, s % 3600 / 60, 0),
        };
        fill(template, |field, out| {
            match field {
                "h" => out.push_str(&h.to_string()),
                "m" => out.push_str(&m.to_string()),
                "s" => out.push_str(&sec.to_string()),
                _ => return false,
            }
            true
        })
    }
}

impl Default for Words {
    fn default() -> Self {
        Words::english().clone()
    }
}

fn push_num(out: &mut String, n: u32, width: usize) {
    use std::fmt::Write;
    let _ = write!(out, "{n:0width$}");
}

/// `template` with each `{field}` written by `write` (false: an unknown field, kept as it is).
fn fill(template: &str, mut write: impl FnMut(&str, &mut String) -> bool) -> String {
    let mut out = String::with_capacity(template.len() + 8);
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}') {
            Some(close) => {
                let field = &after[..close];
                if !write(field, &mut out) {
                    out.push('{');
                    out.push_str(field);
                    out.push('}');
                }
                rest = &after[close + 1..];
            }
            None => {
                out.push_str(&rest[open..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

/// The clock a timeline reads: its zone and its words. The default is Prague in English.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Clock {
    pub zone: Zone,
    pub words: Arc<Words>,
}

/// "14:05", Prague.
pub fn clock(t: Ms) -> String {
    let l = local(t);
    format!("{:02}:{:02}", l.hour, l.minute)
}

/// "14:05:09", Prague.
pub fn clock_sec(t: Ms) -> String {
    let l = local(t);
    format!("{:02}:{:02}:{:02}", l.hour, l.minute, l.second)
}

/// "Mon 14 Oct", Prague, in English.
pub fn date_label(t: Ms) -> String {
    Words::english().date("{wd} {d} {mon}", &local(t))
}

/// "4 min 12 s" for a duration, in English.
pub fn duration(ms: Ms) -> String {
    Words::english().duration(ms)
}

/// "15 min per screen", "6 h per screen", "3.5 d per screen", in English.
pub fn span_label(ms: Ms) -> String {
    Words::english().span(ms)
}

/// Tick steps in minutes; the first that leaves at least [`TICK_GAP_PX`] between ticks wins.
const STEPS_MIN: [f64; 16] = [
    1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 180.0, 360.0, 720.0, 1440.0, 2880.0, 10080.0,
    20160.0, 43200.0,
];
pub const TICK_GAP_PX: f64 = 86.0;

#[derive(Debug, Clone, PartialEq)]
pub struct Tick {
    pub t: Ms,
    pub label: String,
    /// Local midnight: drawn stronger.
    pub day: bool,
}

/// Prague's ticks over `[from, to)` in English ([`ticks_in`] at the default clock).
pub fn ticks_between(from: Ms, to: Ms, scale: f64) -> Vec<Tick> {
    ticks_in(from, to, scale, &Clock::default())
}

/// Ticks over `[from, to)` at the step `scale` (px per ms) leaves room for, on `clock`. Each
/// tick takes the offset of its own instant, so a window across a DST change keeps its labels
/// on the local hour.
pub fn ticks_in(from: Ms, to: Ms, scale: f64, clock: &Clock) -> Vec<Tick> {
    let step_min = STEPS_MIN
        .into_iter()
        .find(|s| s * MIN_MS * scale >= TICK_GAP_PX)
        .unwrap_or(43200.0);
    let step = step_min * MIN_MS;
    let zone = &clock.zone;
    let words = &clock.words;
    let off = f64::from(zone.offset_min(from)) * MIN_MS;
    let mut out = Vec::new();
    let mut lt = ((from + off) / step).ceil() * step;
    while lt - off < to {
        let t = lt - f64::from(zone.offset_min(lt - off)) * MIN_MS;
        lt += step;
        // A local hour the spring change skips lands on the tick before it: drop it.
        if out.last().is_some_and(|p: &Tick| t <= p.t) {
            continue;
        }
        let l = local_in(t, zone);
        let day = l.hour == 0 && l.minute == 0;
        let template = if step_min >= 10080.0 {
            &words.tick_week
        } else if step_min >= 1440.0 {
            &words.tick_day
        } else if day {
            &words.tick_midnight
        } else {
            &words.tick_time
        };
        out.push(Tick {
            t,
            label: words.date(template, &l),
            day,
        });
    }
    out
}

/// The instant of a UTC civil time (Semafor's RFC 3339 `…Z` stamps, in tests and fixtures).
pub fn utc(year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> Ms {
    days_from_civil(year, month, day) as f64 * DAY_MS
        + f64::from(hour) * HOUR_MS
        + f64::from(minute) * MIN_MS
        + f64::from(second) * SECOND_MS
}

/// The instant of a Prague wall-clock time (for tests and fixtures).
pub fn prague(year: i64, month: u32, day: u32, hour: u32, minute: u32) -> Ms {
    let naive = days_from_civil(year, month, day) as f64 * DAY_MS
        + f64::from(hour) * HOUR_MS
        + f64::from(minute) * MIN_MS;
    // The offset at the instant itself: try summer time, keep it if it holds.
    let summer = naive - 120.0 * MIN_MS;
    if prague_offset_min(summer) == 120 {
        summer
    } else {
        naive - 60.0 * MIN_MS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_round_trips() {
        for days in [-1000, 0, 18_000, 20_000, 20_377, 30_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(weekday(0), 4, "1970-01-01 was a Thursday");
    }

    #[test]
    fn prague_switches_at_one_utc_on_the_last_sundays() {
        // 2026: summer time from 29 Mar 01:00 UTC to 25 Oct 01:00 UTC.
        let mar = days_from_civil(2026, 3, 29) as f64 * DAY_MS + HOUR_MS;
        assert_eq!(prague_offset_min(mar - 1.0), 60);
        assert_eq!(prague_offset_min(mar), 120);
        let oct = days_from_civil(2026, 10, 25) as f64 * DAY_MS + HOUR_MS;
        assert_eq!(prague_offset_min(oct - 1.0), 120);
        assert_eq!(prague_offset_min(oct), 60);
    }

    #[test]
    fn ticks_keep_the_local_hour_across_dst() {
        // Hourly ticks over the October change: the local labels never skip or repeat a step's
        // phase, and 03:00 CET follows 02:00 CET (the 02:00 hour happens twice in UTC terms).
        let from = prague(2026, 10, 25, 0, 0);
        let ticks = ticks_between(from, from + 5.0 * HOUR_MS, 120.0 / HOUR_MS);
        let labels: Vec<&str> = ticks.iter().map(|t| t.label.as_str()).collect();
        assert_eq!(labels[0], "Sun 25 Oct", "local midnight is a day tick");
        assert!(ticks[0].day);
        assert!(labels.contains(&"03:00") && labels.contains(&"04:00"));
        for w in ticks.windows(2) {
            assert!(w[1].t > w[0].t, "ticks advance");
        }
        // In March the 02:00 local hour does not exist: 01:00 then 03:00.
        let from = prague(2026, 3, 29, 0, 0);
        let ticks = ticks_between(from, from + 4.0 * HOUR_MS, 120.0 / HOUR_MS);
        let labels: Vec<&str> = ticks.iter().map(|t| t.label.as_str()).collect();
        assert_eq!(&labels[..3], &["Sun 29 Mar", "01:00", "03:00"]);
    }

    #[test]
    fn labels_read_prague() {
        let t = prague(2026, 10, 16, 14, 5);
        assert_eq!(clock(t), "14:05");
        assert_eq!(date_label(t), "Fri 16 Oct");
        assert_eq!(duration(252_000.0), "4 min 12 s");
        assert_eq!(span_label(15.0 * MIN_MS), "15 min per screen");
        assert_eq!(span_label(3.5 * DAY_MS), "3.5 d per screen");
    }

    /// New York as a browser host would hand it: EST, EDT from 8 Mar 2026 07:00 UTC, EST again
    /// from 1 Nov 2026 06:00 UTC.
    fn new_york() -> Zone {
        let edt = utc(2026, 3, 8, 7, 0, 0);
        let est = utc(2026, 11, 1, 6, 0, 0);
        Zone::Table(ZoneTable::new(-300, vec![(edt, -240), (est, -300)]).expect("a valid table"))
    }

    #[test]
    fn a_supplied_zone_moves_the_ticks_across_its_own_dst_change() {
        let z = new_york();
        let fall = utc(2026, 11, 1, 6, 0, 0);
        assert_eq!(z.offset_min(fall - 1.0), -240);
        assert_eq!(z.offset_min(fall), -300);
        assert_eq!(
            z.offset_min(utc(2026, 1, 1, 0, 0, 0)),
            -300,
            "before the first change"
        );
        let clock = Clock {
            zone: z,
            words: Arc::new(Words::default()),
        };
        // Local midnight of 1 Nov is 04:00 UTC (still EDT); hourly ticks then read 01:00 (EDT)
        // and 02:00 (EST): the repeated hour gets one tick, every tick advances.
        let from = utc(2026, 11, 1, 4, 0, 0);
        let ticks = ticks_in(from, from + 5.0 * HOUR_MS, 120.0 / HOUR_MS, &clock);
        let labels: Vec<&str> = ticks.iter().map(|t| t.label.as_str()).collect();
        assert_eq!(labels[0], "Sun 1 Nov");
        assert!(ticks[0].day);
        assert!(labels.contains(&"01:00") && labels.contains(&"02:00"));
        assert!(!labels.contains(&"05:00"), "not Prague's clock");
        for w in ticks.windows(2) {
            assert!(w[1].t > w[0].t, "ticks advance");
        }
        // Prague would call the same instant 05:00.
        assert_eq!(local(from).hour, 5);
        assert_eq!(local_in(from, &clock.zone).hour, 0);
        assert_eq!(local_in(from, &Zone::Fixed(0)).hour, 4);
    }

    #[test]
    fn a_zone_table_refuses_disorder_and_impossible_offsets() {
        assert_eq!(
            ZoneTable::new(60, vec![(10.0, 120), (10.0, 60)]),
            Err(ZoneError::Order { index: 1 })
        );
        assert_eq!(
            ZoneTable::new(60, vec![(f64::NAN, 120)]),
            Err(ZoneError::Order { index: 0 })
        );
        assert!(matches!(
            ZoneTable::new(19 * 60, vec![]),
            Err(ZoneError::Offset { at: None, .. })
        ));
        assert!(matches!(
            ZoneTable::new(i32::MIN, vec![]),
            Err(ZoneError::Offset { at: None, .. })
        ));
        assert!(matches!(
            ZoneTable::new(60, vec![(10.0, i32::MIN)]),
            Err(ZoneError::Offset { at: Some(_), .. })
        ));
    }

    #[test]
    fn supplied_words_write_every_label() {
        let a = |s: &str| -> Arc<str> { s.into() };
        let cs = Words {
            weekdays: ["ne", "po", "út", "st", "čt", "pá", "so"].map(a),
            months: [
                "led", "úno", "bře", "dub", "kvě", "čvn", "čvc", "srp", "zář", "říj", "lis", "pro",
            ]
            .map(a),
            decimal: ',',
            tick_midnight: a("{wd} {d}. {m}."),
            tick_day: a("{wd} {d}."),
            tick_week: a("{d}. {mon}"),
            span_d: a("{n} dne na obrazovku"),
            every_min: a("každých {n} min"),
            dur_min_s: a("{m} min {s} s"),
            ..Words::default()
        };
        let clock = Clock {
            zone: Zone::Prague,
            words: Arc::new(cs.clone()),
        };
        let from = prague(2026, 10, 25, 0, 0);
        let ticks = ticks_in(from, from + 3.0 * HOUR_MS, 120.0 / HOUR_MS, &clock);
        assert_eq!(ticks[0].label, "ne 25. 10.");
        let days = ticks_in(from, from + 3.0 * DAY_MS, 120.0 / DAY_MS, &clock);
        assert_eq!(days[0].label, "ne 25.");
        let weeks = ticks_in(from, from + 60.0 * DAY_MS, 12.0 / DAY_MS, &clock);
        assert!(weeks.iter().any(|t| t.label.ends_with(". lis")));
        assert_eq!(cs.span(3.5 * DAY_MS), "3,5 dne na obrazovku");
        assert_eq!(cs.every(5.0 * MIN_MS), "každých 5 min");
        assert_eq!(cs.duration(252_000.0), "4 min 12 s");
        let twelve = Words {
            tick_time: a("{h} {ap}"),
            ..Words::default()
        };
        let l = local(prague(2026, 10, 16, 14, 5));
        assert_eq!(twelve.date(&twelve.tick_time, &l), "2 PM");
        assert_eq!(
            twelve.date("{y}-{m} {x}", &l),
            "2026-10 {x}",
            "unknown fields stay"
        );
    }
}
