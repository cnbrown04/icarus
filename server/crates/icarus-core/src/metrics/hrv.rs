//! Time-domain HRV on a window of R-R intervals in ms (PLAN.md 8.3).
//! Every function expects intervals that have already passed `rr_cleaner`.

/// sqrt( (1 / (N - 1)) * sum((rr[i+1] - rr[i])^2) ). `None` for fewer than 2 values.
pub fn rmssd(rr: &[f64]) -> Option<f64> {
    if rr.len() < 2 {
        return None;
    }
    let sum_squares = rr.windows(2).fold(0.0, |acc, pair| {
        let difference = pair[1] - pair[0];
        acc + difference * difference
    });
    Some((sum_squares / (rr.len() - 1) as f64).sqrt())
}

/// sqrt( (1 / (N - 1)) * sum((rr[i] - mean)^2) ). `None` for fewer than 2 values.
pub fn sdnn(rr: &[f64]) -> Option<f64> {
    if rr.len() < 2 {
        return None;
    }
    let mean = rr.iter().fold(0.0, |acc, v| acc + v) / rr.len() as f64;
    let sum_squares = rr.iter().fold(0.0, |acc, v| acc + (v - mean) * (v - mean));
    Some((sum_squares / (rr.len() - 1) as f64).sqrt())
}

/// Natural log of RMSSD. `None` when RMSSD is `None` or zero, where the log is undefined.
pub fn ln_rmssd(rr: &[f64]) -> Option<f64> {
    rmssd(rr).filter(|&value| value > 0.0).map(f64::ln)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_and_single_interval_input_is_null() {
        assert_eq!(rmssd(&[]), None);
        assert_eq!(sdnn(&[]), None);
        assert_eq!(ln_rmssd(&[]), None);
        assert_eq!(rmssd(&[800.0]), None);
    }

    #[test]
    fn equal_intervals_give_zero_rmssd_and_no_log() {
        assert_eq!(rmssd(&[800.0, 800.0, 800.0]), Some(0.0));
        assert_eq!(ln_rmssd(&[800.0, 800.0, 800.0]), None);
    }
}
