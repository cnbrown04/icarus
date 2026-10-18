//! In-memory sliding-window limiter, keyed by client IP. One process, so no shared store is needed.

use std::{
    collections::{HashMap, VecDeque},
    hash::Hash,
    net::IpAddr,
    sync::Mutex,
    time::{Duration, Instant},
};

const MAX_TRACKED_IPS: usize = 4096;
const MAX_TRACKED_KEYS: usize = 10_000;

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

/// Token buckets keyed by webhook endpoint (PLAN.md §12.4) or by client IP (PLAN.md §18). The
/// capacity is the per-minute budget, and tokens refill continuously at that rate, so a burst up
/// to the budget is allowed.
#[derive(Debug)]
pub struct TokenBuckets<K> {
    buckets: Mutex<HashMap<K, Bucket>>,
}

impl<K> Default for TokenBuckets<K> {
    fn default() -> Self {
        Self {
            buckets: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: f64,
    updated: Instant,
}

impl<K: Eq + Hash> TokenBuckets<K> {
    /// Takes one token for `key`. Returns `false` when the bucket is empty.
    pub fn take(&self, key: K, per_minute: u32) -> bool {
        self.take_at(key, per_minute, Instant::now())
    }

    fn take_at(&self, key: K, per_minute: u32, now: Instant) -> bool {
        let capacity = f64::from(per_minute.max(1));
        let rate_per_sec = capacity / 60.0;
        let mut map = self
            .buckets
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if map.len() > MAX_TRACKED_KEYS {
            // Full buckets carry no information, so dropping them is safe.
            map.retain(|_, b| b.tokens < capacity);
        }
        let bucket = map.entry(key).or_insert(Bucket {
            tokens: capacity,
            updated: now,
        });
        let elapsed = now.saturating_duration_since(bucket.updated).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * rate_per_sec).min(capacity);
        bucket.updated = now;
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[test]
    fn token_bucket_allows_the_budget_then_refills() {
        let buckets: TokenBuckets<uuid::Uuid> = TokenBuckets::default();
        let key = uuid::Uuid::now_v7();
        let t0 = Instant::now();
        for i in 0..10 {
            assert!(buckets.take_at(key, 10, t0), "token {i}");
        }
        assert!(!buckets.take_at(key, 10, t0), "budget spent");
        // 10 per minute is one token every 6 s.
        assert!(!buckets.take_at(key, 10, t0 + Duration::from_secs(5)));
        assert!(buckets.take_at(key, 10, t0 + Duration::from_secs(7)));
        assert!(
            buckets.take_at(uuid::Uuid::now_v7(), 1, t0),
            "other endpoints have their own budget"
        );
    }

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
