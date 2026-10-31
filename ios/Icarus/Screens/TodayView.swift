import Metrics
import Store
import SwiftUI
import SyncKit

/// Destinations pushed from Today's cards (PLAN.md §14 rows 8-10).
enum TodayDestination: Hashable {
    case heartRate
    case stress
    case calories
    case sleep
}

/// The span for the daily trend charts on the metric detail screens. The old Trends tab owned this control;
/// it now sits beside the values it describes.
enum TrendSpan: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: "7 d"
        case .month: "30 d"
        case .quarter: "90 d"
        }
    }

    /// Load twice the span so the first half can supply the previous-period delta chip.
    var loadedDayCount: Int { rawValue * 2 }
}

/// A 7, 30 or 90 day segmented control shared by the metric detail screens.
struct TrendSpanPicker: View {
    @Binding var span: TrendSpan

    var body: some View {
        Picker("Span", selection: $span) {
            ForEach(TrendSpan.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// A trend average with its change against the previous period, in the style of the old Trends cards.
struct TrendSummary: View {
    let series: TrendSeries
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
            Text(series.average.map { Format.number($0, unit: unit) } ?? "--")
                .font(.metricValue)
                .monospacedDigit()
            if let change = series.change {
                DeltaChip(change: change, unit: unit)
            }
            Spacer(minLength: Spacing.s8)
        }
    }
}

extension TrendSeries {
    /// The latest day's value, worded for a trend card footer.
    func latestFooter(unit: String) -> String {
        guard let latest else { return "No data" }
        return "Latest \(Format.number(latest, unit: unit))"
    }
}

/// Everything Today reads in one observation: the summary, the two per-minute timelines and the
/// calibration progress. Bundling them keeps the cards on the same store snapshot.
private struct TodayData: Sendable {
    let snapshot: Dashboard.TodaySnapshot
    let dayStartMs: Int64
    let zoneTimeline: HRZoneTimeline
    let stressTimeline: [StressTimelinePoint]
    let calibration: StressCalibrationProgress
}

/// The Today dashboard: live heart rate, four metric tiles, and today's zones, stress and sleep. Band and
/// sync state live in Settings; each card opens the screen that owns its detail.
struct TodayView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var data: TodayData?
    @State private var sleep: Dashboard.SleepSnapshot?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                if environment.sync.status.phase == .needsRepair {
                    repairCard
                }
                if environment.storageFailed {
                    storageCard
                }
                heroCard
                metricGrid
                zonesCard
                stressCard
                sleepCard
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .refreshable {
            await environment.sync.runNow()
        }
        .navigationTitle("Today")
        .navigationDestination(for: TodayDestination.self) { destination in
            switch destination {
            case .heartRate: HeartRateDetailView(environment: environment)
            case .stress: StressDetailView(environment: environment)
            case .calories: CaloriesDetailView(environment: environment)
            case .sleep: SleepView(environment: environment)
            }
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ db in
                    let now = clock.nowMs
                    let snapshot = try Dashboard.today(db, nowMs: now)
                    let dayStart = LocalTime.localTime(
                        snapshot.context.today,
                        hour: 0,
                        in: snapshot.context.timeZone
                    )
                    return TodayData(
                        snapshot: snapshot,
                        dayStartMs: dayStart,
                        zoneTimeline: try Dashboard.hrZoneTimeline(
                            db, nowMs: now, fromMs: dayStart, context: snapshot.context
                        ),
                        stressTimeline: try Dashboard.stressTimeline(db, nowMs: now, fromMs: dayStart),
                        calibration: try Dashboard.stressCalibration(
                            db, nowMs: now, context: snapshot.context
                        )
                    )
                }) {
                    data = value
                }
            } catch {
                data = nil
            }
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try Dashboard.sleep($0, nowMs: clock.nowMs) }) {
                    sleep = value
                }
            } catch {
                sleep = nil
            }
        }
    }

    // MARK: Cards

    private var heroCard: some View {
        NavigationLink(value: TodayDestination.heartRate) {
            DashboardCard(
                title: "Heart Rate",
                symbol: "heart.fill",
                tint: Palette.heartRate,
                showsChevron: true,
                pulses: liveState.isStreaming
            ) {
                HStack(alignment: .firstTextBaseline) {
                    bpmText
                    Spacer(minLength: Spacing.s8)
                    StatusPill.link(liveState)
                }
                HRAreaChart(points: sparklinePoints, average: nil, selection: .constant(nil))
                    .frame(height: Spacing.s48 * 2)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heart rate, last 15 minutes")
                    .accessibilityValue(rangeText)
                Text(heroSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bpmText: some View {
        if let bpm = liveState.latestBPM {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text("\(bpm)")
                    .font(.heroValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .stateAnimation(bpm)
                    .accessibilityIdentifier("today.hrValue")
                Text("bpm")
                    .font(.metricUnit)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("--")
                .font(.heroValue)
                .foregroundStyle(.secondary)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.s16),
                GridItem(.flexible(), spacing: Spacing.s16),
            ],
            spacing: Spacing.s16
        ) {
            NavigationLink(value: TodayDestination.heartRate) {
                MetricTile(
                    title: "Resting HR",
                    symbol: "bed.double.fill",
                    tint: Palette.sleep,
                    value: restingValue,
                    unit: restingValue == "--" ? nil : "bpm",
                    caption: "Overnight low",
                    change: restingSeries.change,
                    changeUnit: "bpm"
                ) {
                    MiniSparkline(points: restingWeek.points, tint: Palette.sleep)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Resting HR, last 7 days")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens heart rate details")

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "HRV",
                    symbol: "waveform.path.ecg",
                    tint: Palette.hrv,
                    value: hrvValue,
                    unit: hrvValue == "--" ? nil : "ms",
                    caption: "RMSSD",
                    change: hrvSeries.change,
                    changeUnit: "ms"
                ) {
                    MiniSparkline(points: hrvWeek.points, tint: Palette.hrv)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("HRV, last 7 days")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens stress details")

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "Stress",
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: Palette.stressModerate,
                    value: stressValue,
                    caption: stressTileCaption,
                    change: stressSeries.change,
                    valueIdentifier: "today.stressValue"
                ) {
                    MiniSparkline(points: stressWeek.points, tint: Palette.stressModerate)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Stress, last 7 days")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens stress details")

            NavigationLink(value: TodayDestination.calories) {
                MetricTile(
                    title: "Calories",
                    symbol: "flame.fill",
                    tint: Palette.caloriesActive,
                    value: caloriesValue,
                    unit: caloriesValue == "--" ? nil : "kcal",
                    caption: "Estimated",
                    change: caloriesSeries.change,
                    changeUnit: "kcal",
                    valueIdentifier: "today.caloriesValue"
                ) {
                    MiniSparkline(points: caloriesWeek.points, tint: Palette.caloriesActive)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Calories, last 7 days")
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens calorie details")
        }
    }

    private var zonesCard: some View {
        NavigationLink(value: TodayDestination.heartRate) {
            DashboardCard(
                title: "Heart rate zones",
                symbol: "figure.run",
                tint: .green,
                showsChevron: true
            ) {
                if let data, !data.zoneTimeline.runs.isEmpty {
                    ZoneTimelineChart(
                        timeline: data.zoneTimeline,
                        fromMs: data.dayStartMs,
                        toMs: data.snapshot.context.nowMs
                    )
                    .frame(height: Spacing.s48 * 2)
                    .allowsHitTesting(false)
                    if !zoneSegments.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            MinuteStrip(
                                segments: zoneSegments,
                                accessibilityLabel: "Minutes by zone",
                                accessibilityValue: zoneAccessibilityValue
                            )
                            Text(zoneCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                } else {
                    Text("No zone data yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var stressCard: some View {
        NavigationLink(value: TodayDestination.stress) {
            DashboardCard(
                title: "Stress today",
                symbol: "gauge.with.dots.needle.67percent",
                tint: .orange,
                showsChevron: true
            ) {
                if let data {
                    let day = data.snapshot.stressDay
                    if day.sampleMinutes > 0 {
                        Text(stressSummary(day))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        StressTimelineChart(
                            points: data.stressTimeline,
                            fromMs: data.dayStartMs,
                            toMs: data.snapshot.context.nowMs
                        )
                        .frame(height: Spacing.s48 * 2)
                        .allowsHitTesting(false)
                        if !stressBandSegments.isEmpty {
                            MinuteStrip(
                                segments: stressBandSegments,
                                accessibilityLabel: "Minutes in each stress band",
                                accessibilityValue: stressBandAccessibilityValue
                            )
                        }
                    }
                    if let line = stressCalibrationLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else if day.sampleMinutes == 0 {
                        Text(stressEmptyLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No stress values yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var sleepCard: some View {
        NavigationLink(value: TodayDestination.sleep) {
            DashboardCard(
                title: "Sleep",
                symbol: "moon.zzz.fill",
                tint: Palette.sleep,
                showsChevron: true
            ) {
                if let latest = sleep?.latest {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.duration(latest.asleepS))
                            .font(.metricValue)
                            .monospacedDigit()
                        Spacer(minLength: Spacing.s8)
                        Text(Format.sleepQuality(latest.quality))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.sleepQuality(latest.quality))
                    }
                    Text(sleepWindow(latest))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text("No sleep data yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var repairCard: some View {
        NavigationLink {
            ServerView(sync: environment.sync)
        } label: {
            DashboardCard(
                title: "Re-pair this iPhone",
                symbol: "exclamationmark.triangle.fill",
                tint: Palette.warn,
                showsChevron: true
            ) {
                Text("The server rejected this iPhone. Pair again to resume sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var storageCard: some View {
        DashboardCard(title: "Not saved", symbol: "externaldrive.badge.exclamationmark", tint: Palette.error) {
            Text("Data is not saved on this launch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Values

    private var snapshot: Dashboard.TodaySnapshot? {
        data?.snapshot
    }

    private var stressTimeline: [StressTimelinePoint] {
        data?.stressTimeline ?? []
    }

    private var calibration: StressCalibrationProgress {
        data?.calibration ?? .unavailable
    }

    private var sparklinePoints: [HRPoint] {
        let raw = (snapshot?.sparkline ?? []).map { HRPoint(date: $0.date, bpm: Double($0.bpm)) }
        return HRPoint.averaged(raw, bucket: 15)
    }

    private var rangeText: String {
        let values = (snapshot?.sparkline ?? []).map(\.bpm)
        guard let low = values.min(), let high = values.max() else { return "No samples in the last 15 minutes" }
        return "Range \(low) to \(high) bpm"
    }

    /// One compact line under the live chart: today's average, maximum and coverage.
    private var heroSummary: String {
        guard let snapshot else { return "No summary yet" }
        guard snapshot.hrAvg != nil || snapshot.hrMax != nil else { return "No heart rate yet" }
        let average = snapshot.hrAvg.map { "\(Int($0.rounded()))" } ?? "--"
        let maximum = snapshot.hrMax.map { "\($0)" } ?? "--"
        return "Avg \(average) · Max \(maximum) bpm · \(Format.percent(snapshot.coverage)) coverage"
    }

    private var week: [DaySummary] {
        snapshot?.week ?? []
    }

    private var restingSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.restingHR, currentCount: 1)
    }

    /// Seven days for the sparklines. `restingSeries` and `hrvSeries` cover today only, for the value and the change.
    private var restingWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.restingHR, currentCount: 7)
    }

    private var hrvSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.rmssdNight, currentCount: 1)
    }

    private var hrvWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.rmssdNight, currentCount: 7)
    }

    private var stressSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.stressAverage, currentCount: 1)
    }

    private var stressWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.stressAverage, currentCount: 7)
    }

    private var caloriesSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.kcalTotal, currentCount: 1)
    }

    private var caloriesWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.kcalTotal, currentCount: 7)
    }

    private var timeZone: TimeZone {
        snapshot?.context.timeZone ?? Dashboard.fallbackZone
    }

    private var restingValue: String {
        guard let value = restingSeries.latest ?? snapshot?.context.restingHR else { return "--" }
        return "\(Int(value.rounded()))"
    }

    private var hrvValue: String {
        guard let value = hrvSeries.latest else { return "--" }
        return "\(Int(value.rounded()))"
    }

    private var latestStress: Int? {
        if let stress = snapshot?.latestMinute?.stress { return stress }
        return stressTimeline.last(where: { $0.stress != nil })?.stress
    }

    private var stressState: StressState? {
        snapshot?.latestMinute?.state ?? stressTimeline.last?.state
    }

    private var stressValue: String {
        latestStress.map { "\($0)" } ?? "--"
    }

    /// The band when there is a value; otherwise one short status line.
    private var stressTileCaption: String? {
        guard data != nil else { return nil }
        if let latest = latestStress { return Format.stressBand(latest) }
        if !calibration.isCalibrated, stressState != .exertion, stressState != .hrOnly, !calibration.days.isEmpty {
            return "Calibrating \(calibration.qualifyingDays)/\(calibration.requiredDays)"
        }
        if stressState == .exertion { return "Exertion" }
        if stressState == .hrOnly { return "HR only" }
        if calibration.days.isEmpty { return "No baseline" }
        return "No values"
    }

    private var stressCalibrationLine: String? {
        guard snapshot != nil, latestStress == nil else { return nil }
        if stressState == .exertion || stressState == .hrOnly { return nil }
        guard !calibration.isCalibrated, !calibration.days.isEmpty else { return nil }
        return "Calibrating \(calibration.qualifyingDays) of \(calibration.requiredDays) days"
    }

    private var stressEmptyLine: String {
        if stressState == .exertion {
            return "Stress is not scored during exertion."
        }
        return "No stress values yet"
    }

    private var caloriesValue: String {
        guard let total = snapshot?.today?.kcalTotal else { return "--" }
        return "\(Int(total.rounded()))"
    }

    // MARK: Zone and stress strips

    private var zoneSegments: [MinuteStrip.Segment] {
        (snapshot?.zones ?? [])
            .filter { $0.minutes > 0 }
            .enumerated()
            .map { index, entry in
                MinuteStrip.Segment(id: index, minutes: entry.minutes, color: Palette.zone(entry.zone))
            }
    }

    private var zoneCaption: String {
        let populated = (snapshot?.zones ?? []).filter { $0.minutes > 0 }
        guard !populated.isEmpty else { return "" }
        let parts = populated.map { "\(zoneShortName($0.zone)) \($0.minutes)" }
        return parts.joined(separator: " · ") + " min"
    }

    private var zoneAccessibilityValue: String {
        (snapshot?.zones ?? [])
            .filter { $0.minutes > 0 }
            .map { "\(Format.zoneLabel($0.zone)): \(Format.minutes($0.minutes))" }
            .joined(separator: ", ")
    }

    private func zoneShortName(_ zone: HeartRateZone) -> String {
        switch zone {
        case .below: "Below"
        case .zone1: "Z1"
        case .zone2: "Z2"
        case .zone3: "Z3"
        case .zone4: "Z4"
        case .zone5: "Z5"
        }
    }

    private var stressBandSegments: [MinuteStrip.Segment] {
        (snapshot?.stressDay.bandMinutes ?? [])
            .filter { $0.minutes > 0 }
            .enumerated()
            .map { index, entry in
                MinuteStrip.Segment(id: index, minutes: entry.minutes, color: Palette.stress(entry.band))
            }
    }

    private var stressBandAccessibilityValue: String {
        (snapshot?.stressDay.bandMinutes ?? [])
            .filter { $0.minutes > 0 }
            .map { "\(Format.bandName($0.band)): \(Format.minutes($0.minutes))" }
            .joined(separator: ", ")
    }

    private func stressSummary(_ day: StressDaySummary) -> String {
        var parts: [String] = []
        if let average = day.average {
            parts.append("Avg \(Int(average.rounded()))")
        }
        if let peak = day.peak {
            parts.append("Peak \(peak)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Sleep values

    private func sleepWindow(_ night: Dashboard.SleepSnapshot.Night) -> String {
        let zone = sleep?.context.timeZone ?? Dashboard.fallbackZone
        let wakeMs = night.startMs + night.durationS * 1_000
        return "\(Format.clock(night.startMs, in: zone)) – \(Format.clock(wakeMs, in: zone))"
    }
}

/// A slim proportional bar for zone or band minutes. The segments carry the colour; the caption or
/// the detail screen carries the labels.
private struct MinuteStrip: View {
    struct Segment: Identifiable {
        let id: Int
        let minutes: Int
        let color: Color
    }

    let segments: [Segment]
    let accessibilityLabel: String
    let accessibilityValue: String

    private var total: Int {
        segments.reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: .zero) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(
                            width: proxy.size.width * CGFloat(segment.minutes) / CGFloat(max(total, 1)),
                            height: proxy.size.height
                        )
                }
            }
        }
        .frame(height: Spacing.s8)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}
