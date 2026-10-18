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
}
