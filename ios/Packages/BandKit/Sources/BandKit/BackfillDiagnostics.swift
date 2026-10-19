import Foundation

/// Pure log-line builders for the history-drain's corrupt-RTC diagnostics, ported from NOOP's
/// `Backfiller` (github.com/ryanbr/noop @ ef165de4). No I/O and no time source: everything is
/// passed in, so the lines and thresholds are pinned by tests and BandLog carries them verbatim.
enum BackfillDiagnostics {
    /// How far ahead of the wall clock a HISTORY_END's own timestamp (or a record's unix) may sit
    /// before the strap RTC is called corrupt. The strap RTC and the phone normally agree within
    /// seconds; banked history is always dated in the PAST. Generous (1 day) so ordinary skew or a
    /// timezone confusion never trips it (NOOP `futureRtcToleranceSeconds`).
    static let futureToleranceSeconds = 86_400

    /// Is this timestamp an implausible FUTURE date (a corrupt strap RTC)? Both values are unix
    /// seconds in the same wall domain.
    static func isCorruptFutureRtc(unix: Int, wallNowUnix: Int) -> Bool {
        unix > wallNowUnix + futureToleranceSeconds
    }

    /// The recovery-hint line for a corrupt future-dated strap RTC (NOOP `futureRtcLine`, adapted
    /// to Icarus). Names the cause plainly (the strap's clock, not an Icarus bug) and gives the fix.
    static func futureRtcLine(unix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, unix - wallNowUnix) / 86_400
        return "the strap reported history dated about \(aheadDays) day(s) in the FUTURE - its clock (RTC) is corrupt, not an Icarus problem. Those records are being dropped rather than misfiled, and automatic re-drains are paused until the clock reads sane. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it persists, forget and re-pair the strap."
    }

    /// The trim=0xFFFFFFFF sentinel line (NOOP #783). 0xFFFFFFFF means two different things
    /// depending on whether THIS drain already kept rows: rows > 0 gives the neutral caught-up
    /// line; 0 gives the genuine no-history guidance. NOOP distinguishes these so an empty tail of
    /// a productive sync doesn't false-alarm "charge to 100%".
    static func noCursorLine(rowsKept: Int) -> String {
        if rowsKept > 0 {
            return "drain reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting \(rowsKept) row(s) this run. Nothing more to offload."
        }
        return "strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking."
    }

    /// The one-line record drop (the record-timestamp gate): a historical record dated implausibly
    /// far in the future is dropped BEFORE it can pollute the store.
    static func futureRecordDroppedLine(unix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, unix - wallNowUnix) / 86_400
        return "dropped a historical record dated about \(aheadDays) day(s) in the FUTURE (unix \(unix)) - the strap's clock is corrupt; the record was not emitted or stored."
    }

    /// The GET_DATA_RANGE future-dated-newest line (NOOP #928 call site): the strap's reported
    /// newest banked record sits implausibly ahead of the wall clock, so the range is untrusted.
    static func futureDatedNewestLine(newest: Int, wallNowUnix: Int) -> String {
        let aheadHours = (newest - wallNowUnix) / 3600
        return "the strap's newest banked record reads \(aheadHours)h AHEAD of the wall clock (implausible; the strap's clock is set in the future). The range is untrusted: automatic re-drains pause until the clock reads sane."
    }
}
