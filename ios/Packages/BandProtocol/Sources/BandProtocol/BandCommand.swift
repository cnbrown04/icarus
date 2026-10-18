/// A typed command for the band: a whitelisted opcode and its payload (PLAN.md 5.3.4).
///
/// Built only through the static builders below, so every frame carries an opcode from `SafeCommand`.
/// Payload layouts marked [Unverified] are not documented in PLAN.md; they are either read from the
/// golden frames in shared/golden/frames.json or assumed, and must be checked on hardware (PLAN.md 5.5).
public struct BandCommand: Sendable, Equatable {
    public let command: SafeCommand
    public let payload: [UInt8]

    init(_ command: SafeCommand, payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    /// The complete COMMAND frame for `seq` (PLAN.md 5.3.3).
    public func frame(seq: UInt8) -> [UInt8] {
        FrameCodec.encodeCommand(command, seq: seq, payload: payload)
    }

    // MARK: Haptics

    /// RUN_HAPTICS_PATTERN (cmd 79). Payload `[patternId, numLoops, 0, 0, 0]` (PLAN.md 5.3.4).
    /// Single source [Community]: NOOP uses `patternId = 2`. No captured 4.0 frame exists.
    public static func runHapticsPattern(patternId: UInt8, loops: UInt8) -> BandCommand {
        BandCommand(.runHapticsPattern, payload: [patternId, loops, 0, 0, 0])
    }

    /// STOP_HAPTICS (cmd 122). PLAN.md 5.3.4 names the command but not a payload. Empty is assumed. [Unverified]
    public static func stopHaptics() -> BandCommand {
        BandCommand(.stopHaptics)
    }

    /// GET_ALL_HAPTICS_PATTERN (cmd 80). PLAN.md 5.3.4 says NOOP has never sent it, so the reply is unknown.
    /// Empty payload is assumed. [Unverified]
    public static func getAllHapticsPatterns() -> BandCommand {
        BandCommand(.getAllHapticsPatterns)
    }

    // MARK: Alarm and clock

    /// SET_ALARM_TIME (cmd 66). The UTC unix time is a u32 little-endian value (PLAN.md 5.3.4).
    /// The leading `0x01` and the four trailing zero bytes are not in PLAN.md. They are the layout of
    /// the seven golden frames `set_alarm_*` (S8), so they are [Unverified] beyond those vectors.
    public static func setAlarmTime(unix: UInt32) -> BandCommand {
        BandCommand(.setAlarmTime, payload: [0x01] + littleEndian(unix) + [0, 0, 0, 0])
    }

    /// GET_ALARM_TIME (cmd 67). Empty payload assumed. [Unverified]
    public static func getAlarmTime() -> BandCommand {
        BandCommand(.getAlarmTime)
    }

    /// GET_CLOCK (cmd 11). Empty payload assumed. [Unverified]
    public static func getClock() -> BandCommand {
        BandCommand(.getClock)
    }

    // TODO(PLAN.md 5.3.4, 7.2): SET_CLOCK (cmd 10). The payload is 8 or 9 bytes depending on firmware,
    // but PLAN.md does not document its layout, so no builder exists yet. Until it does, the
    // handshake skips SET_CLOCK and only reads the clock.

    // MARK: Battery and data

    /// GET_BATTERY_LEVEL (cmd 26). Empty request payload assumed. [Unverified]
    /// The same frame, written with response, is the bonding write on 61080002 (PLAN.md 5.3.2).
    public static func getBatteryLevel() -> BandCommand {
        BandCommand(.getBatteryLevel)
    }

    /// GET_DATA_RANGE (cmd 34). Empty payload assumed. [Unverified]
    public static func getDataRange() -> BandCommand {
        BandCommand(.getDataRange)
    }

    // MARK: Heart rate

    /// TOGGLE_REALTIME_HR (cmd 3). PLAN.md 5.3.4 gives no payload. The golden frames `health_monitor_on`
    /// and `health_monitor_off` (S8) use `[1]` and `[0]`.
    public static func toggleRealtimeHR(on: Bool) -> BandCommand {
        BandCommand(.toggleRealtimeHR, payload: [on ? 1 : 0])
    }

    /// Standard HR broadcast toggle (cmd 14, PLAN.md 5.3.1 and 5.3.4). The payload `[1]` or `[0]`
    /// reproduces the golden frames `hr_broadcast_on_*` and `hr_broadcast_off_*` (S8) byte for byte.
    public static func hrBroadcast(on: Bool) -> BandCommand {
        BandCommand(.toggleHRBroadcast, payload: [on ? 1 : 0])
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}

/// The GET_BATTERY_LEVEL reply (PLAN.md 5.3.4): the level is `u16 / 10` percent.
public enum BatteryLevel {
    /// Percent from a COMMAND_RESPONSE payload. Reads a little-endian u16 at offset 0. [Unverified]
    /// PLAN.md 5.3.4 gives the scaling but not the offset.
    public static func percent(payload: [UInt8]) -> Double? {
        guard payload.count >= 2 else { return nil }
        let raw = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        return Double(raw) / 10
    }
}
