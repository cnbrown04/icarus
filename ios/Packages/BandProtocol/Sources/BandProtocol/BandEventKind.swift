/// Event ids carried in the `cmd` byte of an EVENT (0x30) frame (PLAN.md 5.3.4 [S11][S12]).
///
/// Only ids in PLAN.md are named. Everything else is `.unknown(id)`, so new firmware events are
/// kept rather than dropped.
public enum BandEventKind: Sendable, Equatable {
    case batteryLevel             // 3
    case chargingOn               // 7
    case chargingOff              // 8
    case wristOn                  // 9
    case wristOff                 // 10
    case rtcLost                  // 13
    case doubleTap                // 14
    case bleBonded                // 23
    case strapDrivenAlarmExecuted // 57
    case hapticsFired             // 60
    case unknown(UInt8)

    public init(id: UInt8) {
        switch id {
        case 3: self = .batteryLevel
        case 7: self = .chargingOn
        case 8: self = .chargingOff
        case 9: self = .wristOn
        case 10: self = .wristOff
        case 13: self = .rtcLost
        case 14: self = .doubleTap
        case 23: self = .bleBonded
        case 57: self = .strapDrivenAlarmExecuted
        case 60: self = .hapticsFired
        default: self = .unknown(id)
        }
    }

    /// The event id this kind was decoded from.
    public var id: UInt8 {
        switch self {
        case .batteryLevel: 3
        case .chargingOn: 7
        case .chargingOff: 8
        case .wristOn: 9
        case .wristOff: 10
        case .rtcLost: 13
        case .doubleTap: 14
        case .bleBonded: 23
        case .strapDrivenAlarmExecuted: 57
        case .hapticsFired: 60
        case let .unknown(id): id
        }
    }

    /// Stable name for storage (`band_event.kind`): snake case for named ids, `event_<id>` otherwise.
    public var storageName: String {
        switch self {
        case .batteryLevel: "battery_level"
        case .chargingOn: "charging_on"
        case .chargingOff: "charging_off"
        case .wristOn: "wrist_on"
        case .wristOff: "wrist_off"
        case .rtcLost: "rtc_lost"
        case .doubleTap: "double_tap"
        case .bleBonded: "ble_bonded"
        case .strapDrivenAlarmExecuted: "alarm_executed"
        case .hapticsFired: "haptics_fired"
        case let .unknown(id): "event_\(id)"
        }
    }
}

public enum BandEventParser {
    /// Returns the event for an EVENT (0x30) frame, or nil for any other packet type.
    public static func parse(_ frame: Frame) -> BandEventKind? {
        guard frame.packetType == .event else { return nil }
        return BandEventKind(id: frame.cmd)
    }
}
