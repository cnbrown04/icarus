/// R-R cleaning, PLAN.md 8.2 steps 1-2.
public enum RRCleaner {
    /// Step 1: physiological range in milliseconds.
    public static let validRangeMs: ClosedRange<Double> = 300...2000
    /// Step 2: number of previously accepted intervals used for the local median.
    public static let medianWindow = 11
    /// Step 2: reject when |rr - median| > maxDeviation * median.
    public static let maxDeviation = 0.20

    /// Returns one flag per input interval, true when the interval is accepted.
    ///
    /// The first interval is judged on the range filter alone, because there is no history yet.
    /// Rejected intervals never enter the median window.
    public static func acceptedFlags(_ rrMs: [Double]) -> [Bool] {
        var recent: [Double] = []
        var flags: [Bool] = []
        flags.reserveCapacity(rrMs.count)

        for rr in rrMs {
            var accepted = validRangeMs.contains(rr)
            if accepted, let reference = Statistics.median(recent) {
                accepted = abs(rr - reference) <= maxDeviation * reference
            }
            flags.append(accepted)
            if accepted {
                recent.append(rr)
                if recent.count > medianWindow {
                    recent.removeFirst()
                }
            }
        }
        return flags
    }

    /// The intervals that pass `acceptedFlags`, in the same order.
    public static func accepted(_ intervals: [RRSample]) -> [RRSample] {
        let flags = acceptedFlags(intervals.map(\.rrMs))
        return zip(intervals, flags).compactMap { $1 ? $0 : nil }
    }
}
