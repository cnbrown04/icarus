import Foundation

/// What prompted a history-drain attempt. Ported from NOOP
/// `Strand/BLE/BackfillPolicy.swift` (github.com/ryanbr/noop @ ef165de4), which mirrors WHOOP's
/// own sync triggers. Icarus wires `.periodic` (the redrain task), `.connect` (the handshake's
/// drain), `.manual` and `.foreground` (the public `syncNow(trigger:)` — the app calls it on
/// scenePhase changes), and `.strap` (the strap's HIGH_FREQ_SYNC_PROMPT event 96). `.autoContinue`
/// exists for parity with NOOP's back-to-back drain continuation; Icarus does not fire it yet.
public enum BackfillTrigger: Sendable, Equatable {
    /// The repeating timer while the link is ready.
    case periodic
    /// A (re)connect / bond confirmation.
    case connect
    /// The app became active (scenePhase .active).
    case foreground
    /// The user tapped "Sync now".
    case manual
    /// An incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog, event 96).
    case strap
    /// NOOP #364: an immediate back-to-back continuation of a deep oldest-first backlog, fired
    /// right after a drain exit while still connected. Un-floored like `.manual`, but bounded by
    /// the caller's own caps. Not fired by Icarus yet.
    case autoContinue
}

/// Pure rate-limiter for history-drain kicks. No BLE/store/time deps — the caller passes
/// everything, so the decision is fully unit-testable.
///
/// Ported from NOOP `Strand/BLE/BackfillPolicy.swift` verbatim. Floors match WHOOP (observed:
/// ~15-min periodic + expedited event syncs).
public enum BackfillPolicy {
    public static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    public static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts
    public static let emptyBackoffThreshold = 3                  // empties before the floor starts stretching
    public static let maxEmptyBackoff: Double = 4                // cap → ~6-min event / 1-hr periodic floor
    /// NOOP's `BackfillContinuation.defaultFutureSkewSeconds` (#928): how far past the WALL CLOCK a
    /// strap-reported "newest" may sit before it is implausible. 48 h absorbs genuine timezone
    /// confusion and mild drift; nothing legitimate banks records two days ahead of the phone.
    public static let defaultFutureSkewSeconds = 48 * 3600

    /// The floor multiplier for `emptyStreak` consecutive drains that banked nothing: 1 before the
    /// threshold, then doubling per further empty, capped at `maxEmptyBackoff`. Exposed so a
    /// driver can sleep exactly until the next allowed instant.
    public static func backoffMultiplier(emptyStreak: Int) -> Double {
        emptyStreak >= emptyBackoffThreshold
            ? min(pow(2.0, Double(emptyStreak - emptyBackoffThreshold + 1)), maxEmptyBackoff)
            : 1.0
    }

    /// `emptyStreak` = consecutive COMPLETED drains that banked no sensor records. Past the
    /// threshold the AUTOMATIC triggers (.periodic/.strap) stretch their floor — each further
    /// empty doubles it, capped — so an off-wrist / not-banking strap that still emits EVENT
    /// packets every 90s isn't re-drained console-only every 90s, draining its battery
    /// (NOOP #77/#120/#216). `.manual`/`.connect`/`.foreground` never back off, and the first real
    /// record resets the streak, so baseline cadence resumes instantly.
    ///
    /// `clockUntrusted` = the strap's own RTC currently reads future-dated (a corrupt RTC: a
    /// future-dated HISTORY_END or record, or a GET_DATA_RANGE newest beyond the skew). Such a
    /// strap still BANKS real rows every pass, so it never trips the `emptyStreak` backoff above —
    /// which is why the recurring AUTOMATIC triggers are SKIPPED ENTIRELY while the clock is
    /// untrusted (NOOP #160): each ~60s drain holds the link and starves the realtime-HR
    /// keep-alive. The per-connection `.connect` pass still runs, so a clock that later
    /// self-corrects is picked up on the next connection (or a manual sync).
    public static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                                 lastBackfillAt: TimeInterval?, emptyStreak: Int = 0,
                                 clockUntrusted: Bool = false) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        let backoff = backoffMultiplier(emptyStreak: emptyStreak)
        switch trigger {
        // .manual (user-tapped) and .autoContinue (expedited backlog drain) always run — both are
        // deliberately un-floored; .autoContinue's runaway protection lives in the caller's cap.
        case .manual, .autoContinue: return true
        case .connect, .foreground:  return elapsed >= eventFloorSeconds
        // A future-dated-clock strap's recurring automatic drains are near-useless but each holds
        // the link ~60s and starves the realtime-HR re-arm, so skip them entirely — not just
        // stretch the floor. The .connect pass above still re-checks the clock (NOOP #160).
        case .strap:                 return !clockUntrusted && elapsed >= eventFloorSeconds * backoff
        case .periodic:              return !clockUntrusted && elapsed >= periodicFloorSeconds * backoff
        }
    }

    /// NOOP `BackfillContinuation.isFutureDatedNewest` (#928/#1012): is the strap-reported "newest
    /// banked record" FUTURE-dated beyond the skew allowance — more than `futureSkewSeconds` past
    /// the wall clock? The strap's clock is then almost certainly set in the future, so its range
    /// answer is untrustworthy as backlog evidence and the automatic drains skip. 48 h absorbs
    /// genuine timezone confusion and mild drift; nothing legitimate banks records two days ahead
    /// of the phone's clock. nil ⇒ false: an unanswered range is UNKNOWN, not future-dated.
    public static func isFutureDatedNewest(_ strapNewestTs: Int?, wallNowUnix: Int,
                                           futureSkewSeconds: Int = BackfillPolicy.defaultFutureSkewSeconds) -> Bool {
        guard let n = strapNewestTs else { return false }
        return n > wallNowUnix + futureSkewSeconds
    }
}
