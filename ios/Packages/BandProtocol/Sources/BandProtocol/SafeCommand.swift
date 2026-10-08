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
    case getDataRange = 34
    case setAlarmTime = 66
    case getAlarmTime = 67
    case runHapticsPattern = 79
    case getAllHapticsPatterns = 80
    case stopHaptics = 122

    /// Never sent (PLAN.md 5.3.5): FORCE_TRIM 25, REBOOT_STRAP 29, TOGGLE_PERSISTENT_R21 154,
    /// TOGGLE_OPTICAL_MODE 108, SET_RESEARCH_PACKET 131.
    public static let deniedOpcodes: Set<UInt8> = [25, 29, 154, 108, 131]
}
