//! Order statistics for the baselines (PLAN.md 8.3) and the R-R median filter (PLAN.md 8.2).

/// Median. Mean of the two middle values for an even count. `None` when empty.
pub(crate) fn median(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let mid = sorted.len() / 2;
    if sorted.len() % 2 == 1 {
        Some(sorted[mid])
    } else {
        Some((sorted[mid - 1] + sorted[mid]) / 2.0)
    }
}

/// Unscaled median absolute deviation. `None` when empty. Scale by 1.4826 for a sigma estimate.
pub(crate) fn mad(values: &[f64]) -> Option<f64> {
    let center = median(values)?;
    let deviations: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    median(&deviations)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_has_no_median_or_mad() {
        assert_eq!(median(&[]), None);
        assert_eq!(mad(&[]), None);
    }

    #[test]
    fn mad_is_zero_for_constant_input() {
        assert_eq!(median(&[60.0, 60.0, 60.0]), Some(60.0));
        assert_eq!(mad(&[60.0, 60.0, 60.0]), Some(0.0));
    }

    #[test]
    fn even_count_averages_the_middle_pair() {
        assert_eq!(median(&[4.0, 1.0, 3.0, 2.0]), Some(2.5));
    }
}
