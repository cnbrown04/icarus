import Foundation

/// The Experimental band channel switch (PLAN.md 6.2, 19 Phase 6). Off by default. The stored value is the only thing
/// that turns Tier B on at launch, so an unset or off switch sends no custom-service traffic.
enum BandChannel {
    static let storageKey = "band.tierB.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: storageKey)
    }
}
