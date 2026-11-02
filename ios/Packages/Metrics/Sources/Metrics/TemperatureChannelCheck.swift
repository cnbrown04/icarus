import Foundation

// TemperatureChannelCheck.swift: does a raw record channel behave like skin temperature?
//
// The field long called "skin temperature" (frame 72) moves ~11 counts every second, which skin cannot do
// (OpenStrap `protocol` records.dart marks it "NOT a temperature"). Which channel is temperature, if any, is
// therefore tested, not assumed. A Band Tests run gives three labelled spans: a still baseline, the band off on a
// table, the band back on. A temperature channel changes slowly, moves steadily one way once the band leaves the
// wrist, and steadily back once it is worn again. Counts may rise or fall with warmth (a thermistor's ADC can run
// either way), so only the two directions being OPPOSITE is required, not which way each goes.
//
// The thresholds are this port's own choice, recorded with each verdict so a user sees what was judged.

public enum TemperatureChannelCheck {
    /// Median change between consecutive seconds must stay under this, in counts. Skin temperature drifts.
    public static let maxMedianStep = 1.0
    /// How steadily the band-off span must move one way (|Spearman ρ| against time).
    public static let minOffSteadiness = 0.8
    /// How steadily the band-on span must move back (|ρ|); lower, since re-warming flattens as it settles.
    public static let minOnSteadiness = 0.6
    /// Smallest change over a span that counts as a move, in counts, unless the baseline's own spread is larger.
    public static let minChange = 2.0
    /// Seconds averaged at each end of a span to measure its change.
    public static let edgeSeconds = 60.0

    /// One channel's numbers over a run, and whether it passed.
    public struct Verdict: Sendable, Equatable, Codable {
        /// Median |change| between consecutive one-second samples over the whole run, counts.
        public let medianStep: Double?
        /// Change over the band-off span (last minute minus first minute), counts.
        public let offChange: Double?
        /// Spearman ρ of the band-off span against time.
        public let offSteadiness: Double?
        public let onChange: Double?
        public let onSteadiness: Double?
        /// The smallest change that counted as a move for this channel.
        public let changeNeeded: Double
        public let passes: Bool
    }

    /// Judges one channel from its samples in the three spans (each `(timeSec, value)`, any order).
    public static func judge(
        baseline: [(t: Double, v: Double)],
        off: [(t: Double, v: Double)],
        on: [(t: Double, v: Double)]
    ) -> Verdict {
        let all = (baseline + off + on).sorted { $0.t < $1.t }
        let step = medianStep(all)
        let spread = standardDeviation(baseline.map(\.v)) ?? 0
        let needed = max(minChange, 3 * spread)
        let offChange = change(off)
        let onChange = change(on)
        let offRho = spearman(off)
        let onRho = spearman(on)
        var passes = false
        if let step, let offChange, let onChange, let offRho, let onRho {
            passes = step < maxMedianStep
                && abs(offRho) >= minOffSteadiness && abs(onRho) >= minOnSteadiness
                && abs(offChange) >= needed && abs(onChange) >= needed
                && (offChange > 0) != (onChange > 0)
        }
        return Verdict(medianStep: step, offChange: offChange, offSteadiness: offRho, onChange: onChange,
                       onSteadiness: onRho, changeNeeded: needed, passes: passes)
    }

    /// Median |Δ| between samples exactly one second apart. Nil without such a pair.
    static func medianStep(_ samples: [(t: Double, v: Double)]) -> Double? {
        let steps = zip(samples.dropFirst(), samples)
            .filter { abs($0.t - $1.t - 1) < 0.01 }
            .map { abs($0.v - $1.v) }
        return Statistics.median(steps)
    }

    /// Mean of the span's last `edgeSeconds` minus mean of its first `edgeSeconds`. Nil for a span shorter than
    /// two edges.
    static func change(_ span: [(t: Double, v: Double)]) -> Double? {
        let sorted = span.sorted { $0.t < $1.t }
        guard let first = sorted.first?.t, let last = sorted.last?.t, last - first >= 2 * edgeSeconds else { return nil }
        let head = sorted.filter { $0.t < first + edgeSeconds }.map(\.v)
        let tail = sorted.filter { $0.t > last - edgeSeconds }.map(\.v)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return tail.reduce(0, +) / Double(tail.count) - head.reduce(0, +) / Double(head.count)
    }

    /// Spearman rank correlation of value against time. Nil for fewer than 10 samples or a constant value.
    static func spearman(_ span: [(t: Double, v: Double)]) -> Double? {
        guard span.count >= 10 else { return nil }
        let timeRanks = ranks(span.map(\.t))
        let valueRanks = ranks(span.map(\.v))
        return pearson(timeRanks, valueRanks)
    }

    /// Average ranks (ties share their mean rank).
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] { j += 1 }
            let rank = Double(i + j) / 2
            for k in i...j { result[order[k]] = rank }
            i = j + 1
        }
        return result
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)).squareRoot()
    }
}
