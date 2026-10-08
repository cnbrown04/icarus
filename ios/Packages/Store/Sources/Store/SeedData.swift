import Foundation
import GRDB
import Metrics

/// Deterministic demo data for UI tests and screenshots (PLAN.md 16.3, `-IcarusSeedDB seed_30d`).
/// Same inputs, same rows: the generator has a fixed seed and no wall-clock reads.
public enum SeedData {
    public static let days = 30
    /// The first days are calibrating, so Stress shows its calibration state (PLAN.md 8.3).
    public static let calibrationDays = 6
    public static let bandPeripheralUUID = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!
    public static let bandName = "Fixture band"

    /// Builds an in-memory store with `days` of minute rows that end at the last closed minute before `now`,
    /// the last 15 minutes of raw heart-rate samples, a band row and a complete profile.
    /// The profile is male, born 1990, 178 cm, 80 kg, with HRmax from Tanaka.
    public static func make30Days(now: Date, timeZone: TimeZone = TimeZone(identifier: "America/Chicago")!) throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let end = LocalTime.roundDown(nowMs, to: LocalTime.msPerMinute)
        let start = end - Int64(days) * 1440 * LocalTime.msPerMinute
        let profile = ProfileRow(
            formulaSex: "male",
            birthYear: 1990,
            heightCm: 178,
            weightKg: 80,
            hrMax: nil,
            tz: timeZone.identifier
        )
        let year = LocalTime.localDay(containing: end, in: timeZone).year
        let userProfile = profile.userProfile(year: year)!
        let maxHR = HeartRateZones.maxHR(userEntered: nil, ageYears: userProfile.ageYears)
        let flex = Calories.heartRateFlex(restingHR: restingHeartRate, maxHR: maxHR)

        try database.writer.write { db in
            try db.saveProfile(profile, atMs: nowMs)
            try db.upsertBand(peripheralUUID: bandPeripheralUUID, name: bandName, seenAtMs: start)
            // One prepared statement for all rows. Per-row `insert` is several times slower in debug builds.
            let statement = try db.makeStatement(sql: """
            INSERT INTO minute_metric (minute_ms, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms, baevsky_sqrt,
              stress, stress_state, kcal, active_kcal, kcal_estimated, algo_version, computed_at, sync_rev)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            // The zone offset is read once. Only a DST change inside the 30 days would make it differ.
            let offsetMs = Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start) / 1000))) * 1000
            for index in 0..<(days * 1440) {
                let row = minuteRow(
                    index: index,
                    start: start,
                    offsetMs: offsetMs,
                    profile: userProfile,
                    flex: flex,
                    computedAt: nowMs
                )
                statement.setUncheckedArguments([
                    row.minuteMs, row.hrAvg, row.hrMin, row.hrMax, row.hrN, row.rmssdMs, row.sdnnMs,
                    row.baevskySqrt, row.stress, row.stressState, row.kcal, row.activeKcal,
                    row.kcalEstimated, row.algoVersion, row.computedAt, row.syncRev,
                ])
                try statement.execute()
            }
            var readings: [Database.Reading] = []
            var t = end - 15 * LocalTime.msPerMinute
            while t < nowMs {
                let localMinute = localMinuteOfDay(t, offsetMs: offsetMs)
                let dayIndex = Int((t - start) / (1440 * LocalTime.msPerMinute))
                var jitter = SplitMix64(seed: seed(t / 1000, salt: 0x51ED))
                let bpm = baseHeartRate(localMinute: localMinute, dayIndex: dayIndex) + (jitter.unit() - 0.5) * 3
                readings.append(Database.Reading(
                    peripheralUUID: bandPeripheralUUID,
                    tsMs: t,
                    bpm: Int(bpm.rounded()),
                    contact: true,
                    rr: []
                ))
                t += 1000
            }
            try db.insertReadings(readings)
        }
        return database
    }

    /// Resting heart rate the seed uses for the HR_flex floor.
    static let restingHeartRate = 55.0

    private static func minuteRow(
        index: Int,
        start: Int64,
        offsetMs: Int64,
        profile: UserProfile,
        flex: Double,
        computedAt: Int64
    ) -> MinuteMetricRow {
        let minuteMs = start + Int64(index) * LocalTime.msPerMinute
        let dayIndex = index / 1440
        let localMinute = localMinuteOfDay(minuteMs, offsetMs: offsetMs)
        let night = localMinute < 360

        var minuteRandom = SplitMix64(seed: seed(minuteMs / LocalTime.msPerMinute, salt: 0xA11CE))
        let gap = minuteRandom.unit() < 0.01
        let hr = baseHeartRate(localMinute: localMinute, dayIndex: dayIndex) + (minuteRandom.unit() - 0.5) * 4
        let hrAvg: Double? = gap ? nil : hr
        let hrMin: Int? = gap ? nil : Int(hr) - 2 - Int(minuteRandom.unit() * 3)
        let hrMax: Int? = gap ? nil : Int(hr) + 2 + Int(minuteRandom.unit() * 4)

        let windowStart = LocalTime.roundDown(minuteMs, to: LocalTime.msPerWindow)
        var windowRandom = SplitMix64(seed: seed(windowStart / LocalTime.msPerMinute, salt: 0x5EED))
        let valid = windowRandom.unit() > 0.05
        let u1 = windowRandom.unit()
        let u2 = windowRandom.unit()
        let u3 = windowRandom.unit()
        let rmssd: Double? = valid ? (night ? 52 + 16 * u1 : 30 + 12 * u1) : nil
        let stressCore = night ? 30 + 20 * u2 : 50 + 25 * u2

        var stress: Int? = Int(stressCore.rounded())
        var state: StressState = valid ? .value : .hrOnly
        if hr > 106 {
            // Above HRR 40% with the seed's resting HR (PLAN.md 8.2 step 4).
            stress = nil
            state = .exertion
        } else if gap {
            stress = nil
            state = .insufficient
        } else if dayIndex < calibrationDays {
            stress = nil
            state = .calibrating
        }

        let energy = Calories.minuteEnergy(heartRate: hrAvg, profile: profile, heartRateFlex: flex)
        return MinuteMetricRow(
            minuteMs: minuteMs,
            hrAvg: hrAvg,
            hrMin: hrMin,
            hrMax: hrMax,
            hrN: gap ? 0 : 60,
            rmssdMs: rmssd,
            sdnnMs: rmssd.map { $0 * (1.2 + 0.1 * u2) },
            baevskySqrt: valid ? (night ? 9 + 3 * u3 : 12 + 4 * u3) : nil,
            stress: stress,
            stressState: state.rawValue,
            kcal: energy.kcal,
            activeKcal: energy.activeKcal,
            kcalEstimated: energy.estimated,
            algoVersion: AlgoVersion.current.storedValue,
            computedAt: computedAt,
            syncRev: Int64(index + 1)
        )
    }

    /// Daily curve: a low, flat night and a daytime wave, with a 30-minute workout on alternate evenings.
    static func baseHeartRate(localMinute: Int, dayIndex: Int) -> Double {
        var base: Double
        if localMinute < 360 {
            base = 52 + 5 * sin(Double.pi * Double(localMinute) / 360)
        } else {
            base = 64 + 10 * sin(Double.pi * Double(localMinute - 360) / 1080)
        }
        if (1020..<1050).contains(localMinute), dayIndex % 2 == 0 {
            base += 45
        }
        // A 30-minute morning run every day. The screenshot clock is 09:30 local, so Today needs it to show zones 1-3.
        if (420..<450).contains(localMinute) {
            base += 30 + 60 * sin(Double.pi * Double(localMinute - 420) / 30)
        }
        return base
    }

    /// Minute of the local day (0-1439) for a fixed zone offset in ms.
    static func localMinuteOfDay(_ ms: Int64, offsetMs: Int64) -> Int {
        Int((((ms + offsetMs) / LocalTime.msPerMinute) % 1440 + 1440) % 1440)
    }

    private static func seed(_ value: Int64, salt: UInt64) -> UInt64 {
        UInt64(bitPattern: value) &* 0x9E37_79B9_7F4A_7C15 ^ salt
    }
}

/// Fixed-seed generator for the seed data. Not for anything that needs real randomness.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
