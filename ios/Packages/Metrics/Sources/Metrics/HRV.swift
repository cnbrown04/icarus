import Foundation

/// Time-domain HRV on a window of R-R intervals in milliseconds (PLAN.md 8.3).
/// All functions expect intervals that have already passed `RRCleaner`.
public enum HRV {
    /// sqrt( (1 / (N - 1)) * sum((rr[i+1] - rr[i])^2) ). Nil for fewer than 2 values.
    public static func rmssd(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSquares = 0.0
        for i in 1..<rr.count {
            let difference = rr[i] - rr[i - 1]
            sumSquares += difference * difference
        }
        return (sumSquares / Double(rr.count - 1)).squareRoot()
    }

    /// sqrt( (1 / (N - 1)) * sum((rr[i] - mean)^2) ). Nil for fewer than 2 values.
    public static func sdnn(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        let mean = rr.reduce(0, +) / Double(rr.count)
        let sumSquares = rr.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / Double(rr.count - 1)).squareRoot()
    }

    /// Natural log of RMSSD. Nil when RMSSD is nil or zero, where the log is undefined.
    public static func lnRMSSD(_ rr: [Double]) -> Double? {
        guard let value = rmssd(rr), value > 0 else { return nil }
        return log(value)
    }

    /// Session RMSSD as the mean of per-window RMSSD over 5-minute windows (OpenStrap
    /// `sleepSessionWindowedRmssd`, NOOP `sessionAvgHRV`). Nil when no window qualifies.
    ///
    /// Windows tumble from `startUnix` in `windowSeconds` steps; beats before `startUnix` are ignored.
    /// Each window is cleaned on its own with `RRCleaner.acceptedFlags`, so a window's median history
    /// never reaches into its neighbour. A successive difference is taken only between two accepted
    /// intervals that are adjacent in the raw stream and whose records are at most
    /// `maxRecordGapSeconds` apart: a dropout or a rejected beat must not splice two beats together.
    /// A window with fewer than `minDifferences` differences is dropped rather than averaged in, so a
    /// sparse window cannot weigh as much as a full one.
    ///
    /// `beats` must be in time order, one entry per record, each with the intervals it carried.
    public static func windowedRMSSD(
        _ beats: [(unixSeconds: Int64, rrMs: [Double])],
        startUnix: Int64,
        windowSeconds: Int64 = 300,
        minDifferences: Int = 20,
        maxRecordGapSeconds: Int64 = 2
    ) -> Double? {
        var buckets: [Int64: [(unixSeconds: Int64, rrMs: Double)]] = [:]
        for beat in beats where beat.unixSeconds >= startUnix {
            let index = (beat.unixSeconds - startUnix) / windowSeconds
            for rr in beat.rrMs {
                buckets[index, default: []].append((beat.unixSeconds, rr))
            }
        }

        var windowValues: [Double] = []
        for index in buckets.keys.sorted() {
            let bucket = buckets[index]!
            let flags = RRCleaner.acceptedFlags(bucket.map(\.rrMs))
            var sumSquares = 0.0
            var differences = 0
            for i in bucket.indices.dropFirst() where flags[i] && flags[i - 1] {
                guard bucket[i].unixSeconds - bucket[i - 1].unixSeconds <= maxRecordGapSeconds else { continue }
                let difference = bucket[i].rrMs - bucket[i - 1].rrMs
                sumSquares += difference * difference
                differences += 1
            }
            guard differences >= minDifferences else { continue }
            windowValues.append((sumSquares / Double(differences)).squareRoot())
        }
        guard !windowValues.isEmpty else { return nil }
        return windowValues.reduce(0, +) / Double(windowValues.count)
    }
}
