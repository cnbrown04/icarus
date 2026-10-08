//! Baevsky stress index (PLAN.md 8.3), as Kubios computes it.
//!
//! TODO(PLAN.md 8.3): Kubios removes the very-low-frequency trend before computing SI. We do not
//! detrend yet, so values are not directly comparable with Kubios output.

use std::collections::BTreeMap;

use super::statistics::median;

/// Histogram bin width in ms (PLAN.md 8.3).
pub const BIN_WIDTH_MS: f64 = 50.0;

/// SI = AMo / (2 * Mo * MxDMn), with AMo in %, Mo in s and MxDMn in s.
///
/// Bins start at multiples of 50 ms, so the mode is independent of where the data starts.
/// `None` for fewer than 2 intervals or when all intervals are equal.
pub fn stress_index(rr_ms: &[f64]) -> Option<f64> {
    if rr_ms.len() < 2 {
        return None;
    }
    let low = rr_ms.iter().copied().fold(f64::INFINITY, f64::min);
    let high = rr_ms.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    if high <= low {
        return None;
    }
    let median_ms = median(rr_ms)?;

    let mut counts: BTreeMap<i64, usize> = BTreeMap::new();
    for &rr in rr_ms {
        *counts
            .entry((rr / BIN_WIDTH_MS).floor() as i64)
            .or_insert(0) += 1;
    }
    let mode_count = counts.values().copied().max().unwrap_or(0);
    let amo_percent = mode_count as f64 / rr_ms.len() as f64 * 100.0;
    let mo_seconds = median_ms / 1000.0;
    let mxdmn_seconds = (high - low) / 1000.0;
    Some(amo_percent / (2.0 * mo_seconds * mxdmn_seconds))
}

/// The value reported in the app and stored in `minute_metric.baevsky_sqrt` (PLAN.md 8.3).
pub fn sqrt_stress_index(rr_ms: &[f64]) -> Option<f64> {
    stress_index(rr_ms).map(f64::sqrt)
}
