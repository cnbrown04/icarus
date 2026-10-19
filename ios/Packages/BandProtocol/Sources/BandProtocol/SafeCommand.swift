/// Commands Icarus may send to the band (PLAN.md 5.3.4, decimal opcodes).
/// `FrameCodec.encodeCommand` accepts only these, so denied opcodes cannot be built.
public enum SafeCommand: UInt8, Sendable, CaseIterable {
    case toggleRealtimeHR = 3
    case setClock = 10
    case getClock = 11
    case toggleHRBroadcast = 14
    case sendHistoricalData = 22
    case historicalDataResult = 23
    case getBatteryLevel = 26
    /// SET_READ_POINTER (cmd 33, 0x21). Rewinds/positions the strap's persistent read cursor
    /// (OpenStrap PROTOCOL.md §2, §4.3: "the cursor can be repositioned with SET_READ_POINTER";
    /// the cursor survives connections and acks, so a rewind enables re-reading the whole stored
    /// history after the app's database is deleted). See `BandCommand.setReadPointer(offset:)`.
    case setReadPointer = 33
    case getDataRange = 34
    /// SEND_R10_R11_REALTIME (cmd 63). Toggles the strap's realtime-raw flood: REALTIME_RAW_DATA
    /// (type 0x2B) raw accel/PPG samples at ~1.9 KB/s on `61080005` (PLAN.md 7.2 step 4,
    /// whoop-parity §3.4). Sourced from NOOP [S12]; no Icarus capture shows a cmd-63 frame yet.
    case sendR10R11Realtime = 63
    case setAlarmTime = 66
    case getAlarmTime = 67
    case runHapticsPattern = 79
    case getAllHapticsPatterns = 80
    /// GET_HELLO (cmd 35). The identity/version hello the official app sends first on each link.
    /// Verified as part of the working connect handshake by the NOOP project (iOS/CoreBluetooth).
    case getHello = 35
    case stopHaptics = 122

    /// Never sent (PLAN.md 5.3.5): FORCE_TRIM 25, REBOOT_STRAP 29, TOGGLE_PERSISTENT_R21 154,
    /// TOGGLE_OPTICAL_MODE 108, SET_RESEARCH_PACKET 131.
    public static let deniedOpcodes: Set<UInt8> = [25, 29, 154, 108, 131]
}
