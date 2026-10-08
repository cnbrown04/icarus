import Metrics

extension AlgoVersion {
    /// The integer stored in `minute_metric.algo_version`. The v1 table has one column, so this is the
    /// maximum of the four family versions: any family bump changes the stored value. PLAN.md 8.5 keeps
    /// the per-family numbers in code.
    public var storedValue: Int {
        max(hr, hrv, stress, kcal)
    }
}
