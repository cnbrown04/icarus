import Foundation
import Testing
@testable import Store

struct ProfileRowTests {
    /// Local time is the device's zone (CONTEXT.md lesson 8), so a profile built without an explicit zone
    /// must not default to a fixed one.
    @Test func defaultZoneIsTheDeviceZone() {
        #expect(ProfileRow().tz == TimeZone.current.identifier)
    }

    @Test func timeZoneUsesTheStoredIdentifier() {
        #expect(ProfileRow(tz: "Europe/Paris").timeZone.identifier == "Europe/Paris")
    }

    /// An unrecognised identifier falls back to the device zone, not a fixed one.
    @Test func unknownZoneFallsBackToTheDeviceZone() {
        #expect(ProfileRow(tz: "Not/AZone").timeZone == TimeZone.current)
    }
}
