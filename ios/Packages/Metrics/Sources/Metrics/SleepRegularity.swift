import Foundation

// Sleep regularity for the sleep-coaching card. Pure value-in/value-out.
//
// Two measures:
//   1. Phillips Sleep Regularity Index (SRI), the epoch-by-epoch 24-h concordance. Ported from
//      OpenStrap os-analytics lib/src/onehz/sleep/sri.dart, function phillipsSri. The formula is
//      SRI = 200 * agreement / cases - 100. It is not the SD-of-midsleep shortcut.
//   2. A bed/wake-time consistency score in [0, 1]. This is our own design, not a port: OpenStrap has
//      no equivalent, and NOOP AnalyticsEngine.swift takes a caller-supplied regularity signal in
//      [0, 1] for the Rest composite (`sleepConsistency`, neutral 0.5 when nil). The score is shaped to
//      plug into that slot.
//
// Naps count as sleep for SRI, because SRI measures the sleep/wake state at each clock time. The
// consistency score uses main nights only.

public enum SleepRegularity {
    /// Epoch length for the SRI sleep/wake vector, in seconds (60 s, so 1440 epochs per local day).
    /// OpenStrap sri.dart documents 1440 one-minute epochs as its example layout. Phillips et al. 2017
    /// used 30-second epochs. Shorter epochs only change the resolution of the same comparison.
    public static let epochSec: Int64 = 60
    /// Epochs per local day at `epochSec`.
    public static let epochsPerDay: Int = 1440
    /// Minimum calendar days spanned before SRI is reported. OpenStrap sri.dart requires at least two
    /// full days (`n < 2 * epochsPerDay` returns absent).
    public static let minimumDays: Int = 2
    /// Main nights needed for the consistency score. A single night has no regularity signal, as
    /// NOOP's Rest composite notes.
    public static let minimumConsistencyNights: Int = 2
    /// Mean of the bedtime and wake-time circular spreads at which the consistency score reaches 0.
    /// This is a heuristic chosen for this app (2 h). It is not from a reference.
    public static let fullScaleSpreadSec: Double = 2 * 3600

    /// Phillips SRI in [-100, 100], or nil when the record is too short.
    ///
    /// The vector is built on a local clock grid (local midnight plus 60-s epochs). Each epoch is
    /// asleep if it falls inside any block's [start, end). Only the span from the first block's start
    /// to the last block's end is observed. Epochs outside that span are excluded from the count, so
    /// missing data never produces agreement. For each adjacent pair of local days, the comparison
    /// counts epochs where both days are observed and the sleep/wake state matches. SRI is
    /// `200 * agreement / cases - 100`, computed over all pairs together.
    ///
    /// Results:
    ///   - identical clock-aligned nights give 100
    ///   - exact anti-phase nights give -100, the formula's floor
    ///   - nil when the blocks span fewer than `minimumDays` local days, or when no pair has an
    ///     observed epoch on both days (for example a single night)
    ///
    /// Limitations: the input is only block start and end times, with no within-night wake periods.
    /// The whole in-bed interval therefore counts as sleep. DST transition days are treated as 24 h.
    public static func phillipsSRI(nights: [SleepNight], timeZone: TimeZone) -> Double? {
        let blocks = nights.filter(\.isUsable)
        guard let firstStart = blocks.map(\.startSec).min(),
              let lastEnd = blocks.map(\.endSec).max()
        else { return nil }

        let firstDay = LocalTime.localDay(containing: firstStart * 1000, in: timeZone)
        let lastDay = LocalTime.localDay(containing: lastEnd * 1000, in: timeZone)
        var days = [firstDay]
        while days[days.count - 1] != lastDay {
            days.append(LocalTime.adding(days: 1, to: days[days.count - 1]))
        }
        guard days.count >= minimumDays else { return nil }

        var asleep: [[Bool]] = []
        var observed: [[Bool]] = []
        for day in days {
            // Local midnight in Unix seconds.
            let dayStart = LocalTime.localTime(day, hour: 0, in: timeZone) / 1000
            var sleepRow = [Bool](repeating: false, count: epochsPerDay)
            for block in blocks {
                mark(&sleepRow, from: block.startSec - dayStart, to: block.endSec - dayStart)
            }
            var observedRow = [Bool](repeating: false, count: epochsPerDay)
            mark(&observedRow, from: firstStart - dayStart, to: lastEnd - dayStart)
            asleep.append(sleepRow)
            observed.append(observedRow)
        }

        var agreement = 0
        var cases = 0
        for d in 1..<days.count {
            for e in 0..<epochsPerDay where observed[d - 1][e] && observed[d][e] {
                cases += 1
                if asleep[d - 1][e] == asleep[d][e] { agreement += 1 }
            }
        }
        guard cases > 0 else { return nil }
        return 200.0 * Double(agreement) / Double(cases) - 100.0
    }

    /// Bed and wake consistency in [0, 1], where 1 is perfectly regular. Nil with fewer than
    /// `minimumConsistencyNights` main nights.
    ///
    /// For each wake day, bedtime is the earliest main-block start and wake time is the latest
    /// main-block end. Naps are excluded. Each set of local times of day is summarized by its
    /// circular standard deviation, so 23:30 and 00:30 count as one hour apart.
    /// The score is `1 - mean(bedSpread, wakeSpread) / fullScaleSpreadSec`, clamped to [0, 1].
    public static func consistencyScore(nights: [SleepNight], timeZone: TimeZone) -> Double? {
        let mains = SleepDayGroups.group(nights, in: timeZone).filter { $0.mainSec > 0 }
        guard mains.count >= minimumConsistencyNights else { return nil }

        let bedSec = mains.compactMap(\.mainStartSec).map { localSecondOfDay($0, in: timeZone) }
        let wakeSec = mains.compactMap(\.mainEndSec).map { localSecondOfDay($0, in: timeZone) }
        let spread = (circularSpreadSec(bedSec) + circularSpreadSec(wakeSec)) / 2
        return min(max(1 - spread / fullScaleSpreadSec, 0), 1)
    }

    // MARK: - Helpers

    /// Marks epochs whose start `dayStart + i * epochSec` falls in `[lo, hi)`, relative to the day
    /// start. Epoch i is included when `i * epochSec >= lo` and `i * epochSec < hi`.
    private static func mark(_ row: inout [Bool], from lo: Int64, to hi: Int64) {
        let first = max(0, ceilDiv(lo, epochSec))
        let end = min(Int64(epochsPerDay), ceilDiv(hi, epochSec))
        guard first < end else { return }
        for i in Int(first)..<Int(end) { row[i] = true }
    }

    /// Ceiling of `a / b` for `b > 0`, correct for negative `a`.
    private static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? (a + b - 1) / b : -((-a) / b)
    }

    /// Local second of day (0 to 86399) at a Unix timestamp.
    private static func localSecondOfDay(_ sec: Int64, in timeZone: TimeZone) -> Double {
        let offset = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(sec))))
        let day: Int64 = 86_400
        return Double(((sec + offset) % day + day) % day)
    }

    /// Circular standard deviation of local times of day, in seconds.
    ///
    /// Each time maps to an angle on a 24-h circle. With mean resultant length R, the circular SD is
    /// `sqrt(-2 ln R)` radians, converted to seconds. Returns infinity when R is zero, which means the
    /// times are maximally spread.
    private static func circularSpreadSec(_ secOfDay: [Double]) -> Double {
        guard !secOfDay.isEmpty else { return 0 }
        let day = 86_400.0
        var cosSum = 0.0
        var sinSum = 0.0
        for t in secOfDay {
            let angle = 2 * Double.pi * t / day
            cosSum += cos(angle)
            sinSum += sin(angle)
        }
        let n = Double(secOfDay.count)
        let r = min(hypot(cosSum, sinSum) / n, 1)
        guard r > 0 else { return .infinity }
        return sqrt(-2 * log(r)) * day / (2 * Double.pi)
    }
}
