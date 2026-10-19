import Foundation
import Testing
@testable import BandKit

// Port of NOOP's BackfillPolicy decision behaviour (github.com/ryanbr/noop @ ef165de4): the
// 15-min periodic floor, the 90-s event floor, the empty-drain backoff (threshold 3, doubling,
// cap ×4) and the clock-untrusted skip. Pure — no time source, no BLE.
@Suite("Backfill policy")
struct BackfillPolicyTests {
    // MARK: First run

    @Test func theFirstRunAlwaysPasses() {
        for trigger in [BackfillTrigger.periodic, .connect, .foreground, .manual, .strap, .autoContinue] {
            #expect(BackfillPolicy.shouldRun(trigger: trigger, now: 100, lastBackfillAt: nil))
        }
    }

    // MARK: Un-floored triggers

    @Test func manualAndAutoContinueAreNeverFloored() {
        // Even 10 s after the last drain with a long empty streak, a manual kick runs.
        #expect(BackfillPolicy.shouldRun(trigger: .manual, now: 10, lastBackfillAt: 0, emptyStreak: 9))
        #expect(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 10, lastBackfillAt: 0, emptyStreak: 9))
        #expect(BackfillPolicy.shouldRun(trigger: .manual, now: 10, lastBackfillAt: 0, emptyStreak: 9, clockUntrusted: true))
    }

    // MARK: Event floor (connect / foreground = 90 s)

    @Test func connectAndForegroundKeepTheNinetySecondEventFloor() {
        #expect(!BackfillPolicy.shouldRun(trigger: .connect, now: 89.9, lastBackfillAt: 0))
        #expect(BackfillPolicy.shouldRun(trigger: .connect, now: 90, lastBackfillAt: 0))
        #expect(!BackfillPolicy.shouldRun(trigger: .foreground, now: 89.9, lastBackfillAt: 0))
        #expect(BackfillPolicy.shouldRun(trigger: .foreground, now: 90, lastBackfillAt: 0))
        // They never back off on empties, and a future clock never skips them.
        #expect(BackfillPolicy.shouldRun(trigger: .connect, now: 90, lastBackfillAt: 0, emptyStreak: 10))
        #expect(BackfillPolicy.shouldRun(trigger: .foreground, now: 90, lastBackfillAt: 0, clockUntrusted: true))
    }

    // MARK: Periodic floor (15 min)

    @Test func periodicKeepsTheFifteenMinuteFloor() {
        #expect(!BackfillPolicy.shouldRun(trigger: .periodic, now: 899, lastBackfillAt: 0))
        #expect(BackfillPolicy.shouldRun(trigger: .periodic, now: 900, lastBackfillAt: 0))
    }

    // MARK: Empty-drain backoff

    @Test func emptiesBelowTheThresholdDoNotStretchTheFloor() {
        for streak in 0...2 {
            #expect(BackfillPolicy.shouldRun(trigger: .periodic, now: 900, lastBackfillAt: 0, emptyStreak: streak))
            #expect(BackfillPolicy.shouldRun(trigger: .strap, now: 90, lastBackfillAt: 0, emptyStreak: streak))
        }
    }

    @Test func emptiesDoubleTheAutomaticFloorsCappedAtFourTimes() {
        // streak 3 → ×2, streak 4 → ×4, streak 5+ → capped at ×4 (NOOP's 2^n growth).
        #expect(BackfillPolicy.backoffMultiplier(emptyStreak: 3) == 2)
        #expect(BackfillPolicy.backoffMultiplier(emptyStreak: 4) == 4)
        #expect(BackfillPolicy.backoffMultiplier(emptyStreak: 5) == 4, "the cap")
        #expect(!BackfillPolicy.shouldRun(trigger: .periodic, now: 1799, lastBackfillAt: 0, emptyStreak: 3))
        #expect(BackfillPolicy.shouldRun(trigger: .periodic, now: 1800, lastBackfillAt: 0, emptyStreak: 3))
        #expect(!BackfillPolicy.shouldRun(trigger: .periodic, now: 3599, lastBackfillAt: 0, emptyStreak: 4))
        #expect(BackfillPolicy.shouldRun(trigger: .periodic, now: 3600, lastBackfillAt: 0, emptyStreak: 4))
        #expect(!BackfillPolicy.shouldRun(trigger: .periodic, now: 3599, lastBackfillAt: 0, emptyStreak: 9), "the cap holds")
        #expect(BackfillPolicy.shouldRun(trigger: .periodic, now: 3600, lastBackfillAt: 0, emptyStreak: 9))
        #expect(!BackfillPolicy.shouldRun(trigger: .strap, now: 179.9, lastBackfillAt: 0, emptyStreak: 3))
        #expect(BackfillPolicy.shouldRun(trigger: .strap, now: 180, lastBackfillAt: 0, emptyStreak: 3))
    }

    // MARK: Clock untrusted (future-dated RTC)

    @Test func anUntrustedClockSkipsTheAutomaticTriggersEntirely() {
        // Even far past the (un-stretched) floors, .periodic and .strap are denied…
        #expect(!BackfillPolicy.shouldRun(trigger: .periodic, now: 900_000, lastBackfillAt: 0, clockUntrusted: true))
        #expect(!BackfillPolicy.shouldRun(trigger: .strap, now: 900_000, lastBackfillAt: 0, clockUntrusted: true))
        // …while connect (the per-connection pass), foreground and manual still run.
        #expect(BackfillPolicy.shouldRun(trigger: .connect, now: 90, lastBackfillAt: 0, clockUntrusted: true))
        #expect(BackfillPolicy.shouldRun(trigger: .foreground, now: 90, lastBackfillAt: 0, clockUntrusted: true))
        #expect(BackfillPolicy.shouldRun(trigger: .manual, now: 0, lastBackfillAt: 0, clockUntrusted: true))
    }

    // MARK: isFutureDatedNewest (NOOP #928/#1012)

    @Test func futureDatedNewestUsesTheFortyEightHourSkew() {
        let wall = 1_791_382_500
        #expect(BackfillPolicy.isFutureDatedNewest(nil, wallNowUnix: wall) == false, "an unanswered range is UNKNOWN, not future-dated")
        #expect(BackfillPolicy.isFutureDatedNewest(wall, wallNowUnix: wall) == false)
        #expect(BackfillPolicy.isFutureDatedNewest(wall + 48 * 3600, wallNowUnix: wall) == false, "the boundary is strict >")
        #expect(BackfillPolicy.isFutureDatedNewest(wall + 48 * 3600 + 1, wallNowUnix: wall))
        #expect(BackfillPolicy.isFutureDatedNewest(wall + 400 * 86_400, wallNowUnix: wall))
        #expect(BackfillPolicy.isFutureDatedNewest(wall - 3_000_000_000, wallNowUnix: wall) == false, "a stale PAST epoch is the #451 case, not future-dated")
    }
}

// The corrupt-RTC diagnostics: the 1-day tolerance boundary, the two sentinel meanings, and the
// drop line — ported from NOOP's Backfiller with the wording adapted to Icarus.
@Suite("Backfill diagnostics")
struct BackfillDiagnosticsTests {
    private let wall = 1_791_382_500

    @Test func theFutureToleranceIsOneDayInclusive() {
        #expect(BackfillDiagnostics.isCorruptFutureRtc(unix: wall, wallNowUnix: wall) == false)
        #expect(BackfillDiagnostics.isCorruptFutureRtc(unix: wall + 86_400, wallNowUnix: wall) == false, "exactly at the tolerance")
        #expect(BackfillDiagnostics.isCorruptFutureRtc(unix: wall + 86_401, wallNowUnix: wall))
        #expect(BackfillDiagnostics.isCorruptFutureRtc(unix: wall - 400 * 86_400, wallNowUnix: wall) == false, "the past is banked history, not corruption")
    }

    @Test func theFutureRtcLineNamesTheCauseAndTheFix() {
        let line = BackfillDiagnostics.futureRtcLine(unix: wall + 3 * 86_400, wallNowUnix: wall)
        #expect(line.contains("3 day(s) in the FUTURE"))
        #expect(line.contains("its clock (RTC) is corrupt, not an Icarus problem"))
        #expect(line.contains("Fully charge the strap"))
    }

    @Test func theNoCursorSentinelDistinguishesCaughtUpFromNoHistory() {
        let caughtUp = BackfillDiagnostics.noCursorLine(rowsKept: 7)
        #expect(caughtUp.contains("caught up after persisting 7 row(s) this run"))
        let noHistory = BackfillDiagnostics.noCursorLine(rowsKept: 0)
        #expect(noHistory.contains("strap reported no flash cursor (trim=0xFFFFFFFF)"))
        #expect(noHistory.contains("no banked history"))
    }

    @Test func theFutureRecordDropLineReportsTheAge() {
        let line = BackfillDiagnostics.futureRecordDroppedLine(unix: wall + 2 * 86_400, wallNowUnix: wall)
        #expect(line.contains("2 day(s) in the FUTURE"))
        #expect(line.contains("was not emitted or stored"))
    }

    @Test func theFutureDatedNewestLineReportsTheHours() {
        let line = BackfillDiagnostics.futureDatedNewestLine(newest: wall + 5 * 3600, wallNowUnix: wall)
        #expect(line.contains("5h AHEAD of the wall clock"))
        #expect(line.contains("automatic re-drains pause"))
    }
}
