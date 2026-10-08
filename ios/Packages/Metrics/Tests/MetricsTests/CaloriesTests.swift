import Testing
@testable import Metrics

@Suite("Calories: Mifflin-St Jeor, Keytel, per-minute rule")
struct CaloriesTests {
    private let maleProfile = UserProfile(sex: .male, ageYears: 40, heightCm: 180, weightKg: 80)
    private let femaleProfile = UserProfile(sex: .female, ageYears: 30, heightCm: 160, weightKg: 60)

    @Test func mifflinMaleHandComputed() {
        // 10 * 80 + 6.25 * 180 - 5 * 40 + 5 = 800 + 1125 - 200 + 5 = 1730 kcal/day.
        #expect(Calories.mifflinBMRPerDay(maleProfile) == 1730)
        // 1730 / 1440 = 1.2013888...
        #expect(abs(Calories.mifflinBMRPerMinute(maleProfile) - 1730.0 / 1440.0) < 1e-12)
    }

    @Test func mifflinFemaleHandComputed() {
        // 10 * 60 + 6.25 * 160 - 5 * 30 - 161 = 600 + 1000 - 150 - 161 = 1289 kcal/day.
        #expect(Calories.mifflinBMRPerDay(femaleProfile) == 1289)
    }

    @Test func keytelMaleHandComputed() {
        // EE_kJ = -55.0969 + 0.6309 * 120 + 0.1988 * 80 + 0.2017 * 40
        //       = -55.0969 + 75.708 + 15.904 + 8.068 = 44.5831 kJ/min.
        // kcal = 44.5831 / 4.184 = 10.655617...
        let kj = Calories.keytelKJPerMinute(maleProfile, heartRate: 120)
        #expect(abs(kj - 44.5831) < 1e-9)
        #expect(abs(Calories.keytelKcalPerMinute(maleProfile, heartRate: 120) - 44.5831 / 4.184) < 1e-9)
    }

    @Test func keytelFemaleHandComputed() {
        // EE_kJ = -20.4022 + 0.4472 * 140 - 0.1263 * 60 + 0.074 * 30
        //       = -20.4022 + 62.608 - 7.578 + 2.22 = 36.8478 kJ/min.
        let kj = Calories.keytelKJPerMinute(femaleProfile, heartRate: 140)
        #expect(abs(kj - 36.8478) < 1e-9)
    }

    @Test func heartRateFlexUsesFormula() {
        // RHR 60, HRmax 190: 60 + 0.30 * 130 = 99. max(90, 99) = 99.
        #expect(abs(Calories.heartRateFlex(restingHR: 60, maxHR: 190) - 99) < 1e-12)
    }

    @Test func heartRateFlexFloorsAt90() {
        // RHR 50, HRmax 150: 50 + 0.30 * 100 = 80. max(90, 80) = 90.
        #expect(Calories.heartRateFlex(restingHR: 50, maxHR: 150) == 90)
    }

    @Test func minuteBelowFlexUsesRestingRate() {
        // HR 80 < HR_flex 99, so the minute is charged at BMR per minute with no active kcal.
        let minute = Calories.minuteEnergy(heartRate: 80, profile: maleProfile, restingHR: 60, maxHR: 190)
        #expect(!minute.estimated)
        #expect(abs(minute.kcal - 1730.0 / 1440.0) < 1e-12)
        #expect(minute.activeKcal == 0)
    }

    @Test func minuteAboveFlexUsesKeytel() {
        // HR 120 >= 99. Keytel gives 10.655617 kcal, which is above BMR 1.201389.
        let minute = Calories.minuteEnergy(heartRate: 120, profile: maleProfile, restingHR: 60, maxHR: 190)
        #expect(!minute.estimated)
        #expect(abs(minute.kcal - 44.5831 / 4.184) < 1e-9)
        #expect(abs(minute.activeKcal - (44.5831 / 4.184 - 1730.0 / 1440.0)) < 1e-9)
    }

    @Test func missingHeartRateIsEstimatedAtRestingRate() {
        let minute = Calories.minuteEnergy(heartRate: nil, profile: maleProfile, restingHR: 60, maxHR: 190)
        #expect(minute.estimated)
        #expect(abs(minute.kcal - 1730.0 / 1440.0) < 1e-12)
        #expect(minute.activeKcal == 0)
    }
}
