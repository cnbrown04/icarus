import Testing
@testable import Metrics

@Suite("HeartRateZones: HRmax, HRR%, zones, exertion (PLAN.md 8.1, 8.2)")
struct HeartRateZonesTests {
    @Test func tanakaFallback() {
        // 208 - 0.7 * 40 = 208 - 28 = 180. 208 - 0.7 * 55 = 208 - 38.5 = 169.5.
        #expect(HeartRateZones.tanakaMaxHR(ageYears: 40) == 180)
        #expect(HeartRateZones.tanakaMaxHR(ageYears: 55) == 169.5)
    }

    @Test func userEnteredHRMaxWins() {
        #expect(HeartRateZones.maxHR(userEntered: 190, ageYears: 30) == 190)
        // Without a user value, 208 - 0.7 * 30 = 187.
        #expect(HeartRateZones.maxHR(userEntered: nil, ageYears: 30) == 187)
    }

    @Test func hrrFractionIsKarvonen() {
        // (120 - 60) / (180 - 60) = 60 / 120 = 0.5.
        #expect(HeartRateZones.hrrFraction(hr: 120, restingHR: 60, maxHR: 180) == 0.5)
    }

    @Test func hrrIsNilWithoutReserve() {
        #expect(HeartRateZones.hrrFraction(hr: 90, restingHR: 60, maxHR: 60) == nil)
        #expect(HeartRateZones.hrrFraction(hr: 90, restingHR: 70, maxHR: 60) == nil)
    }

    @Test func exertionIsStrictlyAboveForty() {
        // 108: (108 - 60) / 120 = 0.4, which is not above 0.40.
        #expect(!HeartRateZones.isExertion(hr: 108, restingHR: 60, maxHR: 180))
        // 109: 49 / 120 = 0.408, which is above 0.40.
        #expect(HeartRateZones.isExertion(hr: 109, restingHR: 60, maxHR: 180))
    }

    @Test func unknownInputsAreNotExertion() {
        #expect(!HeartRateZones.isExertion(hr: nil, restingHR: 60, maxHR: 180))
        #expect(!HeartRateZones.isExertion(hr: 170, restingHR: nil, maxHR: 180))
        #expect(!HeartRateZones.isExertion(hr: 170, restingHR: 60, maxHR: 60))
    }

    @Test func zoneBoundariesAreLowerInclusive() {
        #expect(HeartRateZone.of(hrrFraction: 0.49) == .below)
        #expect(HeartRateZone.of(hrrFraction: 0.5) == .zone1)
        #expect(HeartRateZone.of(hrrFraction: 0.6) == .zone2)
        #expect(HeartRateZone.of(hrrFraction: 0.7) == .zone3)
        #expect(HeartRateZone.of(hrrFraction: 0.8) == .zone4)
        #expect(HeartRateZone.of(hrrFraction: 0.9) == .zone5)
        #expect(HeartRateZone.of(hrrFraction: 1.2) == .zone5)
    }
}
