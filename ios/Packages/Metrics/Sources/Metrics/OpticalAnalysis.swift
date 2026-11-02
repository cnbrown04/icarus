import Foundation

// OpticalAnalysis.swift: what a stretch of one optical channel shows. Pulse oximetry reads two light colours, red
// and infrared, each carrying a steady level (DC, mostly tissue) and a small pulse riding on it (AC, arterial
// blood). The ratio of ratios R = (AC_red/DC_red) / (AC_ir/DC_ir) rises as oxygen saturation falls (TI SLAA655).
// Turning R into a percentage needs a calibration against a reference pulse oximeter; this file never does that.

public enum OpticalAnalysis {
    /// Pulse search band: 36–200 beats a minute.
    static let pulseLoHz = 0.6
    static let pulseHiHz = 3.33
    /// Fewest seconds of samples a summary needs.
    static let minSeconds = 4.0

    /// One channel over a stretch of time.
    public struct ChannelSummary: Sendable, Equatable, Codable {
        /// Mean level, raw counts.
        public let dc: Double
        /// The pulse's size against the level: the standard deviation after removing the trend, over `dc`.
        public let acOverDC: Double
        /// The strongest rhythm in 36–200 a minute, per minute: a channel that sees the pulse puts it near the heart
        /// rate. Nil when there is no clear peak.
        public let pulsePerMinute: Double?
    }

    /// Summarises evenly spaced `samples` taken `sampleRate` times a second, or nil when too short or flat.
    public static func summarize(_ samples: [Double], sampleRate: Double) -> ChannelSummary? {
        guard sampleRate > 0, Double(samples.count) / sampleRate >= minSeconds else { return nil }
        let times = samples.indices.map { Double($0) / sampleRate }
        let n = Double(samples.count)
        let meanT = times.reduce(0, +) / n
        let dc = samples.reduce(0, +) / n
        guard dc != 0 else { return nil }
        var num = 0.0, den = 0.0
        for (t, v) in zip(times, samples) {
            num += (t - meanT) * (v - dc)
            den += (t - meanT) * (t - meanT)
        }
        let slope = den == 0 ? 0 : num / den
        let detrended = zip(times, samples).map { t, v in v - (dc + slope * (t - meanT)) }
        let spread = (detrended.reduce(0) { $0 + $1 * $1 } / max(n - 1, 1)).squareRoot()
        guard spread > 0 else { return nil }
        let nyquist = sampleRate / 2
        var pulse: Double?
        if nyquist > pulseLoHz {
            let grid = RespiratoryRate.frequencyGrid(lo: pulseLoHz, hi: min(pulseHiHz, nyquist * 0.98), count: 400)
            if let power = RespiratoryRate.lombScargle(t: times, y: detrended, freqsHz: grid),
               let best = power.indices.max(by: { power[$0] < power[$1] }), best > 0, best < grid.count - 1 {
                pulse = grid[best] * 60
            }
        }
        return ChannelSummary(dc: dc, acOverDC: spread / abs(dc), pulsePerMinute: pulse)
    }

    /// The ratio of ratios from a red and an infrared channel over the same stretch. Nil when either has no pulse.
    public static func ratioOfRatios(red: ChannelSummary, infrared: ChannelSummary) -> Double? {
        guard infrared.acOverDC > 0 else { return nil }
        return red.acOverDC / infrared.acOverDC
    }
}
