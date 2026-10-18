//! Heart-rate aggregate per UTC minute (PLAN.md 8.1).

use std::collections::BTreeMap;

use super::local_time::{MS_PER_MINUTE, round_down};
use super::samples::{HeartRateSample, SensorContact};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MinuteAggregate {
    /// Minute start, epoch ms UTC.
    pub minute_ms: i64,
    pub hr_avg: f64,
    pub hr_min: i64,
    pub hr_max: i64,
    pub hr_n: usize,
}

impl MinuteAggregate {
    /// samples / 60 (PLAN.md 8.1).
    pub fn coverage(&self) -> f64 {
        self.hr_n as f64 / 60.0
    }
}

struct Accumulator {
    sum: i64,
    min: i64,
    max: i64,
    n: usize,
}

/// Groups samples by UTC minute. Samples with contact `NotDetected` are dropped.
/// Output is sorted by minute. Minutes with no kept sample are omitted.
///
/// Duplicate timestamps are counted as given. The caller removes duplicates per band.
pub fn aggregate(samples: &[HeartRateSample]) -> Vec<MinuteAggregate> {
    let mut accumulators: BTreeMap<i64, Accumulator> = BTreeMap::new();
    for sample in samples {
        if sample.contact == Some(SensorContact::NotDetected) {
            continue;
        }
        let minute = round_down(sample.ts_ms, MS_PER_MINUTE);
        let acc = accumulators.entry(minute).or_insert(Accumulator {
            sum: 0,
            min: i64::MAX,
            max: i64::MIN,
            n: 0,
        });
        acc.sum += sample.bpm;
        acc.min = acc.min.min(sample.bpm);
        acc.max = acc.max.max(sample.bpm);
        acc.n += 1;
    }
    accumulators
        .into_iter()
        .map(|(minute_ms, acc)| MinuteAggregate {
            minute_ms,
            hr_avg: acc.sum as f64 / acc.n as f64,
            hr_min: acc.min,
            hr_max: acc.max,
            hr_n: acc.n,
        })
        .collect()
}
