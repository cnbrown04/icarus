/// Heart-rate aggregate for one UTC minute (PLAN.md 8.1).
public struct MinuteAggregate: Sendable, Equatable {
    /// Minute start, epoch ms UTC.
    public let minuteMs: Int64
    public let hrAvg: Double
    public let hrMin: Int
    public let hrMax: Int
    public let hrN: Int

    public init(minuteMs: Int64, hrAvg: Double, hrMin: Int, hrMax: Int, hrN: Int) {
        self.minuteMs = minuteMs
        self.hrAvg = hrAvg
        self.hrMin = hrMin
        self.hrMax = hrMax
        self.hrN = hrN
    }

    /// samples / 60 (PLAN.md 8.1).
    public var coverage: Double { Double(hrN) / 60 }
}

public enum MinuteAggregation {
    /// Groups samples by UTC minute. Samples with contact `.notDetected` are dropped.
    /// Output is sorted by minute. Minutes with no kept sample are omitted.
    ///
    /// Duplicate timestamps are counted as given. The caller removes duplicates per band.
    public static func aggregate(_ samples: [HeartRateSample]) -> [MinuteAggregate] {
        var accumulators: [Int64: Accumulator] = [:]
        for sample in samples where sample.contact != .notDetected {
            let minute = LocalTime.roundDown(sample.tsMs, to: LocalTime.msPerMinute)
            accumulators[minute, default: Accumulator()].add(sample.bpm)
        }
        return accumulators.keys.sorted().map { minute in
            let acc = accumulators[minute]!
            return MinuteAggregate(
                minuteMs: minute,
                hrAvg: Double(acc.sum) / Double(acc.n),
                hrMin: acc.min,
                hrMax: acc.max,
                hrN: acc.n
            )
        }
    }

    private struct Accumulator {
        var sum = 0
        var min = Int.max
        var max = Int.min
        var n = 0

        mutating func add(_ bpm: Int) {
            sum += bpm
            min = Swift.min(min, bpm)
            max = Swift.max(max, bpm)
            n += 1
        }
    }
}
