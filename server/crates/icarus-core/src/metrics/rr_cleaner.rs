//! R-R cleaning, PLAN.md 8.2 steps 1-2.

use std::ops::RangeInclusive;

use super::samples::RRSample;
use super::statistics::median;

/// Step 1: physiological range in milliseconds.
pub const VALID_RANGE_MS: RangeInclusive<f64> = 300.0..=2000.0;
/// Step 2: number of previously accepted intervals used for the local median.
pub const MEDIAN_WINDOW: usize = 11;
/// Step 2: reject when |rr - median| > MAX_DEVIATION * median.
pub const MAX_DEVIATION: f64 = 0.20;

/// One flag per input interval, true when the interval is accepted.
///
/// The first interval is judged on the range filter alone, because there is no history yet.
/// Rejected intervals never enter the median window.
pub fn accepted_flags(rr_ms: &[f64]) -> Vec<bool> {
    let mut recent: Vec<f64> = Vec::with_capacity(MEDIAN_WINDOW + 1);
    let mut flags = Vec::with_capacity(rr_ms.len());
    for &rr in rr_ms {
        let mut accepted = VALID_RANGE_MS.contains(&rr);
        if accepted && let Some(reference) = median(&recent) {
            accepted = (rr - reference).abs() <= MAX_DEVIATION * reference;
        }
        flags.push(accepted);
        if accepted {
            recent.push(rr);
            if recent.len() > MEDIAN_WINDOW {
                recent.remove(0);
            }
        }
    }
    flags
}

/// The intervals that pass `accepted_flags`, in the same order.
pub fn accepted(intervals: &[RRSample]) -> Vec<RRSample> {
    let rr_ms: Vec<f64> = intervals.iter().map(|s| s.rr_ms).collect();
    intervals
        .iter()
        .zip(accepted_flags(&rr_ms))
        .filter_map(|(sample, keep)| keep.then_some(*sample))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_has_no_flags() {
        assert!(accepted_flags(&[]).is_empty());
        assert!(accepted(&[]).is_empty());
    }

    #[test]
    fn range_rejects_never_enter_the_median_window() {
        // 299 fails the range filter, so the 800 that follows is judged with no history.
        // 1000 is more than 20% above the median of the accepted 800s, so it is rejected.
        assert_eq!(
            accepted_flags(&[299.0, 800.0, 1000.0, 800.0]),
            vec![false, true, false, true]
        );
    }
}
