import BandKit
import Foundation

/// The Experimental band channel switch (PLAN.md 6.2, 19 Phase 6). Off by default. The stored value is the only thing
/// that turns Tier B on at launch, so an unset or off switch sends no custom-service traffic.
enum BandChannel {
    static let storageKey = "band.tierB.enabled"
    static let floodDisabledKey = "band.floodDisabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: storageKey)
    }

    /// Whether handshakes disable the strap's raw accel/PPG flood (0x3F `[0x00]`). Default false:
    /// OpenStrap's verified reference never sends it, the off form is unverified, and on this strap
    /// the disable coincided with hours of missing banked history (2026-10-18/19).
    static var floodDisabled: Bool {
        UserDefaults.standard.bool(forKey: floodDisabledKey)
    }
}

/// A transport whose Tier B controller can toggle the REALTIME_RAW_DATA (0x2B) flood, so the
/// raw-data viewer can show "2B raw" rows. The intended implementation is BandKit's
/// `TierBController.setRealtimeRawFlood(enabled:)`, reached through the transport. Declared in the
/// app because BandKit does not know the viewer: the viewer feature-detects with an `as?`, so a
/// transport without the capability (or before BandKit's call site lands) is a logged no-op, not a
/// build break.
protocol RealtimeRawFloodTransport: BandTransport {
    func setRealtimeRawFlood(enabled: Bool) async throws
    func setHandshakeRealtimeRawFloodDisabled(_ disabled: Bool) async throws
}

// The transport-level bridge lives in BandKit (`CoreBluetoothTransport.setRealtimeRawFlood`),
// which delegates to `TierBController.setRealtimeRawFlood(enabled:)`. With this conformance the
// `as?` in `LiveState.setRealtimeRawFlood` matches and RawDataView's flood wiring is live.
extension CoreBluetoothTransport: RealtimeRawFloodTransport {}
