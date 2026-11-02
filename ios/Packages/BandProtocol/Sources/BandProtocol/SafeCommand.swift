/// Commands Icarus may send to the band (PLAN.md 5.3.4, decimal opcodes).
/// `FrameCodec.encodeCommand` accepts only these, so denied opcodes cannot be built.
public enum SafeCommand: UInt8, Sendable, CaseIterable {
    /// LINK_VALID (cmd 1). Periodic link keep-alive while the custom service is ready (whoop-parity
    /// §3.8). Payload and reply behaviour are [Unverified] beyond NOOP's use.
    case linkValid = 1
    case toggleRealtimeHR = 3
    case setClock = 10
    case getClock = 11
    case toggleHRBroadcast = 14
    /// ABORT_HISTORICAL_TRANSMITS (cmd 20, 0x14). Ends the strap's current history-transmit session
    /// ("cancel sync"); non-destructive. OpenStrap's client sends it with `[0x00]` when a sync goes idle.
    /// UNUSED by the app: it was tried before a read-cursor rewind and changed nothing (2026-10-30
    /// hardware finding), so no caller sends it. Kept for the protocol surface and its tests.
    case abortHistoricalTransmits = 20
    case sendHistoricalData = 22
    case historicalDataResult = 23
    case getBatteryLevel = 26
    /// GET_EXTENDED_BATTERY_INFO (cmd 98). Read alongside cmd 26 on the 10-minute battery limiter
    /// (whoop-parity §3.7). Reply layout is [Unverified]; the controller logs it raw.
    case getExtendedBatteryInfo = 98
    /// SET_READ_POINTER (cmd 33, 0x21). Positions the strap's persistent read cursor. UNUSED by the app:
    /// the band accepts it and the GET_DATA_RANGE cursor word takes the new value, but the next drain
    /// still streams from the strap's internal position, so a rewind re-reads nothing (2026-10-30
    /// hardware finding). Kept for the protocol surface and its tests. See `BandCommand.setReadPointer(offset:)`.
    case setReadPointer = 33
    case getDataRange = 34
    /// SEND_R10_R11_REALTIME (cmd 63). Toggles the strap's realtime-raw flood: REALTIME_RAW_DATA
    /// (type 0x2B) raw accel/PPG samples at ~1.9 KB/s on `61080005` (PLAN.md 7.2 step 4,
    /// whoop-parity §3.4). Sourced from NOOP [S12]; no Icarus capture shows a cmd-63 frame yet.
    case sendR10R11Realtime = 63
    /// ENABLE_OPTICAL_DATA (cmd 107, 0x6B). Opens the optical data path into the realtime-raw stream, leaving the
    /// band's own wrist gating to decide when the LEDs run (OpenStrap research `enable_live_streams`, its default).
    /// Payload `[0x01 revision, 0x01 on | 0x00 off]`. Its siblings stay denied: TOGGLE_OPTICAL_MODE 108 forces the
    /// LEDs on, and TOGGLE_PERSISTENT_R21 154 keeps them forced on across reboots (OpenStrap's stuck-LED footgun).
    case enableOpticalData = 107
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
