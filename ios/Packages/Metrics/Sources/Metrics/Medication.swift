import Foundation

/// Pharmacological class. Only `stimulant` produces stimulant-active windows (`isStimulantActive`).
public enum MedicationClass: String, Sendable, Codable, Equatable, CaseIterable {
    case stimulant
    case other
}

public enum MedicationFormulation: String, Sendable, Codable, Equatable {
    case immediateRelease
    case extendedRelease
}

/// A medication the user takes on a schedule. Times are epoch ms UTC, the schedule is wall-clock minutes of
/// the local day, and `weekdays` uses 1 = Sunday ... 7 = Saturday (empty = every day).
public struct MedicationProfile: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var medClass: MedicationClass
    public var formulation: MedicationFormulation
    /// Minutes from a dose until the effect starts.
    public var onsetMinutes: Int
    /// Minutes the effect lasts after onset.
    public var durationMinutes: Int
    /// Scheduled dose times as minutes of the local day, e.g. `[480]` is 08:00.
    public var scheduleMinutesOfDay: [Int]
    public var weekdays: Set<Int>
    public var active: Bool

    public init(
        id: String,
        name: String,
        medClass: MedicationClass,
        formulation: MedicationFormulation,
        onsetMinutes: Int,
        durationMinutes: Int,
        scheduleMinutesOfDay: [Int],
        weekdays: Set<Int> = [],
        active: Bool = true
    ) {
        self.id = id
        self.name = name
        self.medClass = medClass
        self.formulation = formulation
        self.onsetMinutes = onsetMinutes
        self.durationMinutes = durationMinutes
        self.scheduleMinutesOfDay = scheduleMinutesOfDay
        self.weekdays = weekdays
        self.active = active
    }

    /// Starting points for common stimulants. The onset and duration figures are approximate typical
    /// ranges from product labelling, not measurements of this user. Every value is user-editable
    /// after a preset creates a profile.
    public enum Preset: CaseIterable, Sendable {
        case amphetamineIR
        case amphetamineXR
        case methylphenidateIR
        case methylphenidateER

        public var name: String {
            switch self {
            case .amphetamineIR: "Adderall (IR)"
            case .amphetamineXR: "Adderall XR"
            case .methylphenidateIR: "Methylphenidate (IR)"
            case .methylphenidateER: "Methylphenidate (ER)"
            }
        }

        public var medClass: MedicationClass { .stimulant }

        public var formulation: MedicationFormulation {
            switch self {
            case .amphetamineIR, .methylphenidateIR: .immediateRelease
            case .amphetamineXR, .methylphenidateER: .extendedRelease
            }
        }

        public var onsetMinutes: Int {
            switch self {
            case .amphetamineIR: 30
            case .amphetamineXR: 60
            case .methylphenidateIR: 20
            case .methylphenidateER: 60
            }
        }

        public var durationMinutes: Int {
            switch self {
            case .amphetamineIR: 300
            case .amphetamineXR: 660
            case .methylphenidateIR: 240
            case .methylphenidateER: 600
            }
        }

        /// A profile built from this preset. The schedule and weekdays come from the user.
        public func profile(
            id: String,
            scheduleMinutesOfDay: [Int],
            weekdays: Set<Int> = [],
            active: Bool = true
        ) -> MedicationProfile {
            MedicationProfile(
                id: id,
                name: name,
                medClass: medClass,
                formulation: formulation,
                onsetMinutes: onsetMinutes,
                durationMinutes: durationMinutes,
                scheduleMinutesOfDay: scheduleMinutesOfDay,
                weekdays: weekdays,
                active: active
            )
        }
    }
}

/// One dose actually taken or scheduled, at an absolute instant.
public struct MedicationDose: Sendable, Equatable {
    public var medicationID: String
    public var takenAtMs: Int64

    public init(medicationID: String, takenAtMs: Int64) {
        self.medicationID = medicationID
        self.takenAtMs = takenAtMs
    }
}

/// A per-day correction to a medication's schedule. For that day it replaces the schedule entirely.
public struct DoseOverride: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case taken(atMs: Int64)
        case skipped
    }

    public var medicationID: String
    public var day: LocalDay
    public var kind: Kind

    public init(medicationID: String, day: LocalDay, kind: Kind) {
        self.medicationID = medicationID
        self.day = day
        self.kind = kind
    }
}

/// The span over which a dose is in effect: `startMs` = dose + onset, `endMs` = start + duration.
/// The end is exclusive.
public struct MedicationWindow: Sendable, Equatable {
    public var medicationID: String
    public var medClass: MedicationClass
    public var startMs: Int64
    public var endMs: Int64

    public init(medicationID: String, medClass: MedicationClass, startMs: Int64, endMs: Int64) {
        self.medicationID = medicationID
        self.medClass = medClass
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum MedicationEffect {
    /// Doses for every active profile on each local day from `from` through `to` (both inclusive).
    ///
    /// A day with overrides for a medication uses only those overrides: `.taken` times are the doses and
    /// `.skipped` yields none. A `.taken` override counts even on a day the schedule would not cover,
    /// because it records a dose the user actually took. Otherwise the day gets the schedule's times when
    /// its weekday matches. Inactive profiles produce no doses.
    public static func doses(
        profiles: [MedicationProfile],
        overrides: [DoseOverride],
        from: LocalDay,
        to: LocalDay,
        in timeZone: TimeZone
    ) -> [MedicationDose] {
        var overridesByDay: [OverrideKey: [DoseOverride.Kind]] = [:]
        for override in overrides {
            overridesByDay[OverrideKey(medicationID: override.medicationID, day: override.day), default: []]
                .append(override.kind)
        }

        var doses: [MedicationDose] = []
        let lastKey = dayKey(to)
        var day = from
        while dayKey(day) <= lastKey {
            let weekday = weekday(of: day)
            for profile in profiles where profile.active {
                let times: Set<Int64>
                if let kinds = overridesByDay[OverrideKey(medicationID: profile.id, day: day)] {
                    times = Set(kinds.compactMap { kind -> Int64? in
                        if case .taken(let atMs) = kind { atMs } else { nil }
                    })
                } else if profile.weekdays.isEmpty || profile.weekdays.contains(weekday) {
                    times = Set(profile.scheduleMinutesOfDay.map {
                        LocalTime.localTime(day, minuteOfDay: $0, in: timeZone)
                    })
                } else {
                    times = []
                }
                for takenAtMs in times.sorted() {
                    doses.append(MedicationDose(medicationID: profile.id, takenAtMs: takenAtMs))
                }
            }
            day = LocalTime.adding(days: 1, to: day)
        }
        return doses
    }

    /// One window per dose whose medication is in `profiles`, in start order. Doses for unknown
    /// medications are skipped.
    public static func activeWindows(doses: [MedicationDose], profiles: [MedicationProfile]) -> [MedicationWindow] {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return doses.compactMap { dose -> MedicationWindow? in
            guard let profile = byID[dose.medicationID] else { return nil }
            let startMs = dose.takenAtMs + Int64(profile.onsetMinutes) * LocalTime.msPerMinute
            return MedicationWindow(
                medicationID: dose.medicationID,
                medClass: profile.medClass,
                startMs: startMs,
                endMs: startMs + Int64(profile.durationMinutes) * LocalTime.msPerMinute
            )
        }
        .sorted { $0.startMs < $1.startMs }
    }

    /// Unions overlapping windows of the same class. Windows that only touch (one ends exactly where the
    /// next starts) also merge. Empty windows are dropped. Each merged window keeps the `medicationID` of
    /// the window that started it. Output is sorted by start time.
    public static func merged(_ windows: [MedicationWindow]) -> [MedicationWindow] {
        var output: [MedicationWindow] = []
        for (_, group) in Dictionary(grouping: windows.filter { $0.endMs > $0.startMs }, by: \.medClass) {
            var current: MedicationWindow?
            for window in group.sorted(by: { $0.startMs < $1.startMs }) {
                if var run = current, window.startMs <= run.endMs {
                    run.endMs = max(run.endMs, window.endMs)
                    current = run
                } else {
                    if let finished = current { output.append(finished) }
                    current = window
                }
            }
            if let finished = current { output.append(finished) }
        }
        return output.sorted {
            $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.medClass.rawValue < $1.medClass.rawValue
        }
    }

    /// True when `ms` falls in a stimulant window: start inclusive, end exclusive.
    public static func isStimulantActive(at ms: Int64, windows: [MedicationWindow]) -> Bool {
        windows.contains { $0.medClass == .stimulant && $0.startMs <= ms && ms < $0.endMs }
    }

    private struct OverrideKey: Hashable {
        var medicationID: String
        var day: LocalDay
    }

    private static func dayKey(_ day: LocalDay) -> Int {
        day.year * 10_000 + day.month * 100 + day.day
    }

    /// 1 = Sunday ... 7 = Saturday, evaluated on the calendar date itself (no timezone involved).
    private static func weekday(of day: LocalDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return calendar.component(.weekday, from: noon)
    }
}
