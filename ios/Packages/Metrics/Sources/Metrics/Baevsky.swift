import Foundation

/// Baevsky stress index (PLAN.md 8.3), as Kubios computes it.
///
/// TODO(PLAN.md 8.3): Kubios removes the very-low-frequency trend before computing SI. We do not
/// detrend yet, so values are not directly comparable with Kubios output.
public enum Baevsky {
    /// Histogram bin width in ms (PLAN.md 8.3).
    public static let binWidthMs = 50.0

    /// SI = AMo / (2 * Mo * MxDMn), with AMo in %, Mo in s and MxDMn in s.
    ///
    /// Bins start at multiples of 50 ms, so the mode is independent of where the data starts.
    /// Nil for fewer than 2 intervals or when all intervals are equal.
    public static func stressIndex(rrMs: [Double]) -> Double? {
        guard rrMs.count >= 2,
              let low = rrMs.min(),
              let high = rrMs.max(),
              high > low,
              let medianMs = Statistics.median(rrMs)
        else {
            return nil
        }
        var counts: [Int64: Int] = [:]
        for rr in rrMs {
            counts[Int64((rr / binWidthMs).rounded(.down)), default: 0] += 1
        }
        let modeCount = counts.values.max() ?? 0
        let amoPercent = Double(modeCount) / Double(rrMs.count) * 100
        let moSeconds = medianMs / 1000
        let mxdmnSeconds = (high - low) / 1000
        return amoPercent / (2 * moSeconds * mxdmnSeconds)
    }

    /// The value reported in the app and stored in `minute_metric.baevsky_sqrt` (PLAN.md 8.3).
    public static func sqrtStressIndex(rrMs: [Double]) -> Double? {
        stressIndex(rrMs: rrMs).map { $0.squareRoot() }
    }
}
