import Foundation

// SkinTemperature.swift: the night's skin temperature from the band's frame-76 channel, in raw counts.
//
// Port of OpenStrap `analytics` `wellness/temp_circadian.dart` `nightlySkinTemp`. The plain mean of a night cannot
// tell a fever from a band that was just put on: a cold band reads low until it reaches skin temperature, and a
// band off the wrist reads low too. A sample is SETTLED when it is no more than `settleBand` below the night's own
// median. One-sided on purpose: warm-up and off-body read low, while a fever reads high and must pass through.
//
// The band width is this band's own, measured, not OpenStrap's gen4 number: after 20 minutes off the wrist, frame 76
// took about 8 minutes to climb within 20 counts of its worn level (Band Tests, 2026-11-01), and with 20 counts every
// stored night keeps at least 80 % of its samples. No conversion to degrees is verified, so the value is only ever
// compared with the user's own nights.

public enum SkinTemperature {
    /// How far below the night's median a sample may sit and still count as settled, in counts.
    public static let settleBand = 20.0
    /// Fewest settled samples, as a share of the night's, for the night to have a value (OpenStrap 0.80).
    public static let minSettledFraction = 0.8
    /// Fewest samples a night needs (OpenStrap: 60).
    public static let minSamples = 60

    /// The settled mean of a night's frame-76 samples (on-wrist, in counts), or nil when there are too few or too
    /// much of the night was below skin temperature.
    public static func nightly(_ samples: [Double]) -> Double? {
        let valid = samples.filter { $0 > 0 }
        guard valid.count >= minSamples, let median = Statistics.median(valid) else { return nil }
        let settled = valid.filter { $0 >= median - settleBand }
        guard Double(settled.count) / Double(valid.count) >= minSettledFraction else { return nil }
        return settled.reduce(0, +) / Double(settled.count)
    }
}
