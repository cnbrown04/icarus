import Foundation

// Sleep need, sleep debt and sleep performance for the sleep-coaching card.
//
// Pure value-in/value-out. No Store, GRDB or BLE imports. Sources (read-only references):
//   - NOOP     StrandAnalytics/SleepDebt.swift: SleepDebt.ledger (carry factor, 10-minute floor,
//              14-night window) and SleepDebt.creditedSleepMin (main + nap credit).
//   - NOOP     StrandAnalytics/AnalyticsEngine.swift: enum Rest. defaultNeedHours = 8.0. The duration
//              term is hours asleep / need, clamped to 1.0.
//   - OpenStrap os-analytics lib/src/onehz/human/coaching.dart: sleepNeed (strain bonus up to 45 min,
//              6 h to 11 h clamp) and sleepPerformance (asleep / need, 0 to 100 clamp).
//
// Not used as sources: NOOP SleepReadout.swift contains only live-readout parsers, with no need or
// performance math. OpenStrap human/sleep_regularity.dart's sleepDebt is a habitual-percentile gap,
// which its own header says is not a sleep debt.

/// One sleep block, either a main night or a nap. Timestamps are unix seconds.
///
/// A block with `asleepSec <= 0` or `endSec <= startSec` is ignored. This matches NOOP, which skips
/// nights with no usable sleep total rather than zero-filling them (SleepDebt.ledger).
public struct SleepNight: Sendable, Equatable {
    public let startSec: Int64
    public let endSec: Int64
    /// Asleep time inside the block, in seconds.
    public let asleepSec: Double
    /// Naps add repayment credit to debt. They never replace the main-night figure used for
    /// performance (see SleepCoaching.summarize).
    public let isNap: Bool

    public init(startSec: Int64, endSec: Int64, asleepSec: Double, isNap: Bool = false) {
        self.startSec = startSec
        self.endSec = endSec
        self.asleepSec = asleepSec
        self.isNap = isNap
    }

    var isUsable: Bool { asleepSec > 0 && endSec > startSec }
}

/// Sleep need in seconds, adjusted by debt, strain and naps.
public enum SleepNeed {
    /// Population default need, 8 h. NOOP AnalyticsEngine.Rest.defaultNeedHours = 8.0. The reference
    /// has no learned need until 7 nights exist (AnalyticsEngine.Rest.minNeedNights). Callers that
    /// learn a personal baseline pass it in as `baselineNeedSec`.
    public static let defaultBaselineSec: Double = 8 * 3600
    /// Floor on the adjusted need. OpenStrap coaching.dart sleepNeed clamps to [6 h, 11 h].
    public static let minNeedSec: Double = 6 * 3600
    /// Ceiling on the adjusted need. See `minNeedSec`.
    public static let maxNeedSec: Double = 11 * 3600
    /// Strain on the 0 to 21 scale at which the strain bonus is full. OpenStrap sleepNeed divides by 21.
    public static let maxStrain: Double = 21
    /// Extra need at full strain, 45 min. OpenStrap coaching.dart sleepNeed.
    public static let maxStrainBonusSec: Double = 45 * 60

    /// Extra need from the day's strain: `clamp(strain, 0, 21) / 21 * 45 min`.
    ///
    /// Strain increases the need linearly (OpenStrap coaching.dart sleepNeed). A nil strain adds
    /// nothing, so an unknown day is not treated as a hard one.
    public static func strainBonusSec(dayStrain: Double?) -> Double {
        guard let dayStrain, dayStrain.isFinite else { return 0 }
        return min(max(dayStrain, 0), maxStrain) / maxStrain * maxStrainBonusSec
    }

    /// Sleep need for the coming night, in seconds.
    ///
    ///     need = clamp(baseline + sleepDebt + strainBonus - napCredit, 6 h, 11 h)
    ///
    /// Port of OpenStrap coaching.dart `sleepNeed`. The clamp is applied to the whole sum, so debt
    /// can never push the need above 11 h.
    ///
    /// - Parameters:
    ///   - sleepDebtSec: debt owed, as a positive number of seconds. Pass `-balanceSec` from
    ///     `SleepDebt.ledger`.
    ///   - napCreditSec: OpenStrap subtracts nap sleep from the need. `SleepCoaching.summarize`
    ///     passes 0 because naps are already credited through the debt ledger. Passing both would
    ///     count the same nap twice.
    public static func adjustedNeedSec(
        baselineNeedSec: Double = defaultBaselineSec,
        sleepDebtSec: Double = 0,
        dayStrain: Double?,
        napCreditSec: Double = 0
    ) -> Double {
        let sum = baselineNeedSec + max(sleepDebtSec, 0) + strainBonusSec(dayStrain: dayStrain) - napCreditSec
        return min(max(sum, minNeedSec), maxNeedSec)
    }
}

/// The ledger's sleep debt for a window of nights.
public struct SleepDebtLedger: Equatable, Sendable {
    /// Signed balance in seconds. Negative means debt, zero means on target. The sign follows NOOP's
    /// convention and the ledger never reports a surplus.
    public let balanceSec: Double
    /// Counted nights, oldest to newest. Nights with no main sleep are absent.
    public let nights: [SleepDebtNight]
    /// Need the ledger was computed against, in seconds.
    public let needSec: Double

    public init(balanceSec: Double, nights: [SleepDebtNight], needSec: Double) {
        self.balanceSec = balanceSec
        self.nights = nights
        self.needSec = needSec
    }

    /// Nights that contributed to the balance.
    public var nightCount: Int { nights.count }
}

/// One counted night in a `SleepDebtLedger`.
public struct SleepDebtNight: Equatable, Sendable {
    /// Local calendar day the night ended on (its wake day).
    public let day: LocalDay
    /// Main-night asleep plus nap credit, in seconds (NOOP `creditedSleepMin`).
    public let creditedSec: Double
    /// `creditedSec - needSec`. Positive is surplus and negative is deficit. Drives the per-night bars.
    public let deltaSec: Double

    public init(day: LocalDay, creditedSec: Double, deltaSec: Double) {
        self.day = day
        self.creditedSec = creditedSec
        self.deltaSec = deltaSec
    }
}

/// Recency-weighted sleep debt over the most recent nights.
///
/// Port of NOOP `SleepDebt.ledger`. For each counted night, in order:
///
///     calculated = 0.55 * max(0, need + previousDebt - credited)
///     debt       = calculated < 10 min ? 0 : calculated
///
/// The 0.55 factor means 55% of unmet need carries into the following night. Only the most recent
/// 14 counted nights are used, so debt cannot compound over months. The recurrence is a planning
/// estimate, not a physiological model.
public enum SleepDebt {
    /// Trailing nights in the ledger. NOOP SleepDebt.defaultWindowNights = 14.
    public static let defaultWindowNights: Int = 14
    /// Share of unmet need carried into the next night. NOOP SleepDebt.debtCarryFactor = 0.55.
    public static let debtCarryFactor: Double = 0.55
    /// Debts below this are cleared to zero (10 min, as NOOP minimumDebtMin).
    public static let minimumDebtSec: Double = 10 * 60

    /// Sleep debt over the trailing `window` counted nights.
    ///
    /// Blocks are grouped by the local day they end on. Within a day, main-night asleep time is
    /// summed across blocks, and nap asleep time is added as credit. A day with no main sleep is
    /// skipped and never zero-filled (NOOP `creditedSleepMin` returns nil in that case).
    ///
    /// Naps are credited only through the ledger. They do not change the main-night figure used for
    /// performance, following NOOP's rule that the main-night total stays canonical.
    ///
    /// - Parameters:
    ///   - needSec: the baseline need the nights are measured against. It does not include the
    ///     strain bonus, because the ledger recurrence uses the base need.
    ///   - window: counted nights to include. Clamped to at least 1.
    public static func ledger(
        nights: [SleepNight],
        needSec: Double = SleepNeed.defaultBaselineSec,
        window: Int = defaultWindowNights,
        timeZone: TimeZone
    ) -> SleepDebtLedger {
        let need = max(needSec, 0)
        let cap = max(window, 1)
        let counted = SleepDayGroups.group(nights, in: timeZone).filter { $0.mainSec > 0 }

        var entries: [SleepDebtNight] = []
        var debt = 0.0
        for day in counted.suffix(cap) {
            let credited = day.mainSec + day.napSec
            let calculated = debtCarryFactor * max(0, need + debt - credited)
            debt = calculated < minimumDebtSec ? 0 : calculated
            entries.append(SleepDebtNight(day: day.day, creditedSec: credited, deltaSec: credited - need))
        }
        return SleepDebtLedger(balanceSec: -debt, nights: entries, needSec: need)
    }
}

/// Sleep performance: asleep time as a share of need.
public enum SleepPerformance {
    /// Ceiling on the score. OpenStrap sleepPerformance clamps to 100, and NOOP's duration term clamps
    /// the ratio to 1.0.
    public static let maxPercent: Double = 100

    /// `asleep / need` as a percentage clamped to 0 to 100. Nil when need is not positive.
    ///
    /// Port of OpenStrap coaching.dart `sleepPerformance`. The score does not exceed 100 even when
    /// the user sleeps well beyond need.
    public static func percent(asleepSec: Double, needSec: Double) -> Double? {
        guard needSec > 0 else { return nil }
        return min(max(asleepSec / needSec * 100, 0), maxPercent)
    }
}

/// Sleep-coaching values for the most recent main night.
public struct SleepCoachingSummary: Equatable, Sendable {
    /// Need that applied to the most recent main night, in seconds. It is the baseline plus the debt
    /// carried into that night plus the strain bonus, clamped to 6 to 11 h.
    public let needSec: Double
    /// Baseline need passed in by the caller.
    public let baselineNeedSec: Double
    /// Debt carried into the most recent night, in seconds (>= 0), from the nights before it.
    public let carriedDebtSec: Double
    /// Strain bonus included in `needSec`, in seconds.
    public let strainBonusSec: Double
    /// Main-night asleep time for the most recent night, in seconds. Naps are excluded.
    public let asleepSec: Double
    /// `asleepSec / needSec`, 0 to 100.
    public let performancePct: Double
    /// Signed debt balance after the most recent night, in seconds (negative = debt). It includes
    /// that night's nap credit. Add `-debtBalanceSec` to the baseline for tonight's need, using
    /// tonight's strain.
    public let debtBalanceSec: Double
}

/// Sleep-coaching summary over a list of blocks.
public enum SleepCoaching {
    /// Summarize the most recent main night.
    ///
    /// The most recent main night is the latest wake day with main sleep. Its need is computed from
    /// the nights before it: debt carried into it, plus the strain bonus from `dayStrain`. Its
    /// performance is main-night asleep divided by that need. `debtBalanceSec` runs over all nights,
    /// so it includes the most recent night.
    ///
    /// `dayStrain` is the strain of the waking day that came before the most recent night (0 to 21).
    /// Pass nil when unknown. Nil returns nil only when no main night exists.
    public static func summarize(
        nights: [SleepNight],
        dayStrain: Double?,
        baselineNeedSec: Double = SleepNeed.defaultBaselineSec,
        timeZone: TimeZone
    ) -> SleepCoachingSummary? {
        let usable = nights.filter(\.isUsable)
        let mainDays = SleepDayGroups.group(usable, in: timeZone).filter { $0.mainSec > 0 }
        guard let latest = mainDays.last else { return nil }

        let latestKey = SleepDayGroups.key(latest.day)
        let priorNights = usable.filter {
            SleepDayGroups.key(LocalTime.localDay(containing: $0.endSec * 1000, in: timeZone)) < latestKey
        }
        let carried = -SleepDebt.ledger(nights: priorNights, needSec: baselineNeedSec, timeZone: timeZone).balanceSec
        let carriedDebt = max(carried, 0)
        let need = SleepNeed.adjustedNeedSec(
            baselineNeedSec: baselineNeedSec,
            sleepDebtSec: carriedDebt,
            dayStrain: dayStrain
        )
        // Napping is credited through the debt ledger, so nap credit is not subtracted from the need.
        let performance = SleepPerformance.percent(asleepSec: latest.mainSec, needSec: need) ?? 0
        let balance = SleepDebt.ledger(nights: usable, needSec: baselineNeedSec, timeZone: timeZone).balanceSec

        return SleepCoachingSummary(
            needSec: need,
            baselineNeedSec: baselineNeedSec,
            carriedDebtSec: carriedDebt,
            strainBonusSec: SleepNeed.strainBonusSec(dayStrain: dayStrain),
            asleepSec: latest.mainSec,
            performancePct: performance,
            debtBalanceSec: balance
        )
    }
}

/// Usable blocks grouped by the local day they end on (the wake day).
///
/// Shared by SleepDebt, SleepCoaching and SleepRegularity. Main-night asleep time is summed across
/// the day's main blocks, following NOOP's "main-night group" convention (SleepDebt.creditedSleepMin
/// doc). Naps are summed separately. The group also records the earliest main start and latest main
/// end, which SleepRegularity uses as bed and wake times.
struct SleepDayTally {
    let day: LocalDay
    var mainSec: Double = 0
    var napSec: Double = 0
    var mainStartSec: Int64?
    var mainEndSec: Int64?
}

enum SleepDayGroups {
    /// Days ascending by wake day.
    static func group(_ nights: [SleepNight], in timeZone: TimeZone) -> [SleepDayTally] {
        var byKey: [Int: SleepDayTally] = [:]
        for night in nights where night.isUsable {
            let day = LocalTime.localDay(containing: night.endSec * 1000, in: timeZone)
            let key = key(day)
            var tally = byKey[key] ?? SleepDayTally(day: day)
            if night.isNap {
                tally.napSec += night.asleepSec
            } else {
                tally.mainSec += night.asleepSec
                tally.mainStartSec = min(tally.mainStartSec ?? night.startSec, night.startSec)
                tally.mainEndSec = max(tally.mainEndSec ?? night.endSec, night.endSec)
            }
            byKey[key] = tally
        }
        return byKey.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Sortable key for a calendar day (yyyymmdd).
    static func key(_ day: LocalDay) -> Int {
        day.year * 10_000 + day.month * 100 + day.day
    }
}
