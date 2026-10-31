import Foundation

/// The ring-buffer state a GET_DATA_RANGE reply reports. OpenStrap PROTOCOL.md §4.3 / NOOP's
/// DataRange: the write pointer `W` (where the strap banks next), the read pointer `U` (the
/// persistent drain cursor — SET_READ_POINTER repositions it), and the ring capacity `T`
/// (131072 in every real capture so far). `pagesBehind` is the backlog with wraparound:
/// `W < U ? W + (T − U) : W − U`.
public struct RingState: Sendable, Equatable {
    public let write: Int
    public let read: Int
    public let capacity: Int

    /// The backlog the strap reports, with wraparound (`W < U` means the write pointer passed
    /// capacity and resumed at 0 while the read pointer lagged behind).
    public var pagesBehind: Int {
        write < read ? write + (capacity - read) : write - read
    }

    public init(write: Int, read: Int, capacity: Int) {
        self.write = write
        self.read = read
        self.capacity = capacity
    }
}

/// GET_DATA_RANGE frame parsing. Ported byte-exactly from NOOP
/// `Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift`
/// (github.com/ryanbr/noop @ ef165de4), which is itself byte-identical to NOOP's Kotlin twin
/// `com.noop.protocol.DataRange`. The functions scan the RAW frame bytes (the `[0xAA]…` envelope
/// included) — `FrameCodec.reencode` reconstructs them from a decoded `Frame` losslessly.
///
/// The newest-record read gates automatic sync (`isFutureDatedNewest` → the backfill policy), so
/// its value must stay byte-identical across implementations.
public enum DataRange {
    /// The newest plausible unix time banked by the strap, from a GET_DATA_RANGE frame.
    ///
    /// Scans EVERY byte offset — the newest-record `u32` isn't on a fixed grid (it sits at byte
    /// offset 8 on WHOOP 4.0, off the old aligned-from-7 scan, which straddled it and returned
    /// nil). Keeps the newest word inside a plausible unix window (2023-11…2030-03), preferring
    /// the newest that is NOT implausibly future (> `wallNowUnix + futureSkewSeconds`) so a
    /// garbage future word can't latch and stall auto-sync. Falls back to the newest-any word so a
    /// genuinely future-dated RTC is still surfaced downstream and the future-date guard still
    /// fires. Returns nil only for a too-short frame or no plausible word at all.
    public static func newestUnix(from frame: [UInt8], wallNowUnix: Int, futureSkewSeconds: Int) -> Int? {
        guard frame.count >= 4 else { return nil }
        let futureCutoff = wallNowUnix + futureSkewSeconds
        var newestNotFuture: Int? = nil
        var newestAny: Int? = nil
        var i = 0
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 {
                newestAny = max(newestAny ?? 0, w)
                if w <= futureCutoff { newestNotFuture = max(newestNotFuture ?? 0, w) }
            }
            i += 1
        }
        return newestNotFuture ?? newestAny
    }

    ///
    /// Unlike `newestUnix`, this scans ONLY the 4-byte grid aligned from offset 7, NOT every
    /// offset — and that asymmetry is DELIBERATE. The minimum is fragile in a way the maximum is
    /// not: an any-offset scan of a real WHOOP 4.0 frame surfaces a spurious straddle word
    /// (offset 6 → 1_754_857_506, ~11 months *before* the true newest at offset 8) that would
    /// hijack the min and report a bogus deep backlog. The max is immune — the real newest
    /// dominates it — which is exactly why `newestUnix` can scan every offset. The aligned grid
    /// skips that straddle, so real frames with no distinct oldest word return nil here. Do NOT
    /// "make this consistent with `newestUnix`" by scanning every offset without anchoring — see
    /// `DataRangeTests.oldestAlignedScanSkipsTheSpuriousOffset6Straddle`.
    public static func oldestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        var oldest: Int? = nil
        var i = 7
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { oldest = min(oldest ?? .max, w) }
            i += 4
        }
        return oldest
    }

    /// The ring-buffer page backlog ("pages behind") the strap reports in a GET_DATA_RANGE
    /// response — DIAGNOSTIC ONLY (it never gates sync or backfill itself). Confirmed against
    /// real captures on both WHOOP 4.0 and 5.0/MG upstream: the write/read pointers and ring
    /// capacity land exactly where this predicts, across four independent frames.
    ///
    /// The app reads three u32s from the command-response INNER payload (whose byte 0 is a
    /// subtype), at `V(i) = word @ (i*4 + 3)`: write pointer `W = V(2)`, read pointer `U = V(3)`,
    /// ring capacity `T = V(5)`. The inner payload starts at `cmdOff + 1` (`cmdOff` = the frame
    /// offset of the cmd byte: 6 on WHOOP 4.0), so those words sit at frame offsets
    /// `cmdOff + 12/16/24` here. Read u32 LITTLE-endian to match the frame's other words. Backlog
    /// with wraparound (unverified upstream — no real capture has crossed it yet, but harmless to
    /// ship since this only ever feeds a diagnostic): `W < U ? W + (T - U) : W - U`. `T` has been
    /// `131072` in every real capture so far (both families) but is read from the frame each time
    /// rather than hardcoded, in case a firmware revision differs.
    ///
    /// Returns nil for a too-short frame or implausible values — a capacity that is 0 or above a
    /// sane ceiling (a misaligned read hitting a timestamp / `0xFFFFFFFF`), a pointer at/beyond
    /// capacity, or a backlog past capacity — so a garbage frame can never log a nonsense number.
    /// Decodes the GET_DATA_RANGE reply's full ring state (`write`, `read`, `capacity`), not just
    /// the backlog. The word offsets and the plausibility guards are exactly `pagesBehind`'s
    /// (NOOP's hardware-confirmed layout: the words sit at `cmdOff + 12/16/24`, little-endian, and
    /// a pointer at/beyond capacity or a nonsense capacity is a misaligned read, not a ring).
    ///
    /// [Unverified] guard consequence: a strap whose write pointer is a MONOTONIC counter (never
    /// wrapped, `W ≥ T` after ~36 h of 1 Hz history) is rejected here just like in `pagesBehind`.
    /// No real capture has crossed the wrap yet, so the conservative NOOP semantics stand; revisit
    /// when a live capture shows `W ≥ T`.
    ///
    /// [Unverified] wrapped-ring reading (the full-history restore relies on it): if W wraps back
    /// to 0 at T, the OLDEST surviving slot is W itself and the newest is W − 1, so the ring reads
    /// oldest-first from W around to W − 1. A restore that rewinds to 0 skips the oldest
    /// `T − W` slots; `TierBController.drainFullHistory` starts past W for that reason. Not yet
    /// confirmed on hardware: the 2026-10-23 "acked data is gone" finding fits this reading.
    public static func ringState(from frame: [UInt8], cmdOff: Int) -> RingState? {
        guard cmdOff >= 0 else { return nil }
        let payloadOffset = cmdOff + 1
        let wOff = payloadOffset + 11, uOff = payloadOffset + 15, tOff = payloadOffset + 23
        guard tOff + 4 <= frame.count else { return nil }
        func u32(_ o: Int) -> Int {
            Int(frame[o]) | Int(frame[o + 1]) << 8 | Int(frame[o + 2]) << 16 | Int(frame[o + 3]) << 24
        }
        let w = u32(wOff), u = u32(uOff), t = u32(tOff)
        guard t > 0, t <= 0x00FF_FFFF, w < t, u < t else { return nil }
        return RingState(write: w, read: u, capacity: t)
    }

    /// The ring generation word GET_DATA_RANGE carries after the read pointer (`cmdOff + 20`, u32 LE).
    /// [Unverified] meaning: on fw 41.17.x it reads 1, the same value as the second word of every
    /// HISTORICAL_DATA_RESULT cursor token (`[page u32][1 u32]`), so it is read as the epoch / wrap
    /// count those tokens carry. Nil for a frame too short to hold it.
    public static func ringEpoch(from frame: [UInt8], cmdOff: Int) -> UInt32? {
        let offset = cmdOff + 20
        guard cmdOff >= 0, offset + 4 <= frame.count else { return nil }
        return UInt32(frame[offset]) | UInt32(frame[offset + 1]) << 8
            | UInt32(frame[offset + 2]) << 16 | UInt32(frame[offset + 3]) << 24
    }

    public static func pagesBehind(from frame: [UInt8], cmdOff: Int) -> Int? {
        guard let state = ringState(from: frame, cmdOff: cmdOff) else { return nil }
        let behind = state.pagesBehind
        guard behind >= 0, behind <= state.capacity else { return nil }
        return behind
    }
}
