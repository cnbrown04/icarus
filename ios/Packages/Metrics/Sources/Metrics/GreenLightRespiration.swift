import Foundation

// GreenLightRespiration.swift: respiratory rate from the band's 1 Hz green-light (PPG) level.
//
// Breathing modulates how much light the wrist reflects (respiratory-induced intensity variation, RIIV). Port of
// OpenStrap `analytics` `respiration/resp_rate.dart` `riivRespRate`: linear detrend, then the Lomb-Scargle peak
// in 0.1-0.5 Hz (6-30 breaths/min). OpenStrap rates it RELATIVE/MED: the green level is a once-a-second
// intensity, not the pulse waveform, so two gates of this port's own come first.
//
// - Pulse alias. At one sample a second the pulse (about 1-1.5 Hz) folds into 0-0.5 Hz, at |f - round(f)|. A
//   peak on that alias is the heartbeat, not breathing, so it is withheld.
// - Stillness. Arm movement changes the light far more than breathing does, so a window whose gravity vector
//   moves is withheld.
//
// Not yet a source of any shown value: it is validated against the R-R estimate on the user's own nights first
// (plan: Phase 4). Band Tests reports it beside the R-R estimate.

public enum GreenLightRespiration {
    /// Breathing band searched, Hz: 6-30 breaths/min. The upper edge is the 1 Hz Nyquist limit.
    public static let loHz = 0.1
    public static let hiHz = 0.5
    /// Fewest samples a window needs (OpenStrap: 30 s).
    public static let minSamples = 30
    /// A peak this close to the pulse alias is withheld, Hz (1.2 breaths/min).
    public static let aliasGuardHz = 0.02
    /// A window whose gravity vector strays further than this from its mean, in g, moved.
    public static let stillnessToleranceG = 0.05

    /// Why a window has no estimate, for Band Tests to report.
    public enum Withheld: String, Sendable, Equatable {
        case tooFewSamples
        case cadenceTooSlow
        case moving
        case noPeak
        case pulseAlias
    }

    /// Breaths per minute from one window of green-light samples, or why there is none.
    ///
    /// `green` and `timesSec` are the window's samples and their times; `meanHeartRate` (bpm) enables the alias
    /// guard; `gravity` (one vector per sample, in g) enables the stillness gate.
    public static func estimate(
        green: [Double],
        timesSec: [Double],
        meanHeartRate: Double?,
        gravity: [(x: Double, y: Double, z: Double)]? = nil
    ) -> Result<Double, WithheldError> {
        let n = green.count
        guard n >= minSamples, timesSec.count == n else { return .failure(.init(.tooFewSamples)) }
        // Nyquist: anything slower than a sample a second cannot represent the band; every breath would alias.
        let gaps = zip(timesSec.dropFirst(), timesSec).map { $0 - $1 }.sorted()
        guard let cadence = gaps.isEmpty ? nil : gaps[gaps.count / 2], cadence > 0, 0.5 / cadence >= hiHz - 1e-9 else {
            return .failure(.init(.cadenceTooSlow))
        }
        if let gravity, !gravity.isEmpty, moved(gravity) {
            return .failure(.init(.moving))
        }
        let detrended = detrend(green, timesSec)
        let grid = RespiratoryRate.frequencyGrid(lo: loHz, hi: hiHz, count: 500)
        guard let power = RespiratoryRate.lombScargle(t: timesSec, y: detrended, freqsHz: grid),
              let best = power.indices.max(by: { power[$0] < power[$1] }),
              best > 0, best < grid.count - 1
        else { return .failure(.init(.noPeak)) }
        let peak = grid[best]
        if let meanHeartRate, meanHeartRate > 0 {
            let pulse = meanHeartRate / 60
            let alias = abs(pulse - pulse.rounded())
            if abs(peak - alias) < aliasGuardHz { return .failure(.init(.pulseAlias)) }
        }
        return .success(peak * 60)
    }

    /// `Withheld` as an `Error`, so `estimate` reads as a `Result`.
    public struct WithheldError: Error, Equatable, Sendable {
        public let reason: Withheld
        init(_ reason: Withheld) { self.reason = reason }
    }

    /// True when any gravity vector strays more than `stillnessToleranceG` from the window's mean vector.
    static func moved(_ gravity: [(x: Double, y: Double, z: Double)]) -> Bool {
        let count = Double(gravity.count)
        let mx = gravity.reduce(0) { $0 + $1.x } / count
        let my = gravity.reduce(0) { $0 + $1.y } / count
        let mz = gravity.reduce(0) { $0 + $1.z } / count
        return gravity.contains { g in
            let dx = g.x - mx, dy = g.y - my, dz = g.z - mz
            return (dx * dx + dy * dy + dz * dz).squareRoot() > stillnessToleranceG
        }
    }

    /// `values` minus their least-squares line over `times`.
    static func detrend(_ values: [Double], _ times: [Double]) -> [Double] {
        let n = Double(values.count)
        let meanT = times.reduce(0, +) / n
        let meanV = values.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (t, v) in zip(times, values) {
            num += (t - meanT) * (v - meanV)
            den += (t - meanT) * (t - meanT)
        }
        let slope = den == 0 ? 0 : num / den
        return zip(times, values).map { t, v in v - (meanV + slope * (t - meanT)) }
    }
}
