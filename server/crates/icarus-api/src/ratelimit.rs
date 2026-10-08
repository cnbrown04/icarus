//! In-memory sliding-window limiter, keyed by client IP. One process, so no shared store is needed.

use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
    sync::Mutex,
    time::{Duration, Instant},
};

const MAX_TRACKED_IPS: usize = 4096;

#[derive(Debug)]
pub struct RateLimiter {
    limit: usize,
    window: Duration,
    hits: Mutex<HashMap<IpAddr, VecDeque<Instant>>>,
}

impl RateLimiter {
    pub fn new(limit: usize, window: Duration) -> Self {
        Self {
            limit,
            window,
            hits: Mutex::new(HashMap::new()),
        }
    }

    /// Records a hit and returns `true` if it is within the limit.
    pub fn allow(&self, key: IpAddr) -> bool {
        self.allow_at(key, Instant::now())
    }

    fn allow_at(&self, key: IpAddr, now: Instant) -> bool {
        let mut map = self
            .hits
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let cutoff = now.checked_sub(self.window);
        let hits = map.entry(key).or_default();
        while let (Some(&front), Some(cutoff)) = (hits.front(), cutoff) {
            if front > cutoff {
                break;
            }
            hits.pop_front();
        }
        if hits.len() >= self.limit {
            return false;
        }
        hits.push_back(now);

        if map.len() > MAX_TRACKED_IPS {
            map.retain(|_, hits| match (hits.back(), cutoff) {
                (Some(&last), Some(cutoff)) => last > cutoff,
                _ => false,
            });
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn allows_limit_hits_then_blocks_until_window_passes() {
        let limiter = RateLimiter::new(5, Duration::from_secs(60));
        let ip = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        let t0 = Instant::now();
        for i in 0..5 {
            assert!(limiter.allow_at(ip, t0 + Duration::from_secs(i)), "hit {i}");
        }
        assert!(!limiter.allow_at(ip, t0 + Duration::from_secs(10)));
        // The first hit leaves the window 60 s after it was made.
        assert!(limiter.allow_at(ip, t0 + Duration::from_secs(61)));
        // Other IPs have their own budget.
        assert!(limiter.allow_at(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2)), t0));
    }
}
