/// Pure clock decision: should we SET_CLOCK on this connect?
///
/// Ported from NOOP `Strand/Collect/ClockPolicy.swift` (github.com/ryanbr/noop @ ef165de4): the
/// clock is set only when the strap's RTC has drifted beyond a small threshold (or is frozen/way
/// off), not blindly on every connect. A healthy clock is never gratuitously reset — avoiding
/// discontinuities in derived historical timestamps. No I/O and no time source: the caller passes
/// the device reading and wall now, so the decision is fully unit-testable.
public enum ClockPolicy {
    /// How far the strap's RTC may sit from the phone's wall clock before SET_CLOCK fires
    /// (NOOP's default: 2 s).
    public static let driftThreshold: Int = 2

    /// `deviceClock` = the strap's current RTC reading (unix seconds, from GET_CLOCK). `wallNow` =
    /// phone wall time (unix seconds). Returns true when |drift| >= threshold.
    public static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = ClockPolicy.driftThreshold) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }

    /// The clock value carried by a GET_CLOCK COMMAND_RESPONSE reply payload: a response counter
    /// and a result byte lead, and the u32 little-endian RTC reading sits at payload bytes 2..6
    /// (NOOP PostHooks, `GET_CLOCK` case: `pay.count >= 6`). Nil when the reply is too short to
    /// carry the value — the caller then has NO decoded reading and NOOP never sets the clock
    /// from one, so SET_CLOCK is skipped and retried on the next connection.
    public static func deviceClock(replyPayload: [UInt8]) -> Int? {
        guard replyPayload.count >= 6 else { return nil }
        return Int(replyPayload[2])
            | (Int(replyPayload[3]) << 8)
            | (Int(replyPayload[4]) << 16)
            | (Int(replyPayload[5]) << 24)
    }
}
