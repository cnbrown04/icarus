/// Algorithm version per metric family (PLAN.md 8.5). Stored with every derived row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlgoVersion {
    pub hr: i64,
    pub hrv: i64,
    pub stress: i64,
    pub kcal: i64,
}

impl AlgoVersion {
    pub const CURRENT: AlgoVersion = AlgoVersion {
        hr: 1,
        hrv: 1,
        stress: 1,
        kcal: 1,
    };
}
