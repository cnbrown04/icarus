import Foundation
import GRDB
import Metrics
import Store

/// The ranges a metric page offers. Intraday metrics add the day view (D), so they default to it; daily metrics
/// start at the week (W). Nightly vitals (resting HR, HRV, respiratory rate) also have D: last night's readings.
enum MetricRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case sixMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "D"
        case .week: "W"
        case .month: "M"
        case .sixMonths: "6M"
        }
    }

    /// Local days covered, ending today. The day range covers one day.
    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .sixMonths: 182
        }
    }

    static func options(for kind: MetricKind) -> [MetricRange] {
        kind.hasIntraday || kind.isNightly ? allCases : [.week, .month, .sixMonths]
    }

    static func defaultRange(for kind: MetricKind) -> MetricRange {
        kind.hasIntraday ? .day : .week
    }
}

/// One daily bar or point: a local day's value, and its heart-rate range where the metric has one.
struct MetricDayRow: Identifiable, Sendable, Equatable {
    /// Epoch ms of local noon, which is unique per day and places the mark mid-day.
    let id: Int64
    let date: Date
    let value: Double?
    let low: Double?
    let high: Double?
}

/// Calories split for today: the active part and the total, from `Dashboard.calories`.
struct CaloriesSplit: Sendable, Equatable {
    let active: Double?
    let total: Double?
}

/// Everything a metric page shows for one range, read in one store pass through `MetricSeries`.
struct MetricDetailData: Sendable {
    let kind: MetricKind
    let range: MetricRange
    let timeZone: TimeZone
    let nowMs: Int64
    /// Local midnight today and the next midnight, the span the day view charts.
    let dayStartMs: Int64
    let dayEndMs: Int64
    /// Intraday values for today, oldest first; a nightly vital's readings (see `showsReadings`). Empty for other
    /// daily ranges.
    let points: [MetricPoint]
    /// One row per local day, oldest first. Empty for the day range.
    let rows: [MetricDayRow]
    /// The period's value: the mean, or the total for sums. Nil when the range has no values.
    let value: Double?
    let minimum: Double?
    let maximum: Double?
    /// The same measure over the previous equal period (yesterday for the day range). Nil when it has no values.
    let previousValue: Double?
    /// Caption under the header value, e.g. "Average · Oct 24–30" or "Latest · 21:42".
    let caption: String
    /// Minutes in each heart-rate zone over the range. Heart rate only.
    let zones: [ZoneMinutes]
    /// Stimulant-active windows that overlap today. Shown on the day view of heart rate and stress only.
    let medication: [MedicationWindow]
    /// Stress calibration progress. Stress only.
    let calibration: StressCalibrationProgress?
    /// Today's calories split. Calories day view only.
    let calories: CaloriesSplit?
    /// Today's recovery contributors and the 30-night reference. Recovery only.
    let snapshot: HealthSnapshot?
    /// The night the day view shows, for nightly vitals: `points` are its readings and `dayStartMs`–`dayEndMs` its
    /// span. Nil for other metrics and ranges, or before any main sleep.
    var night: VitalNight? = nil
    /// True when `points` are every window reading of a nightly vital over W, M or 6M, spanning `dayStartMs` (the
    /// first day's midnight) to `dayEndMs`. `rows` stay the nightly values.
    var showsReadings = false
    /// HRV or respiratory rate readings taken awake over the chart's span (D and All Readings), oldest first. They
    /// are drawn lighter: only the sleep readings in `points` set the nightly value.
    var dayPoints: [MetricPoint] = []

    var isEmpty: Bool {
        value == nil && points.isEmpty && rows.allSatisfy { $0.value == nil }
    }

    func nearestPoint(to date: Date) -> MetricPoint? {
        (points + dayPoints).min { lhs, rhs in
            abs(Date(epochMs: lhs.tsMs).timeIntervalSince(date)) < abs(Date(epochMs: rhs.tsMs).timeIntervalSince(date))
        }
    }

    func nearestRow(to date: Date) -> MetricDayRow? {
        rows.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
    }
}

/// Reads a metric page's data. Every value comes from `MetricSeries` (or the existing score and stress readers
/// that feed the same number), so a value is the same on every screen that shows it.
enum MetricDetailModel {
    /// `readings`: for a nightly vital over W, M or 6M, `points` carry every window reading of the span's nights
    /// (`MetricDetailData.showsReadings`). The header and details stay the nightly values.
    static func load(
        _ db: Database,
        nowMs: Int64,
        kind: MetricKind,
        range: MetricRange,
        readings: Bool = false
    ) throws -> MetricDetailData {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        let zone = context.timeZone
        let today = context.today
        var dayStartMs = LocalTime.localTime(today, hour: 0, in: zone)
        var dayEndMs = LocalTime.localTime(LocalTime.adding(days: 1, to: today), hour: 0, in: zone)

        var points: [MetricPoint] = []
        var rows: [MetricDayRow] = []
        var value: Double?
        var minimum: Double?
        var maximum: Double?
        var previousValue: Double?
        var caption: String

        var night: VitalNight?
        var showsReadings = false
        var dayPoints: [MetricPoint] = []

        if range == .day, kind.isNightly {
            // Last night's window readings; the value is the night's own (their floor, mean or median), which is
            // the number every other screen shows for that night.
            let nights = try db.vitalNights(kind, nowMs: nowMs, limit: 2, in: zone)
            night = nights.first
            if let night {
                points = try db.nightReadings(kind, night: night)
                dayStartMs = night.startMs
                dayEndMs = night.endMs
                // HRV and respiratory rate go on through the day: last night, then awake since.
                dayPoints = try db.awakeReadings(kind, fromMs: night.startMs, toMs: nowMs, in: zone)
                if let last = dayPoints.last { dayEndMs = max(dayEndMs, last.tsMs) }
            }
            value = night?.value
            minimum = points.map(\.value).min()
            maximum = points.map(\.value).max()
            previousValue = nights.count > 1 ? nights[1].value : nil
            caption = night.map { nightCaption($0, today: today, in: zone) } ?? "No night yet"
        } else if range == .day {
            points = try db.metricIntraday(kind, day: today, in: zone)
            let values = points.map(\.value)
            value = aggregate(values, kind)
            minimum = values.min()
            maximum = values.max()
            let yesterday = LocalTime.adding(days: -1, to: today)
            previousValue = aggregate(try db.metricIntraday(kind, day: yesterday, in: zone).map(\.value), kind)
            if kind.aggregation == .sum {
                caption = "Total · today"
            } else if let last = points.last {
                caption = "Latest · \(Format.clock(last.tsMs, in: zone))"
            } else {
                caption = "Latest · today"
            }
        } else {
            let first = LocalTime.adding(days: -(range.days - 1), to: today)
            let days = try db.metricDays(kind, from: first, through: today, in: zone)
            let ranges = kind == .heartRate
                ? try db.heartRateRange(from: first, through: today, in: zone)
                : []
            rows = days.map { entry in
                let bounds = ranges.first { $0.day == entry.day }
                return MetricDayRow(
                    id: LocalTime.localTime(entry.day, hour: 12, in: zone),
                    date: Date(epochMs: LocalTime.localTime(entry.day, hour: 12, in: zone)),
                    value: entry.value,
                    low: bounds?.min,
                    high: bounds?.max
                )
            }
            let present = days.compactMap(\.value)
            value = aggregate(present, kind)
            if kind == .heartRate {
                minimum = ranges.map(\.min).min()
                maximum = ranges.map(\.max).max()
            } else {
                minimum = present.min()
                maximum = present.max()
            }
            let previousFirst = LocalTime.adding(days: -range.days, to: first)
            let previousLast = LocalTime.adding(days: -1, to: first)
            let previous = try db.metricDays(kind, from: previousFirst, through: previousLast, in: zone)
            previousValue = aggregate(previous.compactMap(\.value), kind)
            let label = MetricFormat.rangeLabel(first, today, in: zone)
            caption = "\(kind.aggregation == .sum ? "Total" : "Average") · \(label)"
            if readings, kind.isNightly {
                points = try db.vitalReadings(kind, from: first, through: today, in: zone)
                showsReadings = true
                dayStartMs = LocalTime.localTime(first, hour: 0, in: zone)
                dayPoints = try db.awakeReadings(kind, fromMs: dayStartMs, toMs: dayEndMs, in: zone)
            }
        }

        var zones: [ZoneMinutes] = []
        if kind == .heartRate, let restingHR = context.restingHR, let maxHR = context.maxHR {
            let fromMs = range == .day ? dayStartMs : LocalTime.localTime(
                LocalTime.adding(days: -(range.days - 1), to: today),
                hour: 0,
                in: zone
            )
            let minutes = try db.minuteMetricRows(from: fromMs, to: dayEndMs)
            zones = HeartRateSeries.zoneMinutes(minutes, restingHR: restingHR, maxHR: maxHR)
        }

        var medication: [MedicationWindow] = []
        if range == .day, kind == .heartRate || kind == .stress {
            medication = try db.medicationWindows(from: today, to: today, in: zone)
                .clipped(toMs: dayStartMs, dayEndMs)
        }

        var calibration: StressCalibrationProgress?
        if kind == .stress {
            calibration = try Dashboard.stressCalibration(db, nowMs: nowMs, context: context)
        }

        var calories: CaloriesSplit?
        if kind == .calories, range == .day {
            let snapshot = try Dashboard.calories(db, nowMs: nowMs)
            calories = CaloriesSplit(active: snapshot.active, total: snapshot.total)
        }

        var snapshot: HealthSnapshot?
        if kind == .recovery {
            snapshot = try HealthSnapshot.load(db, nowMs: nowMs, day: nil, seriesDays: 30)
        }

        return MetricDetailData(
            kind: kind,
            range: range,
            timeZone: zone,
            nowMs: nowMs,
            dayStartMs: dayStartMs,
            dayEndMs: dayEndMs,
            points: points,
            rows: rows,
            value: value,
            minimum: minimum,
            maximum: maximum,
            previousValue: previousValue,
            caption: caption,
            zones: zones,
            medication: medication,
            calibration: calibration,
            calories: calories,
            snapshot: snapshot,
            night: night,
            showsReadings: showsReadings,
            dayPoints: dayPoints
        )
    }

    /// "Last night · 01:33–07:10", or the wake date when the newest night is older than last night.
    static func nightCaption(_ night: VitalNight, today: LocalDay, in zone: TimeZone) -> String {
        let span = "\(Format.clock(night.startMs, in: zone))–\(Format.clock(night.endMs, in: zone))"
        let when = night.day == today ? "Last night" : MetricFormat.shortDate(night.day, in: zone)
        return "\(when) · \(span)"
    }

    /// The period value: a mean for averaged metrics, a total for sums. Nil when there are no values.
    static func aggregate(_ values: [Double], _ kind: MetricKind) -> Double? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        switch kind.aggregation {
        case .sum: return total
        case .average: return total / Double(values.count)
        }
    }
}

/// Display text for metric values and ranges. Numbers are locale-aware, and the unit follows after a regular space.
enum MetricFormat {
    /// A value with the metric's decimal places, no unit.
    static func number(_ value: Double, _ kind: MetricKind) -> String {
        if kind == .sleep {
            return Format.duration(Int64(value))
        }
        return value.formatted(.number.precision(.fractionLength(kind.fractionDigits)))
    }

    /// A value with its unit, e.g. "65 bpm". Metrics without a unit show the number alone.
    static func withUnit(_ value: Double, _ kind: MetricKind) -> String {
        let text = number(value, kind)
        guard let unit = kind.unit else { return text }
        return unit == "%" ? "\(text)%" : "\(text) \(unit)"
    }

    /// A signed change, e.g. "+3 bpm" or "−2 bpm".
    static func change(_ value: Double, _ kind: MetricKind) -> String {
        let text = number(abs(value), kind)
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        guard let unit = kind.unit else { return "\(sign)\(text)" }
        return unit == "%" ? "\(sign)\(text)%" : "\(sign)\(text) \(unit)"
    }

    /// "Oct 24–30" within one month, or "Oct 24–Nov 2" across months.
    static func rangeLabel(_ first: LocalDay, _ last: LocalDay, in zone: TimeZone) -> String {
        let start = shortDate(first, in: zone)
        if first == last { return start }
        let sameMonth = first.year == last.year && first.month == last.month
        let end = sameMonth ? "\(last.day)" : shortDate(last, in: zone)
        return "\(start)–\(end)"
    }

    /// "Oct 24" for a local day.
    static func shortDate(_ day: LocalDay, in zone: TimeZone) -> String {
        shortDate(Date(epochMs: LocalTime.localTime(day, hour: 12, in: zone)), in: zone)
    }

    static func shortDate(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
