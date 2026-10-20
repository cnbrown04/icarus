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

/// The Today dashboard: live heart rate, four metric tiles, and stress and zones for the day. Band and sync state
/// lives in Settings.
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
                stressCard
                zonesCard
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
                        Text(Format.duration(latest.durationS))
                            .font(.metricValue)
                            .monospacedDigit()
                        Spacer(minLength: Spacing.s8)
                        Text(Format.sleepQuality(latest.quality))
                            .foregroundStyle(Palette.sleepQuality(latest.quality))
                    }
                    HStack(spacing: Spacing.s8) {
                        Text(sleepWindow(latest))
                        Spacer(minLength: Spacing.s8)
                        if let comparison = sleepComparison(latest) {
                            Text(comparison)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    HStack(spacing: Spacing.s16) {
                        Text("RHR \(latest.restingHR.map { Format.bpm($0) } ?? "--")")
                        Text("RMSSD \(latest.rmssdMs.map { Format.ms($0) } ?? "--")")
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } else {
                    Text("No data yet")
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
                    .accessibilityLabel("Heart rate, last 15 minutes")
                    .accessibilityValue(rangeText)
                HStack {
                    Text("Last 15 min")
                    Spacer(minLength: Spacing.s8)
                    Text(rangeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let snapshot {
                    HStack(alignment: .top, spacing: Spacing.s16) {
                        summaryStat(title: "Avg", value: snapshot.hrAvg.map { Format.bpm($0) } ?? "--")
                        summaryStat(title: "Max", value: snapshot.hrMax.map { Format.bpm($0) } ?? "--")
                        summaryStat(title: "Data coverage", value: Format.percent(snapshot.coverage))
                    }
                    if snapshot.coverage < 0.8 {
                        Text("Partial day")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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

    private func summaryStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    caption: "Lowest 5-min in 00:00–06:00",
                    change: restingSeries.change,
                    changeUnit: "bpm"
                ) {
                    MiniSparkline(points: restingWeek.points, tint: Palette.sleep)
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "HRV",
                    symbol: "waveform.path.ecg",
                    tint: Palette.hrv,
                    value: hrvValue,
                    unit: hrvValue == "--" ? nil : "ms",
                    caption: hrvCaption,
                    change: hrvSeries.change,
                    changeUnit: "ms"
                ) {
                    MiniSparkline(points: hrvWeek.points, tint: Palette.hrv)
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "Stress",
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: Palette.stressModerate,
                    value: stressValue,
                    caption: latestStress == nil ? nil : "Estimated",
                    valueIdentifier: "today.stressValue"
                ) {
                    HStack(spacing: Spacing.s8) {
                        StressGauge(value: latestStress)
                            .frame(width: MetricTileLayout.visualHeight, height: MetricTileLayout.visualHeight)
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            if let band = stressCaption {
                                Text(band)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let average = snapshot?.stressAverage, let peak = snapshot?.stressPeak {
                                Text("Avg \(Int(average.rounded())) · Peak \(peak)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            if let day = snapshot?.stressDay, day.sampleMinutes > 0 {
                                StressBandMinutesCompact(summary: day)
                            } else if showsCalibrationNote {
                                Text(calibrationLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.calories) {
                MetricTile(
                    title: "Calories",
                    symbol: "flame.fill",
                    tint: Palette.caloriesActive,
                    value: caloriesValue,
                    unit: caloriesValue == "--" ? nil : "kcal",
                    caption: "Estimated",
                    valueIdentifier: "today.caloriesValue"
                ) {
                    HStack(spacing: Spacing.s12) {
                        RingProgress(fraction: activeShare, summary: "Active share of calories", lineWidth: Spacing.s8) {
                            EmptyView()
                        }
                        .frame(width: MetricTileLayout.visualHeight, height: MetricTileLayout.visualHeight)
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            Text(activeText)
                            Text(bmrText)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
            .buttonStyle(.plain)
        }
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
                    if data.snapshot.stressDay.sampleMinutes > 0 {
                        stressSummary(data.snapshot.stressDay)
                        StressTimelineChart(
                            points: data.stressTimeline,
                            fromMs: data.dayStartMs,
                            toMs: data.snapshot.context.nowMs
                        )
                        .frame(height: Spacing.s48 * 2)
                        .allowsHitTesting(false)
                        StressLegend()
                        StressBandMinutesRow(summary: data.snapshot.stressDay)
                    }
                    if showsCalibrationNote {
                        if data.snapshot.stressDay.sampleMinutes > 0 {
                            Divider()
                        }
                        StressCalibrationNote(progress: data.calibration, state: stressState)
                    } else if data.snapshot.stressDay.sampleMinutes == 0 {
                        Text(noStressText)
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

    private func stressSummary(_ day: StressDaySummary) -> some View {
        HStack(spacing: Spacing.s16) {
            if let average = day.average {
                Text("Average \(Int(average.rounded()))")
            }
            if let peak = day.peak {
                Text("Peak \(peak)")
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var zonesCard: some View {
        NavigationLink(value: TodayDestination.heartRate) {
            DashboardCard(
                title: "Zones today",
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
                    .frame(height: Spacing.s48 * 2 + Spacing.s16)
                    .allowsHitTesting(false)
                }
                if let zones = snapshot?.zones, zones.contains(where: { $0.minutes > 0 }) {
                    Text("Minutes by zone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ZoneBar(zones: zones)
                } else if data == nil || data?.zoneTimeline.runs.isEmpty == true {
                    Text("Zones need a profile and a night of data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
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
        guard let low = values.min(), let high = values.max() else { return "No samples" }
        return "Range \(low)-\(high) bpm"
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

    private var hrvCaption: String? {
        guard let sdnn = snapshot?.latestMinute?.sdnnMs else { return nil }
        return "SDNN \(Format.ms(sdnn))"
    }

    private var latestStress: Int? {
        if let stress = snapshot?.latestMinute?.stress { return stress }
        return stressTimeline.last(where: { $0.stress != nil })?.stress
    }

    private var stressState: StressState? {
        snapshot?.latestMinute?.state ?? stressTimeline.last?.state
    }

    private var stressValue: String {
        if let latest = latestStress { return "\(latest)" }
        if let state = stressState, state != .value { return Format.stressState(state) }
        if calibration.nights.isEmpty { return "No baseline" }
        if !calibration.isCalibrated { return "Calibrating" }
        return "No values"
    }

    private var stressCaption: String? {
        guard let latest = latestStress else { return nil }
        return Format.stressBand(latest)
    }

    private var calibrationLine: String {
        guard !calibration.nights.isEmpty else { return "No baseline" }
        return "\(calibration.qualifyingDays) of \(calibration.requiredDays) nights"
    }

    private var showsCalibrationNote: Bool {
        guard let data else { return false }
        switch stressState {
        case .some(.calibrating), .some(.hrOnly), .some(.insufficient):
            return true
        default:
            break
        }
        return data.snapshot.stressDay.sampleMinutes == 0 && !data.calibration.isCalibrated
    }

    private var noStressText: String {
        if stressState == .exertion {
            return "Stress is not scored during exertion."
        }
        return "No stress values yet"
    }

    private var caloriesValue: String {
        guard let total = snapshot?.today?.kcalTotal else { return "--" }
        return "\(Int(total.rounded()))"
    }

    private var activeShare: Double {
        guard let total = snapshot?.today?.kcalTotal, total > 0, let active = snapshot?.today?.kcalActive else { return 0 }
        return active / total
    }

    private var activeText: String {
        guard let active = snapshot?.today?.kcalActive else { return "Active --" }
        return "Active \(Int(active.rounded())) kcal"
    }

    private var bmrText: String {
        guard let total = snapshot?.today?.kcalTotal, let active = snapshot?.today?.kcalActive else {
            return "BMR --"
        }
        return "BMR \(Int(max(0, total - active).rounded())) kcal"
    }

    // MARK: Sleep values

    private var sleepTimeZone: TimeZone {
        sleep?.context.timeZone ?? Dashboard.fallbackZone
    }

    private func sleepWindow(_ night: Dashboard.SleepSnapshot.Night) -> String {
        let wakeMs = night.startMs + night.durationS * 1_000
        return "\(Format.clock(night.startMs, in: sleepTimeZone)) – \(Format.clock(wakeMs, in: sleepTimeZone))"
    }

    /// Latest duration against the recent nights, including the latest. Named for the actual count when
    /// fewer than seven nights have synced.
    private func sleepComparison(_ latest: Dashboard.SleepSnapshot.Night) -> String? {
        guard let nights = sleep?.nights, nights.count > 1 else { return nil }
        let recent = Array(nights.prefix(7))
        let average = Double(recent.reduce(Int64(0)) { $0 + $1.durationS }) / Double(recent.count)
        let deltaMinutes = Int(((Double(latest.durationS) - average) / 60).rounded())
        let label = recent.count >= 7 ? "7-day average" : "\(recent.count)-night average"
        if deltaMinutes == 0 { return "At \(label)" }
        if deltaMinutes > 0 { return "\(deltaMinutes) min above \(label)" }
        return "\(-deltaMinutes) min below \(label)"
    }
}
