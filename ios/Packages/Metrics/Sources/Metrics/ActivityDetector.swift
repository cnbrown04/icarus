import Foundation

// ActivityDetector.swift: auto-detected bouts of activity from minute heart rate, and the per-activity summary.
//
// Our own heuristic, not a published method. It is tuned for a wrist band that reports one HR average per
// minute. Gravity movement is not used: minute rows carry no movement aggregate, and HR alone separates
// workouts from sitting in practice. The thresholds are judgements, and the constants below are the knobs.
//
// Rules, in order:
//   1. A minute is active when its HR average is at or above the zone-1 lower bound (50 % HRR, see
//      `HeartRateZones`). Minutes with no HR are not active.
//   2. A bout starts at the first minute of a run of at least `minRunMinutes` consecutive active minutes.
//   3. A bout continues through dips shorter than `endBelowMinutes` minutes below the threshold, and ends
//      after that many minutes below.
//   4. A bout is clipped at every sleep window, so no bout ever lies inside sleep.
//   5. Bouts separated by a gap of `mergeGapMinutes` or less are merged, unless sleep lies in the gap.
//   6. Bouts shorter than `minActivityMinutes` after clipping and merging are dropped.
//
// Heart rate alone cannot tell a brisk walk from a slow run. Auto-detected rows are kind `other` until the
// user retypes them.

/// Activity kinds stored in `activity.kind`. The raw values are the database strings.
public enum ActivityKind: String, CaseIterable, Sendable, Codable {
    case run
    case walk
    case cycle
    case strength
    case hiit
    case yoga
    case sport
    case other
}

/// The detector's output: an interval [startMs, endMs) of activity.
public struct ActivityBout: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64

    public init(startMs: Int64, endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMinutes: Double {
        Double(endMs - startMs) / Double(LocalTime.msPerMinute)
    }
}

public enum ActivityDetector {
    /// Version of this heuristic. Stored on each activity row, so a later change can re-detect stale rows.
    public static let algoVersion = 1

    /// Consecutive active minutes before a bout starts.
    public static let minRunMinutes = 3
    /// Minutes below the threshold that end a bout. Shorter dips do not split it.
    public static let endBelowMinutes = 5
    /// Gaps at or below this merge two bouts, when no sleep lies between them.
    public static let mergeGapMinutes = 5
    /// Shortest bout that is kept.
    public static let minActivityMinutes = 15

    /// Zone-1 lower bound as a fraction of HRR. Matches the `..<0.5` boundary in `HeartRateZone.of(hrrFraction:)`.
    public static let zone1LowerHRR = 0.5

    /// The activity threshold in bpm: the zone-1 lower bound, `restingHR + 0.5 x (maxHR - restingHR)`.
    /// Nil when the reserve is not positive.
    public static func thresholdBPM(restingHR: Double, maxHR: Double) -> Double? {
        let reserve = maxHR - restingHR
        guard reserve > 0 else { return nil }
        return restingHR + zone1LowerHRR * reserve
    }

    /// Bouts in `minutes` (sorted or not), outside every range in `sleep`. Ranges are half-open, in ms.
    public static func detect(
        _ minutes: [MinuteAggregate],
        thresholdBPM: Double,
        sleep: [Range<Int64>]
    ) -> [ActivityBout] {
        let minute = Int64(LocalTime.msPerMinute)
        let active = Set(minutes.filter { $0.hrAvg >= thresholdBPM }.map(\.minuteMs)).sorted()

        // Runs of consecutive active minutes: (first minute start, last minute start, length).
        var runs: [(first: Int64, last: Int64, length: Int)] = []
        for ms in active {
            if let last = runs.last, last.last + minute == ms {
                runs[runs.count - 1].last = ms
                runs[runs.count - 1].length += 1
            } else {
                runs.append((first: ms, last: ms, length: 1))
            }
        }

        // Candidates as [start, end) with end exclusive. Dips under `endBelowMinutes` keep a candidate open.
        var candidates: [Range<Int64>] = []
        var current: Range<Int64>?
        for run in runs {
            let runEnd = run.last + minute
            if let open = current {
                let belowMinutes = (run.first - open.upperBound) / minute
                if belowMinutes < Int64(endBelowMinutes) {
                    current = open.lowerBound..<runEnd
                    continue
                }
                candidates.append(open)
                current = nil
            }
            if run.length >= minRunMinutes {
                current = run.first..<runEnd
            }
        }
        if let open = current {
            candidates.append(open)
        }

        // Clip each candidate at every sleep window.
        var pieces: [Range<Int64>] = []
        for candidate in candidates {
            var remaining = [candidate]
            for window in sleep.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                remaining = remaining.flatMap { subtract(window, from: $0) }
            }
            pieces.append(contentsOf: remaining)
        }

        // Merge close pieces, never across sleep.
        var merged: [Range<Int64>] = []
        for piece in pieces.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last {
                let gap = piece.lowerBound - last.upperBound
                let sleepBetween = sleep.contains { $0.lowerBound < piece.lowerBound && $0.upperBound > last.upperBound }
                if gap <= Int64(mergeGapMinutes) * minute, !sleepBetween {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, piece.upperBound)
                    continue
                }
            }
            merged.append(piece)
        }

        return merged
            .filter { $0.upperBound - $0.lowerBound >= Int64(minActivityMinutes) * minute }
            .map { ActivityBout(startMs: $0.lowerBound, endMs: $0.upperBound) }
    }

    /// `range` with `window` removed. Zero, one or two pieces.
    private static func subtract(_ window: Range<Int64>, from range: Range<Int64>) -> [Range<Int64>] {
        guard window.lowerBound < range.upperBound, window.upperBound > range.lowerBound else { return [range] }
        var out: [Range<Int64>] = []
        if window.lowerBound > range.lowerBound {
            out.append(range.lowerBound..<window.lowerBound)
        }
        if window.upperBound < range.upperBound {
            out.append(window.upperBound..<range.upperBound)
        }
        return out
    }
}

/// What one activity span looks like in numbers. Built from minute aggregates, so it works the same for
/// detected bouts, manual recordings and a live recording in progress.
public struct ActivitySummary: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    /// Heart-rate average weighted by each minute's sample count. Nil without heart rate.
    public let avgHR: Double?
    /// Highest minute maximum in the span. Nil without heart rate.
    public let maxHR: Int?
    /// Credited minutes in six buckets, as `Strain.Score.zoneMinutes`: index 0 is below 50 % HRR, 1...5 are zones 1 to 5.
    public let zoneMinutes: [Double]
    /// Total kcal over the span, from `Calories.minuteEnergy` (resting rate included). Nil without a profile.
    /// Estimated.
    public let kcal: Double?
    /// Strain on WHOOP's 0-21 axis, from the same Banister method as day strain. Nil when `Strain` refuses it.
    public let strain: Double?

    public var durationMinutes: Double {
        Double(endMs - startMs) / Double(LocalTime.msPerMinute)
    }

    /// The strain method, the same one day strain uses (Store `Database.strainMethod`). Keep the two equal.
    public static let strainMethod: Strain.Method = .banister

    /// Summarises the minutes that overlap [startMs, endMs). A minute that is only partly inside the span counts
    /// for its inside fraction, in kcal and in strain. Strain is scored by `Strain.scoreActivity`.
    public static func make(
        startMs: Int64,
        endMs: Int64,
        minutes: [MinuteAggregate],
        restingHR: Double,
        maxHR: Double,
        profile: UserProfile?
    ) -> ActivitySummary {
        let minute = LocalTime.msPerMinute
        let inside = minutes
            .filter { $0.minuteMs < endMs && $0.minuteMs + minute > startMs }
            .sorted { $0.minuteMs < $1.minuteMs }

        let weightedHR = inside.reduce(0.0) { $0 + $1.hrAvg * Double($1.hrN) }
        let samples = inside.reduce(0) { $0 + $1.hrN }
        let avg = samples > 0 ? weightedHR / Double(samples) : nil
        let maxima = inside.map(\.hrMax)
        let peak = maxima.max()

        var kcal: Double?
        if let profile, !inside.isEmpty {
            kcal = inside.reduce(0.0) { total, row in
                let overlap = Double(min(endMs, row.minuteMs + minute) - max(startMs, row.minuteMs)) / Double(minute)
                let energy = Calories.minuteEnergy(heartRate: row.hrAvg, profile: profile, restingHR: restingHR, maxHR: maxHR)
                return total + energy.kcal * overlap
            }
        }

        let score = inside.isEmpty ? nil : Strain.scoreActivity(
            minutes: inside,
            restingHR: restingHR,
            maxHR: maxHR,
            method: Self.strainMethod,
            sex: profile?.sex ?? .male
        )

        return ActivitySummary(
            startMs: startMs,
            endMs: endMs,
            avgHR: avg,
            maxHR: peak,
            zoneMinutes: score?.zoneMinutes ?? [Double](repeating: 0, count: 6),
            kcal: kcal,
            strain: score.map { Strain.whoopStrain(fromEffort: $0.strain) }
        )
    }
}
