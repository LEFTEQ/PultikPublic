//! Time on the axis: milliseconds since the Unix epoch (`f64`, exact far past any date drawn),
//! the Prague wall clock the labels read (CET, CEST from the last Sunday of March to the last
//! Sunday of October, both at 01:00 UTC, the EU rule), and the axis's ticks.

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

/// Prague wall-clock fields of `t`.
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

pub fn local(t: Ms) -> Local {
    let lt = t + f64::from(prague_offset_min(t)) * MIN_MS;
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

const DOW: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MON: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

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

/// "Mon 14 Oct", Prague.
pub fn date_label(t: Ms) -> String {
    let l = local(t);
    format!(
        "{} {} {}",
        DOW[l.weekday as usize],
        l.day,
        MON[l.month as usize - 1]
    )
}

/// "4 min 12 s" for a duration.
pub fn duration(ms: Ms) -> String {
    let s = (ms / SECOND_MS).round().max(0.0) as u64;
    match s {
        0..60 => format!("{s} s"),
        60..3600 if s.is_multiple_of(60) => format!("{} min", s / 60),
        60..3600 => format!("{} min {} s", s / 60, s % 60),
        _ if s % 3600 / 60 == 0 => format!("{} h", s / 3600),
        _ => format!("{} h {} min", s / 3600, s % 3600 / 60),
    }
}

/// "15 min per screen", "6 h per screen", "3.5 d per screen".
pub fn span_label(ms: Ms) -> String {
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
        format!("{:.0} min per screen", m.round())
    } else if m < 2880.0 {
        format!("{} h per screen", short(m / 60.0))
    } else {
        format!("{} d per screen", short(m / 1440.0))
    }
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

/// Ticks over `[from, to)` at the step `scale` (px per ms) leaves room for. Each tick takes the
/// Prague offset of its own instant, so a window across a DST change keeps its labels on the
/// local hour.
pub fn ticks_between(from: Ms, to: Ms, scale: f64) -> Vec<Tick> {
    let step_min = STEPS_MIN
        .into_iter()
        .find(|s| s * MIN_MS * scale >= TICK_GAP_PX)
        .unwrap_or(43200.0);
    let step = step_min * MIN_MS;
    let off = f64::from(prague_offset_min(from)) * MIN_MS;
    let mut out = Vec::new();
    let mut lt = ((from + off) / step).ceil() * step;
    while lt - off < to {
        let t = lt - f64::from(prague_offset_min(lt - off)) * MIN_MS;
        lt += step;
        // A local hour the spring change skips lands on the tick before it: drop it.
        if out.last().is_some_and(|p: &Tick| t <= p.t) {
            continue;
        }
        let l = local(t);
        let day = l.hour == 0 && l.minute == 0;
        let date = format!("{} {}", DOW[l.weekday as usize], l.day);
        let label = if step_min >= 10080.0 {
            format!("{} {}", l.day, MON[l.month as usize - 1])
        } else if step_min >= 1440.0 {
            date
        } else if day {
            format!("{date} {}", MON[l.month as usize - 1])
        } else {
            format!("{:02}:{:02}", l.hour, l.minute)
        };
        out.push(Tick { t, label, day });
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
}
