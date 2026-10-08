//! Wall-clock helpers. Timestamps are epoch ms UTC (PLAN.md 10.1).

use std::ops::Range;

use chrono::{DateTime, Datelike, NaiveDate, Offset, TimeDelta, TimeZone, Utc};
use chrono_tz::Tz;

pub const MS_PER_MINUTE: i64 = 60_000;
/// Windows are aligned to UTC multiples of 5 minutes. For timezones with a whole-5-minute
/// offset this is the same as wall-clock alignment.
pub const MS_PER_WINDOW: i64 = 300_000;
/// Night window is 00:00 to 06:00 local (PLAN.md 8.1, 8.3).
pub const NIGHT_END_HOUR: u32 = 6;

/// A calendar date in the user's timezone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LocalDay {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

/// The local calendar day that contains `ts_ms`.
pub fn local_day_containing(ts_ms: i64, tz: Tz) -> LocalDay {
    let local = utc_from_ms(ts_ms).with_timezone(&tz);
    LocalDay {
        year: local.year(),
        month: local.month(),
        day: local.day(),
    }
}

/// The calendar day `days` days away. Negative values go back in time.
/// Pure date arithmetic, so no timezone is involved.
pub fn adding_days(days: i64, day: LocalDay) -> LocalDay {
    let shifted = naive_date(day)
        .checked_add_signed(TimeDelta::days(days))
        .expect("calendar day in range");
    LocalDay {
        year: shifted.year(),
        month: shifted.month(),
        day: shifted.day(),
    }
}

/// Epoch ms of `hour`:00 local on `day`.
///
/// The offset is resolved by hand instead of with a local-time constructor, which fails for a
/// wall-clock time that DST skipped. Two passes settle the offset when a transition falls between
/// the UTC guess and the answer.
pub fn local_time(day: LocalDay, hour: u32, tz: Tz) -> i64 {
    let wall_ms = wall_clock_ms(day, hour);
    let mut instant_ms = wall_ms - offset_ms_at(tz, wall_ms);
    for _ in 0..2 {
        instant_ms = wall_ms - offset_ms_at(tz, instant_ms);
    }
    instant_ms
}

/// Half-open night window [00:00, 06:00) local on `day`.
pub fn night_window(day: LocalDay, tz: Tz) -> Range<i64> {
    local_time(day, 0, tz)..local_time(day, NIGHT_END_HOUR, tz)
}

/// Rounds down to a multiple of `size` ms. Correct for negative timestamps.
pub fn round_down(ts_ms: i64, size: i64) -> i64 {
    ts_ms - ts_ms.rem_euclid(size)
}

/// Rounds up to a multiple of `size` ms.
pub fn round_up(ts_ms: i64, size: i64) -> i64 {
    let down = round_down(ts_ms, size);
    if down == ts_ms { down } else { down + size }
}

/// Multiples of `step` in the half-open range `[lower, upper)`, ascending.
pub fn starts(lower: i64, upper: i64, step: i64) -> Vec<i64> {
    (lower..upper).step_by(step as usize).collect()
}

fn utc_from_ms(ts_ms: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(ts_ms).expect("timestamp in chrono range")
}

fn naive_date(day: LocalDay) -> NaiveDate {
    NaiveDate::from_ymd_opt(day.year, day.month, day.day).expect("valid calendar day")
}

/// The wall-clock time read as if it were UTC, in epoch ms.
fn wall_clock_ms(day: LocalDay, hour: u32) -> i64 {
    naive_date(day)
        .and_hms_opt(hour, 0, 0)
        .expect("valid hour")
        .and_utc()
        .timestamp_millis()
}

/// The zone's offset from UTC at the instant `instant_ms`, in ms.
fn offset_ms_at(tz: Tz, instant_ms: i64) -> i64 {
    let instant = utc_from_ms(instant_ms);
    let seconds = tz
        .offset_from_utc_datetime(&instant.naive_utc())
        .fix()
        .local_minus_utc();
    i64::from(seconds) * 1000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding_is_correct_for_negative_timestamps() {
        assert_eq!(round_down(-1, MS_PER_WINDOW), -MS_PER_WINDOW);
        assert_eq!(round_up(-1, MS_PER_WINDOW), 0);
        assert_eq!(round_up(0, MS_PER_WINDOW), 0);
    }

    #[test]
    fn adding_days_crosses_month_boundaries() {
        let day = LocalDay {
            year: 2026,
            month: 3,
            day: 1,
        };
        assert_eq!(
            adding_days(-1, day),
            LocalDay {
                year: 2026,
                month: 2,
                day: 28
            }
        );
    }
}
