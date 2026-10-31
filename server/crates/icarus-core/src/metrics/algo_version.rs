/// Algorithm version per metric family (PLAN.md 8.5). Stored with every derived row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlgoVersion {
    pub hr: i64,
    pub hrv: i64,
    pub stress: i64,
    pub kcal: i64,
}

impl AlgoVersion {
    /// Stress 3 is the Swift "Part A rules": the R-R fallback to the HR-only path and 12-window R-R days. The Rust
    /// core has no medication data, so the Swift medication-aware baselines (Part B) are not mirrored here.
    pub const CURRENT: AlgoVersion = AlgoVersion {
        hr: 1,
        hrv: 1,
        stress: 3,
        kcal: 1,
    };
}
