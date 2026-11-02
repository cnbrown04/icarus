/// Event ids carried in the `cmd` byte of an EVENT (0x30) frame (PLAN.md 5.3.4 [S11][S12]).
///
/// Ids from PLAN.md are named, plus ids identified on this band by the in-app Band Tests runs (2026-11-01, two
/// runs: the event placed by the band's own timestamp against what the user was doing). Each identified id notes
/// its evidence. Everything else is `.unknown(id)`, so new firmware events are kept rather than dropped.
public enum BandEventKind: Sendable, Equatable {
    case batteryLevel             // 3
    case chargingOn               // 7
    case chargingOff              // 8
    case wristOn                  // 9
    case wristOff                 // 10
    /// 11: the second Bluetooth came back after being switched off in Control Center (one run, to the second).
    case bluetoothConnected
    /// 12: the second Bluetooth was switched off (one run, to the second).
    case bluetoothDisconnected
    case rtcLost                  // 13
    /// 14. Named "double tap" upstream; on this band it also fires for triple taps, the tap that stops an alarm and
    /// taking the band off, and missed three deliberate double taps. Treat it as "a tap gesture".
    case doubleTap
    /// 21: every time charging started, the same second as event 7 (4 of 4 across both runs).
    case chargingOnSecondReport
    /// 22: every time charging stopped, the same second as event 8 (4 of 4).
    case chargingOffSecondReport
    case bleBonded                // 23
    /// 32: at every band off and on, with a longer payload: a wear report.
    case wearReport
    /// 56: when the band's alarm is set; bytes 10–13 of the payload are the alarm time (it fired at exactly that
    /// second as event 57).
    case alarmSet
    case strapDrivenAlarmExecuted // 57
    case hapticsFired             // 60
    /// 63: with every battery report (event 3), the same second, 9 of 9; a longer battery and charging status.
    case batteryDetails
    /// 69: with wrist on, the same second (2 of 2).
    case wristOnSecondReport
    /// 100: after every buzz: 1 s after a short one, 5 s after a long one, 13 s after an alarm's.
    case hapticsFinished
    /// 102 and 103: at every band off and on, and when a cold pack was lifted off the band: a skin-contact change.
    case contactChange
    case contactChangeSecondReport
    case unknown(UInt8)

    public init(id: UInt8) {
        switch id {
        case 3: self = .batteryLevel
        case 7: self = .chargingOn
        case 8: self = .chargingOff
        case 9: self = .wristOn
        case 10: self = .wristOff
        case 11: self = .bluetoothConnected
        case 12: self = .bluetoothDisconnected
        case 13: self = .rtcLost
        case 14: self = .doubleTap
        case 21: self = .chargingOnSecondReport
        case 22: self = .chargingOffSecondReport
        case 23: self = .bleBonded
        case 32: self = .wearReport
        case 56: self = .alarmSet
        case 57: self = .strapDrivenAlarmExecuted
        case 60: self = .hapticsFired
        case 63: self = .batteryDetails
        case 69: self = .wristOnSecondReport
        case 100: self = .hapticsFinished
        case 102: self = .contactChange
        case 103: self = .contactChangeSecondReport
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
        case .bluetoothConnected: 11
        case .bluetoothDisconnected: 12
        case .rtcLost: 13
        case .doubleTap: 14
        case .chargingOnSecondReport: 21
        case .chargingOffSecondReport: 22
        case .bleBonded: 23
        case .wearReport: 32
        case .alarmSet: 56
        case .strapDrivenAlarmExecuted: 57
        case .hapticsFired: 60
        case .batteryDetails: 63
        case .wristOnSecondReport: 69
        case .hapticsFinished: 100
        case .contactChange: 102
        case .contactChangeSecondReport: 103
        case let .unknown(id): id
        }
    }

    /// Stable name for storage (`band_event.kind`): snake case for named ids, `event_<id>` otherwise. Rows stored
    /// as `event_<id>` before an id was named still decode to the named kind (`BandEventKind(id:)`).
    public var storageName: String {
        switch self {
        case .batteryLevel: "battery_level"
        case .chargingOn: "charging_on"
        case .chargingOff: "charging_off"
        case .wristOn: "wrist_on"
        case .wristOff: "wrist_off"
        case .bluetoothConnected: "bluetooth_connected"
        case .bluetoothDisconnected: "bluetooth_disconnected"
        case .rtcLost: "rtc_lost"
        case .doubleTap: "double_tap"
        case .chargingOnSecondReport: "charging_on_2"
        case .chargingOffSecondReport: "charging_off_2"
        case .bleBonded: "ble_bonded"
        case .wearReport: "wear_report"
        case .alarmSet: "alarm_set"
        case .strapDrivenAlarmExecuted: "alarm_executed"
        case .hapticsFired: "haptics_fired"
        case .batteryDetails: "battery_details"
        case .wristOnSecondReport: "wrist_on_2"
        case .hapticsFinished: "haptics_finished"
        case .contactChange: "contact_change"
        case .contactChangeSecondReport: "contact_change_2"
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
