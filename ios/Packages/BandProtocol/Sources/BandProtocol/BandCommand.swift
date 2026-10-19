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

    /// STOP_HAPTICS (cmd 122). Carries the standard `[0x00]` command byte (NOOP, verified on 4.0).
    public static func stopHaptics() -> BandCommand {
        BandCommand(.stopHaptics, payload: [0x00])
    }

    /// GET_ALL_HAPTICS_PATTERN (cmd 80). PLAN.md 5.3.4 says NOOP has never sent it, so the reply is unknown.
    /// Carries the standard `[0x00]` command byte.
    public static func getAllHapticsPatterns() -> BandCommand {
        BandCommand(.getAllHapticsPatterns, payload: [0x00])
    }

    /// GET_HELLO (cmd 35). The identity hello the official app sends first on every link. The strap
    /// replies with a version/name frame. Carries the standard `[0x00]` command byte.
    public static func getHello() -> BandCommand {
        BandCommand(.getHello, payload: [0x00])
    }

    // MARK: Alarm and clock

    /// SET_ALARM_TIME (cmd 66). The UTC unix time is a u32 little-endian value (PLAN.md 5.3.4).
    /// The leading `0x01` and the four trailing zero bytes are not in PLAN.md. They are the layout of
    /// the seven golden frames `set_alarm_*` (S8), so they are [Unverified] beyond those vectors.
    public static func setAlarmTime(unix: UInt32) -> BandCommand {
        BandCommand(.setAlarmTime, payload: [0x01] + littleEndian(unix) + [0, 0, 0, 0])
    }

    /// GET_ALARM_TIME (cmd 67). Carries `[0x01]` (NOOP, verified on 4.0). [Unverified]
    public static func getAlarmTime() -> BandCommand {
        BandCommand(.getAlarmTime, payload: [0x01])
    }

    /// GET_CLOCK (cmd 11). Carries `[0x00]` — a command with an empty payload is ACKed by the
    /// strap but silently discarded by its command processor (NOOP and captured official-app
    /// frames all carry at least one payload byte). [Unverified]
    public static func getClock() -> BandCommand {
        BandCommand(.getClock, payload: [0x00])
    }

    /// SET_CLOCK (cmd 10). Sets the strap's RTC, which alarms and history timestamps rely on
    /// (PLAN.md 5.3.4). 8-byte form: `[secs u32 LE][subsecs u32 LE]` (NOOP). A wrong-length
    /// SET_CLOCK is ACKed but not latched per community findings, and some firmware never replies,
    /// so callers write it as a confirmed write without awaiting a response.
    public static func setClock(unix: UInt32, subseconds: UInt32 = 0) -> BandCommand {
        BandCommand(.setClock, payload: littleEndian(unix) + littleEndian(subseconds))
    }

    /// SET_CLOCK's legacy 9-byte form: `[secs u32 LE][5 zero]`. WHOOP 4 firmware 41.17.x latches
    /// ONLY this form — the 8-byte body draws no command response and the RTC stays lost, which
    /// also stops the strap from banking sensor history (NOOP, hardware-verified on fw 41.17.6.0;
    /// newer firmware is the reverse). Callers send both forms with the same seconds; double-
    /// latching is harmless.
    public static func setClockLegacy(unix: UInt32) -> BandCommand {
        BandCommand(.setClock, payload: littleEndian(unix) + [0, 0, 0, 0, 0])
    }

    // MARK: Battery and data

    /// GET_BATTERY_LEVEL (cmd 26). Carries `[0x00]` (NOOP, verified on 4.0).
    /// The same frame, written with response, is the bonding write on 61080002 (PLAN.md 5.3.2).
    public static func getBatteryLevel() -> BandCommand {
        BandCommand(.getBatteryLevel, payload: [0x00])
    }

    /// GET_DATA_RANGE (cmd 34). Carries `[0x00]` (NOOP, verified on 4.0). [Unverified]
    public static func getDataRange() -> BandCommand {
        BandCommand(.getDataRange, payload: [0x00])
    }

    // MARK: Heart rate

    /// TOGGLE_REALTIME_HR (cmd 3). PLAN.md 5.3.4 gives no payload. The golden frames `health_monitor_on`
    /// and `health_monitor_off` (S8) use `[1]` and `[0]`.
    public static func toggleRealtimeHR(on: Bool) -> BandCommand {
        BandCommand(.toggleRealtimeHR, payload: [on ? 1 : 0])
    }

    /// SEND_R10_R11_REALTIME (cmd 63). Enables or disables the REALTIME_RAW_DATA (type 0x2B) raw
    /// accel/PPG flood on `61080005`, ~1.9 KB/s (PLAN.md 7.2 step 4, whoop-parity §3.4). Payload
    /// `[0x01]` on / `[0x00]` off (NOOP [S12]). The flood competes with the ack-driven history
    /// drain for BLE throughput, so the handshake sends it `[0x00]` after the clock exchange, as a
    /// confirmed write without awaiting a reply — no Icarus capture shows a cmd-63
    /// COMMAND_RESPONSE. Payload forms are [Unverified] beyond the NOOP source.
    public static func toggleRealtimeRaw(on: Bool) -> BandCommand {
        BandCommand(.sendR10R11Realtime, payload: [on ? 1 : 0])
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
    /// Percent from a COMMAND_RESPONSE payload. Replies lead with a response counter and a
    /// status byte (verified live on a WHOOP 4.0: `03 01 D8 03 …` → 0x03D8 = 984 → 98.4 %),
    /// so the little-endian u16 sits at offset 2, not 0. [Unverified] across firmware revisions.
    public static func percent(payload: [UInt8]) -> Double? {
        guard payload.count >= 4 else { return nil }
        let raw = UInt16(payload[2]) | (UInt16(payload[3]) << 8)
        return Double(raw) / 10
    }
}
