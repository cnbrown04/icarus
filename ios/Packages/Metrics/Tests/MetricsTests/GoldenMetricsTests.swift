import Foundation
import Testing
@testable import Metrics

// Shared with the Rust core (shared/golden/metrics_v1.json, format documented in shared/golden/README.md).
@Suite("Golden metrics (shared/golden/metrics_v1.json)")
struct GoldenMetricsTests {
    private struct GoldenFile: Decodable {
        let formatVersion: Int
        let algoVersion: AlgoJSON
        let tolerance: Double
        let rrCases: [RRCase]
        let kcalCases: [KcalCase]
    }

    private struct AlgoJSON: Decodable {
        let hr: Int
        let hrv: Int
        let stress: Int
        let kcal: Int
    }

    private struct RRCase: Decodable {
        let name: String
        let rrMs: [Double]
        let expected: RRExpected
    }

    private struct RRExpected: Decodable {
        let rrAccepted: [Bool]
        let rmssd: Double?
        let sdnn: Double?
        let lnRmssd: Double?
    }

    private struct KcalCase: Decodable {
        let name: String
        let profile: ProfileJSON
        let restingHr: Double
        let maxHr: Double
        let hrBpm: [Double?]
        let expected: KcalExpected
    }

    private struct ProfileJSON: Decodable {
        let sex: String
        let ageYears: Int
        let heightCm: Double
        let weightKg: Double
    }

    private struct KcalExpected: Decodable {
        let hrFlex: Double
        let bmrKcalMin: Double
        let kcalMin: [Double]
        let activeKcalMin: [Double]
        let estimated: [Bool]
    }

    private func loadGolden() throws -> GoldenFile {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GoldenFile.self, from: GoldenFixture.data())
    }

    private func close(_ actual: Double?, _ expected: Double?, tolerance: Double) -> Bool {
        switch (actual, expected) {
        case (nil, nil): return true
        case let (a?, e?): return abs(a - e) <= tolerance
        default: return false
        }
    }

    @Test func algoVersionMatchesCode() throws {
        let golden = try loadGolden()
        #expect(golden.formatVersion == 1)
        #expect(golden.algoVersion.hr == AlgoVersion.current.hr)
        #expect(golden.algoVersion.hrv == AlgoVersion.current.hrv)
        #expect(golden.algoVersion.stress == AlgoVersion.current.stress)
        #expect(golden.algoVersion.kcal == AlgoVersion.current.kcal)
    }

    @Test func rrCasesMatch() throws {
        let golden = try loadGolden()
        #expect(!golden.rrCases.isEmpty)
        for c in golden.rrCases {
            let flags = RRCleaner.acceptedFlags(c.rrMs)
            #expect(flags == c.expected.rrAccepted, "\(c.name): accepted flags")

            let accepted = zip(c.rrMs, flags).compactMap { $1 ? $0 : nil }
            let rmssd = HRV.rmssd(accepted)
            let sdnn = HRV.sdnn(accepted)
            let lnRmssd = HRV.lnRMSSD(accepted)
            #expect(close(rmssd, c.expected.rmssd, tolerance: golden.tolerance), "\(c.name): rmssd")
            #expect(close(sdnn, c.expected.sdnn, tolerance: golden.tolerance), "\(c.name): sdnn")
            #expect(close(lnRmssd, c.expected.lnRmssd, tolerance: golden.tolerance), "\(c.name): lnRMSSD")
        }
    }

    @Test func kcalCasesMatch() throws {
        let golden = try loadGolden()
        #expect(!golden.kcalCases.isEmpty)
        for c in golden.kcalCases {
            let sex: FormulaSex = c.profile.sex == "male" ? .male : .female
            let profile = UserProfile(
                sex: sex,
                ageYears: c.profile.ageYears,
                heightCm: c.profile.heightCm,
                weightKg: c.profile.weightKg
            )
            let tol = golden.tolerance

            #expect(abs(Calories.heartRateFlex(restingHR: c.restingHr, maxHR: c.maxHr) - c.expected.hrFlex) <= tol,
                    "\(c.name): hr_flex")
            #expect(abs(Calories.mifflinBMRPerMinute(profile) - c.expected.bmrKcalMin) <= tol,
                    "\(c.name): bmr_kcal_min")

            for (i, hr) in c.hrBpm.enumerated() {
                let minute = Calories.minuteEnergy(
                    heartRate: hr, profile: profile, restingHR: c.restingHr, maxHR: c.maxHr
                )
                #expect(abs(minute.kcal - c.expected.kcalMin[i]) <= tol, "\(c.name): kcal_min[\(i)]")
                #expect(abs(minute.activeKcal - c.expected.activeKcalMin[i]) <= tol,
                        "\(c.name): active_kcal_min[\(i)]")
                #expect(minute.estimated == c.expected.estimated[i], "\(c.name): estimated[\(i)]")
            }
        }
    }
}
