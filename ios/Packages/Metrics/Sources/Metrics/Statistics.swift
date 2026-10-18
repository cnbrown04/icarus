/// Order statistics for the baselines (PLAN.md 8.3) and the RR median filter (PLAN.md 8.2).
enum Statistics {
    /// Median. Mean of the two middle values for an even count. Nil when empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Unscaled median absolute deviation. Nil when empty. Scale by 1.4826 for a sigma estimate.
    static func mad(_ values: [Double]) -> Double? {
        guard let center = median(values) else { return nil }
        return median(values.map { abs($0 - center) })
    }
}
