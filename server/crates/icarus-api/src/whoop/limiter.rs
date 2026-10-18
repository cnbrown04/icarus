//! Client-side budget for calls to WHOOP (PLAN.md §5.2, §12.6). Calls over budget are refused here,
//! so they never leave the server.

use std::{
    collections::VecDeque,
    sync::{Mutex, PoisonError},
    time::{Duration, Instant},
};

const MINUTE: Duration = Duration::from_secs(60);
const DAY: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exhausted {
    Minute,
    Day,
}

/// Sliding windows over the times of recent calls. One process, so no shared store is needed.
#[derive(Debug)]
pub struct WhoopLimiter {
    per_minute: usize,
    per_day: usize,
    calls: Mutex<VecDeque<Instant>>,
}

impl WhoopLimiter {
    pub fn new(per_minute: usize, per_day: usize) -> Self {
        Self {
            per_minute,
            per_day,
            calls: Mutex::new(VecDeque::new()),
        }
    }

    /// Records one outgoing call, or reports which budget is spent.
    pub fn acquire(&self) -> Result<(), Exhausted> {
        self.acquire_at(Instant::now())
    }

    fn acquire_at(&self, now: Instant) -> Result<(), Exhausted> {
        let mut calls = self.calls.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(cutoff) = now.checked_sub(DAY) {
            while calls.front().is_some_and(|&t| t <= cutoff) {
                calls.pop_front();
            }
        }
        if calls.len() >= self.per_day {
            return Err(Exhausted::Day);
        }
        let minute_start = now.checked_sub(MINUTE);
        let in_minute = calls
            .iter()
            .rev()
            .take_while(|&&t| minute_start.is_none_or(|start| t > start))
            .count();
        if in_minute >= self.per_minute {
            return Err(Exhausted::Minute);
        }
        calls.push_back(now);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minute_budget_refuses_then_frees_after_a_minute() {
        let limiter = WhoopLimiter::new(100, 10_000);
        let t0 = Instant::now();
        for i in 0..100 {
            assert!(limiter.acquire_at(t0 + Duration::from_millis(i)).is_ok());
        }
        assert_eq!(
            limiter.acquire_at(t0 + Duration::from_secs(30)),
            Err(Exhausted::Minute)
        );
        assert!(limiter.acquire_at(t0 + Duration::from_secs(61)).is_ok());
    }

    #[test]
    fn daily_budget_refuses_until_a_day_has_passed() {
        let limiter = WhoopLimiter::new(100, 10_000);
        let t0 = Instant::now();
        // Spread over the day, so the minute budget never applies.
        for i in 0..10_000u64 {
            let at = t0 + Duration::from_secs(i * 8);
            assert!(limiter.acquire_at(at).is_ok(), "call {i}");
        }
        let end = t0 + Duration::from_secs(10_000 * 8);
        assert_eq!(limiter.acquire_at(end), Err(Exhausted::Day));
        assert!(
            limiter
                .acquire_at(t0 + DAY + Duration::from_secs(1))
                .is_ok()
        );
    }
}
