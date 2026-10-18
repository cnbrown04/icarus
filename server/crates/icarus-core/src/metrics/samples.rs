/// Sensor contact as stored in `hr_sample.contact` (PLAN.md 10.2). Storage NULL maps to `None`.
/// BandProtocol `notSupported` also maps to `None`, because the store cannot tell it apart from unknown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensorContact {
    Detected,
    NotDetected,
}

/// One heart-rate reading at 1 Hz (PLAN.md 8.1). `ts_ms` is epoch ms UTC.
/// `contact` of `None` means unknown. Only `NotDetected` is excluded from aggregation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeartRateSample {
    pub ts_ms: i64,
    pub bpm: i64,
    pub contact: Option<SensorContact>,
}

/// One accepted R-R interval (PLAN.md 8.2). `ts_ms` is the receive time of the carrying notification.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RRSample {
    pub ts_ms: i64,
    pub rr_ms: f64,
}
