import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// 2026-10-07T14:30:00Z, a minute boundary.
let testNowMs: Int64 = 1_791_383_400_000
let chicago = TimeZone(identifier: "America/Chicago")!
let testPeripheral = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!

let testProfile = UserProfile(sex: .male, ageYears: 36, heightCm: 178, weightKg: 80)

let emptyBaseline = StressBaseline(
    validDays: 0,
    hrMedian: nil,
    hrMAD: nil,
    lnRmssdMedian: nil,
    lnRmssdMAD: nil,
    hrOnlyDays: 0,
    hrOnlyMedian: nil,
    hrOnlyMAD: nil
)

func seededDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try database.writer.write { db in
        try db.saveProfile(
            ProfileRow(formulaSex: "male", birthYear: 1990, heightCm: 178, weightKg: 80, tz: chicago.identifier),
            atMs: testNowMs
        )
        try db.upsertBand(peripheralUUID: testPeripheral, name: "Band", seenAtMs: testNowMs)
    }
    return database
}

/// A minute row with the fields the query tests care about. Other columns are plausible constants.
func minuteRow(
    _ minuteMs: Int64,
    hr: Double? = 60,
    hrN: Int = 60,
    kcal: Double = 1,
    activeKcal: Double = 0,
    stress: Int? = nil,
    rmssd: Double? = nil,
    syncRev: Int64 = 1
) -> MinuteMetricRow {
    MinuteMetricRow(
        minuteMs: minuteMs,
        hrAvg: hr,
        hrMin: hr.map { Int($0) - 2 },
        hrMax: hr.map { Int($0) + 3 },
        hrN: hrN,
        rmssdMs: rmssd,
        sdnnMs: nil,
        baevskySqrt: nil,
        stress: stress,
        stressState: stress == nil ? StressState.insufficient.rawValue : StressState.value.rawValue,
        kcal: kcal,
        activeKcal: activeKcal,
        kcalEstimated: hr == nil,
        algoVersion: 1,
        computedAt: 0,
        syncRev: syncRev
    )
}

func insertMinuteRows(_ rows: [MinuteMetricRow], into database: AppDatabase) throws {
    _ = try database.writer.write { db in
        for row in rows {
            try row.insert(db)
        }
    }
}

/// Calculator output for a range with the given samples. Gives real `MinuteMetric` values.
func calculatedMinutes(
    from start: Int64,
    count: Int,
    bpm: Int
) -> [MinuteMetric] {
    let samples = (0..<(count * 60)).map { HeartRateSample(tsMs: start + Int64($0) * 1000, bpm: bpm) }
    return MinuteMetricsCalculator.rows(
        range: start..<(start + Int64(count) * LocalTime.msPerMinute),
        samples: samples,
        rr: [],
        context: MinuteMetricsContext(profile: testProfile, restingHR: 55, maxHR: 183, baseline: emptyBaseline)
    )
}

/// `#require` on a plain value. Lets tests unwrap a result of a mutating call without a macro around it.
func required(_ reading: Database.Reading?) throws -> Database.Reading {
    try #require(reading)
}
