import Foundation
import Testing
@testable import Metrics

// Sections of shared/golden/metrics_v1.json added for PLAN.md 8. Column order is in shared/golden/README.md.
@Suite("Golden pipeline sections (shared/golden/metrics_v1.json, PLAN.md 8)")
struct GoldenPipelineTests {
    private struct Golden: Decodable {
        let tolerance: Double
        let minuteCases: [MinuteCase]
        let rhrCases: [RHRCase]
        let hrmaxCases: [HRmaxCase]
        let hrrCases: [HRRCase]
        let windowCases: [WindowCase]
        let baevskyCases: [BaevskyCase]
        let stressCases: [StressCase]
        let minuteMetricCases: [MinuteMetricCase]
    }

    private struct MinuteCase: Decodable {
        let name: String
        let samples: [SampleRow]
        let expected: Minutes

        struct Minutes: Decodable { let minutes: [MinuteJSON] }
    }

    private struct MinuteJSON: Decodable {
        let minuteMs: Int64
        let hrAvg: Double
        let hrMin: Int
        let hrMax: Int
        let hrN: Int
        let coverage: Double
    }

    private struct RHRCase: Decodable {
        let name: String
        let localDay: DayJSON
        let tz: String
        let minutes: [MinuteRow]
        let expected: Expected

        struct Expected: Decodable { let rhr: Double? }
    }

    private struct HRmaxCase: Decodable {
        let name: String
        let ageYears: Int
        let userHrMax: Int?
        let expected: Expected

        struct Expected: Decodable { let hrMax: Double }
    }

    private struct HRRCase: Decodable {
        let name: String
        let hr: Double
        let restingHr: Double
        let maxHr: Double
        let expected: Expected

        struct Expected: Decodable {
            let hrrFraction: Double?
            let zone: String?
            let exertion: Bool
        }
    }

    private struct WindowCase: Decodable {
        let name: String
        let samples: [SampleRow]
        let rr: [RRRow]
        let rangeStartMs: Int64
        let rangeEndMs: Int64
        let expected: Expected

        struct Expected: Decodable { let windows: [WindowJSON] }
    }

    private struct WindowJSON: Decodable {
        let startMs: Int64
        let hrMean: Double?
        let rrCount: Int
        let rrSumMs: Double
        let valid: Bool
        let rmssd: Double?
        let sdnn: Double?
        let lnRmssd: Double?
        let baevskySqrt: Double?
    }

    private struct BaevskyCase: Decodable {
        let name: String
        let rrMs: [Double]
        let expected: Expected

        struct Expected: Decodable {
            let si: Double?
            let sqrtSi: Double?
        }
    }

    private struct StressCase: Decodable {
        let name: String
        let day: DayJSON
        let tz: String
        let restingHr: Double?
        let maxHr: Double
        let history: [WindowRow]
        let current: WindowRow
        let expected: Expected

        struct Expected: Decodable {
            let validDays: Int
            let hrOnlyDays: Int
            let hrMedian: Double?
            let hrMad: Double?
            let lnRmssdMedian: Double?
            let lnRmssdMad: Double?
            let hrOnlyMedian: Double?
            let hrOnlyMad: Double?
            let stress: Int?
            let state: String
        }
    }

    private struct MinuteMetricCase: Decodable {
        let name: String
        let tz: String
        let day: DayJSON
        let rangeStartMs: Int64
        let rangeEndMs: Int64
        let profile: ProfileJSON
        let restingHr: Double?
        let maxHr: Double
        let history: [WindowRow]
        let samples: [SampleRow]
        let rr: [RRRow]
        let expected: Expected

        struct Expected: Decodable { let rows: [RowJSON] }
    }

    private struct RowJSON: Decodable {
        let minuteMs: Int64
        let hrAvg: Double?
        let hrMin: Int?
        let hrMax: Int?
        let hrN: Int
        let rmssdMs: Double?
        let sdnnMs: Double?
        let baevskySqrt: Double?
        let stress: Int?
        let stressState: String
        let kcal: Double
        let activeKcal: Double
        let kcalEstimated: Bool
    }

    private struct DayJSON: Decodable {
        let year: Int
        let month: Int
        let day: Int

        var localDay: LocalDay { LocalDay(year: year, month: month, day: day) }
    }

    private struct ProfileJSON: Decodable {
        let sex: String
        let ageYears: Int
        let heightCm: Double
        let weightKg: Double

        var profile: UserProfile {
            UserProfile(
                sex: sex == "male" ? .male : .female,
                ageYears: ageYears,
                heightCm: heightCm,
                weightKg: weightKg
            )
        }
    }

    /// [ts_ms, bpm, contact]. Contact is "detected", "not_detected" or null (unknown).
    private struct SampleRow: Decodable {
        let sample: HeartRateSample

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let tsMs = try row.decode(Int64.self)
            let bpm = try row.decode(Int.self)
            let contact = try row.decode(String?.self)
            let mapped: SensorContact? = switch contact {
            case "detected": .detected
            case "not_detected": .notDetected
            default: nil
            }
            sample = HeartRateSample(tsMs: tsMs, bpm: bpm, contact: mapped)
        }
    }

    /// [minute_ms, hr_avg, hr_n]
    private struct MinuteRow: Decodable {
        let minute: MinuteAggregate

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let minuteMs = try row.decode(Int64.self)
            let hrAvg = try row.decode(Double.self)
            let hrN = try row.decode(Int.self)
            minute = MinuteAggregate(minuteMs: minuteMs, hrAvg: hrAvg, hrMin: 0, hrMax: 0, hrN: hrN)
        }
    }

    /// [ts_ms, rr_ms]
    private struct RRRow: Decodable {
        let sample: RRSample

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let tsMs = try row.decode(Int64.self)
            let rrMs = try row.decode(Double.self)
            sample = RRSample(tsMs: tsMs, rrMs: rrMs)
        }
    }

    /// [start_ms, hr_mean, valid, ln_rmssd]
    private struct WindowRow: Decodable {
        let window: FiveMinuteWindow

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let startMs = try row.decode(Int64.self)
            let hrMean = try row.decode(Double?.self)
            let valid = try row.decode(Bool.self)
            let lnRmssd = try row.decode(Double?.self)
            window = FiveMinuteWindow(
                startMs: startMs,
                hrMean: hrMean,
                // Only the stress fields are read from these rows. R-R counts are not needed.
                rrCount: 0,
                rrSumMs: valid ? FiveMinuteWindows.minValidRRSumMs : 0,
                valid: valid,
                rmssd: nil,
                sdnn: nil,
                lnRmssd: lnRmssd,
                baevskySqrt: nil
            )
        }
    }

    private func load() throws -> Golden {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: GoldenFixture.data())
    }

    private func expectClose(_ actual: Double?, _ expected: Double?, tolerance: Double, _ label: String) {
        switch (actual, expected) {
        case (nil, nil):
            return
        case let (a?, e?):
            #expect(abs(a - e) <= tolerance, "\(label): \(a) vs \(e)")
        default:
            Issue.record("\(label): \(String(describing: actual)) vs \(String(describing: expected))")
        }
    }

    private func timeZone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    @Test func minuteAggregationMatches() throws {
        let golden = try load()
        #expect(!golden.minuteCases.isEmpty)
        for c in golden.minuteCases {
            let got = MinuteAggregation.aggregate(c.samples.map(\.sample))
            #expect(got.count == c.expected.minutes.count, "\(c.name): minute count")
            for (g, e) in zip(got, c.expected.minutes) {
                #expect(g.minuteMs == e.minuteMs, "\(c.name): minute_ms")
                expectClose(g.hrAvg, e.hrAvg, tolerance: golden.tolerance, "\(c.name): hr_avg")
                #expect(g.hrMin == e.hrMin, "\(c.name): hr_min")
                #expect(g.hrMax == e.hrMax, "\(c.name): hr_max")
                #expect(g.hrN == e.hrN, "\(c.name): hr_n")
                expectClose(g.coverage, e.coverage, tolerance: golden.tolerance, "\(c.name): coverage")
            }
        }
    }

    @Test func restingHRMatches() throws {
        let golden = try load()
        #expect(golden.rhrCases.count >= 5)
        for c in golden.rhrCases {
            let tz = try timeZone(c.tz)
            let got = RestingHR.forNight(of: c.localDay.localDay, minutes: c.minutes.map(\.minute), in: tz)
            expectClose(got, c.expected.rhr, tolerance: golden.tolerance, "\(c.name): rhr")
        }
    }

    @Test func hrMaxMatches() throws {
        let golden = try load()
        for c in golden.hrmaxCases {
            let got = HeartRateZones.maxHR(userEntered: c.userHrMax, ageYears: c.ageYears)
            expectClose(got, c.expected.hrMax, tolerance: golden.tolerance, "\(c.name): hr_max")
        }
    }

    @Test func hrrAndZonesMatch() throws {
        let golden = try load()
        for c in golden.hrrCases {
            let fraction = HeartRateZones.hrrFraction(hr: c.hr, restingHR: c.restingHr, maxHR: c.maxHr)
            expectClose(fraction, c.expected.hrrFraction, tolerance: golden.tolerance, "\(c.name): hrr")
            let zone = fraction.map { String(describing: HeartRateZone.of(hrrFraction: $0)) }
            #expect(zone == c.expected.zone, "\(c.name): zone")
            let exertion = HeartRateZones.isExertion(hr: c.hr, restingHR: c.restingHr, maxHR: c.maxHr)
            #expect(exertion == c.expected.exertion, "\(c.name): exertion")
        }
    }

    @Test func windowsMatch() throws {
        let golden = try load()
        for c in golden.windowCases {
            let got = FiveMinuteWindows.build(
                samples: c.samples.map(\.sample),
                rr: c.rr.map(\.sample),
                range: c.rangeStartMs..<c.rangeEndMs
            )
            #expect(got.count == c.expected.windows.count, "\(c.name): window count")
            for (g, e) in zip(got, c.expected.windows) {
                let label = "\(c.name) start \(e.startMs)"
                #expect(g.startMs == e.startMs, "\(label): start")
                expectClose(g.hrMean, e.hrMean, tolerance: golden.tolerance, "\(label): hr_mean")
                #expect(g.rrCount == e.rrCount, "\(label): rr_count")
                expectClose(g.rrSumMs, e.rrSumMs, tolerance: golden.tolerance, "\(label): rr_sum_ms")
                #expect(g.valid == e.valid, "\(label): valid")
                expectClose(g.rmssd, e.rmssd, tolerance: golden.tolerance, "\(label): rmssd")
                expectClose(g.sdnn, e.sdnn, tolerance: golden.tolerance, "\(label): sdnn")
                expectClose(g.lnRmssd, e.lnRmssd, tolerance: golden.tolerance, "\(label): ln_rmssd")
                expectClose(g.baevskySqrt, e.baevskySqrt, tolerance: golden.tolerance, "\(label): baevsky_sqrt")
            }
        }
    }

    @Test func baevskyMatches() throws {
        let golden = try load()
        for c in golden.baevskyCases {
            let si = Baevsky.stressIndex(rrMs: c.rrMs)
            let sqrtSi = Baevsky.sqrtStressIndex(rrMs: c.rrMs)
            expectClose(si, c.expected.si, tolerance: golden.tolerance, "\(c.name): si")
            expectClose(sqrtSi, c.expected.sqrtSi, tolerance: golden.tolerance, "\(c.name): sqrt_si")
        }
    }

    @Test func stressMatches() throws {
        let golden = try load()
        #expect(golden.stressCases.count == 6)
        for c in golden.stressCases {
            let tz = try timeZone(c.tz)
            let baseline = StressBaseline.build(
                windows: c.history.map(\.window),
                day: c.day.localDay,
                in: tz,
                restingHR: c.restingHr,
                maxHR: c.maxHr
            )
            let e = c.expected
            #expect(baseline.validDays == e.validDays, "\(c.name): valid_days")
            #expect(baseline.hrOnlyDays == e.hrOnlyDays, "\(c.name): hr_only_days")
            expectClose(baseline.hrMedian, e.hrMedian, tolerance: golden.tolerance, "\(c.name): hr_median")
            expectClose(baseline.hrMAD, e.hrMad, tolerance: golden.tolerance, "\(c.name): hr_mad")
            expectClose(baseline.lnRmssdMedian, e.lnRmssdMedian, tolerance: golden.tolerance, "\(c.name): ln_median")
            expectClose(baseline.lnRmssdMAD, e.lnRmssdMad, tolerance: golden.tolerance, "\(c.name): ln_mad")
            expectClose(baseline.hrOnlyMedian, e.hrOnlyMedian, tolerance: golden.tolerance, "\(c.name): hr_only_median")
            expectClose(baseline.hrOnlyMAD, e.hrOnlyMad, tolerance: golden.tolerance, "\(c.name): hr_only_mad")

            let result = Stress.score(
                window: c.current.window,
                restingHR: c.restingHr,
                maxHR: c.maxHr,
                baseline: baseline
            )
            #expect(result.state.rawValue == e.state, "\(c.name): state")
            #expect(result.stress == e.stress, "\(c.name): stress")
        }
    }

    @Test func minuteMetricsMatch() throws {
        let golden = try load()
        #expect(golden.minuteMetricCases.count == 3)
        for c in golden.minuteMetricCases {
            let tz = try timeZone(c.tz)
            let baseline = StressBaseline.build(
                windows: c.history.map(\.window),
                day: c.day.localDay,
                in: tz,
                restingHR: c.restingHr,
                maxHR: c.maxHr
            )
            let context = MinuteMetricsContext(
                profile: c.profile.profile,
                restingHR: c.restingHr,
                maxHR: c.maxHr,
                baseline: baseline
            )
            let rows = MinuteMetricsCalculator.rows(
                range: c.rangeStartMs..<c.rangeEndMs,
                samples: c.samples.map(\.sample),
                rr: c.rr.map(\.sample),
                context: context
            )
            #expect(rows.count == c.expected.rows.count, "\(c.name): row count")
            for (g, e) in zip(rows, c.expected.rows) {
                let label = "\(c.name) minute \(e.minuteMs)"
                #expect(g.minuteMs == e.minuteMs, "\(label): minute_ms")
                expectClose(g.hrAvg, e.hrAvg, tolerance: golden.tolerance, "\(label): hr_avg")
                #expect(g.hrMin == e.hrMin, "\(label): hr_min")
                #expect(g.hrMax == e.hrMax, "\(label): hr_max")
                #expect(g.hrN == e.hrN, "\(label): hr_n")
                expectClose(g.rmssdMs, e.rmssdMs, tolerance: golden.tolerance, "\(label): rmssd")
                expectClose(g.sdnnMs, e.sdnnMs, tolerance: golden.tolerance, "\(label): sdnn")
                expectClose(g.baevskySqrt, e.baevskySqrt, tolerance: golden.tolerance, "\(label): baevsky")
                #expect(g.stress == e.stress, "\(label): stress")
                #expect(g.stressState.rawValue == e.stressState, "\(label): stress_state")
                expectClose(g.kcal, e.kcal, tolerance: golden.tolerance, "\(label): kcal")
                expectClose(g.activeKcal, e.activeKcal, tolerance: golden.tolerance, "\(label): active_kcal")
                #expect(g.kcalEstimated == e.kcalEstimated, "\(label): kcal_estimated")
            }
        }
    }
}
