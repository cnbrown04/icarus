import BandProtocol

extension BandEventKind {
    /// What the Band page, the Event Log and Band Tests call this event. Unnamed ids read "Event 42" until a Band
    /// Tests run shows what they mean.
    var displayName: String {
        switch self {
        case .batteryLevel: "Battery level"
        case .chargingOn: "Charging on"
        case .chargingOff: "Charging off"
        case .wristOn: "Wrist on"
        case .wristOff: "Wrist off"
        case .rtcLost: "Clock reset"
        case .doubleTap: "Double tap"
        case .bleBonded: "Bonded"
        case .strapDrivenAlarmExecuted: "Alarm rang"
        case .hapticsFired: "Buzz"
        case let .unknown(id): "Event \(id)"
        }
    }

    /// The kind stored as `band_event.kind` (`storageName`), decoded back. Nil for a name this build does not know.
    init?(storageName: String) {
        if storageName.hasPrefix("event_"), let id = UInt8(storageName.dropFirst("event_".count)) {
            self = BandEventKind(id: id)
            return
        }
        guard let kind = (0...UInt8.max).lazy.map(BandEventKind.init(id:)).first(where: { $0.storageName == storageName })
        else { return nil }
        self = kind
    }
}
