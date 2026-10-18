/// One 5-minute window (PLAN.md 8.2 step 3, 8.3). HRV fields are nil unless `valid`.
public struct FiveMinuteWindow: Sendable, Equatable {
    /// Window start, epoch ms UTC, aligned to 5 minutes.
    public let startMs: Int64
    /// Mean bpm of samples in the window, excluding contact `.notDetected`. Nil when there are none.
    public let hrMean: Double?
    public let rrCount: Int
    /// Sum of accepted R-R intervals in ms.
    public let rrSumMs: Double
    /// True when the accepted R-R sum is at least 60% of 300 s.
    public let valid: Bool
    public let rmssd: Double?
    public let sdnn: Double?
    public let lnRmssd: Double?
    public let baevskySqrt: Double?

    public init(
        startMs: Int64,
        hrMean: Double?,
        rrCount: Int,
        rrSumMs: Double,
        valid: Bool,
        rmssd: Double?,
        sdnn: Double?,
        lnRmssd: Double?,
        baevskySqrt: Double?
    ) {
        self.startMs = startMs
        self.hrMean = hrMean
        self.rrCount = rrCount
        self.rrSumMs = rrSumMs
        self.valid = valid
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.lnRmssd = lnRmssd
        self.baevskySqrt = baevskySqrt
    }
}

public enum FiveMinuteWindows {
    /// 0.6 * 300 s (PLAN.md 8.2 step 3).
    public static let minValidRRSumMs = 180_000.0

    /// Builds every window whose start lies in `range` (half-open). Starts are aligned to 5 minutes.
    ///
    /// An R-R interval belongs to the window containing its `tsMs`.
    /// `rr` must be the accepted intervals in arrival order.
    public static func build(samples: [HeartRateSample], rr: [RRSample], range: Range<Int64>) -> [FiveMinuteWindow] {
        let size = LocalTime.msPerWindow
        var hrByStart: [Int64: (sum: Double, n: Int)] = [:]
        for sample in samples where sample.contact != .notDetected {
            let start = LocalTime.roundDown(sample.tsMs, to: size)
            var acc = hrByStart[start, default: (sum: 0, n: 0)]
            acc.sum += Double(sample.bpm)
            acc.n += 1
            hrByStart[start] = acc
        }
        var rrByStart: [Int64: [Double]] = [:]
        for interval in rr {
            rrByStart[LocalTime.roundDown(interval.tsMs, to: size), default: []].append(interval.rrMs)
        }

        let starts = LocalTime.starts(
            from: LocalTime.roundUp(range.lowerBound, to: size),
            to: range.upperBound,
            step: size
        )
        return starts.map { start in
            let values = rrByStart[start] ?? []
            let sum = values.reduce(0, +)
            let valid = sum >= minValidRRSumMs
            return FiveMinuteWindow(
                startMs: start,
                hrMean: hrByStart[start].map { $0.sum / Double($0.n) },
                rrCount: values.count,
                rrSumMs: sum,
                valid: valid,
                rmssd: valid ? HRV.rmssd(values) : nil,
                sdnn: valid ? HRV.sdnn(values) : nil,
                lnRmssd: valid ? HRV.lnRMSSD(values) : nil,
                baevskySqrt: valid ? Baevsky.sqrtStressIndex(rrMs: values) : nil
            )
        }
    }
}
