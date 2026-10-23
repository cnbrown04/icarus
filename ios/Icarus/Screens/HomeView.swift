import Foundation
import Metrics
import Store
import SwiftUI
import SyncKit

/// Everything Home reads in one store snapshot. Sleep is derived from the band's offloaded history,
/// so it rides along with today's numbers to keep the cards on the same read.
private struct HomeSnapshot: Sendable {
    let today: Dashboard.TodaySnapshot
    let sleep: Dashboard.SleepSnapshot
    let calibration: StressCalibrationProgress
    /// Today's scores; strain accrues all day even when no night ended today.
    let todayScores: DailyScores
}

/// The morning dashboard: last night, today's vitals, activity and the next alarm. Home is a summary
/// and a launcher; the detailed charts stay on Today and the metric detail screens.
struct HomeView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let openAlarms: () -> Void
    let openSettings: () -> Void

    @State private var snapshot: HomeSnapshot?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            // The clock text, sync age and next alarm all move with the minute, not only with store writes.
            TimelineView(.everyMinute) { _ in
                VStack(alignment: .leading, spacing: Spacing.s24) {
                    greetingHeader
                    scoresRow
                    lastNightCard
                    vitalsRow
                    activityCard
                    alarmRow
                    syncFooter
                }
                .pagePadding()
                .padding(.vertical, Spacing.s8)
            }
        }
        .dashboardBackground()
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ db in
                    let now = clock.nowMs
                    let today = try Dashboard.today(db, nowMs: now)
                    return HomeSnapshot(
                        today: today,
                        sleep: try Dashboard.sleep(db, nowMs: now),
                        calibration: try Dashboard.stressCalibration(db, nowMs: now, context: today.context),
                        todayScores: try db.dailyScores(day: today.context.today, in: today.context.timeZone)
                    )
                }) {
                    snapshot = value
                }
            } catch {
                snapshot = nil
            }
        }
    }

    // MARK: Header

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(greeting)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    dateLabel
                    StatusPill.link(liveState)
                }
            } else {
                HStack(spacing: Spacing.s8) {
                    dateLabel
                    Spacer(minLength: Spacing.s8)
                    StatusPill.link(liveState)
                }
            }
        }
        .padding(.top, Spacing.s8)
    }

    private var dateLabel: some View {
        Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var now: Date {
        environment.clock.now
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    // MARK: Last night

    private var lastNightCard: some View {
        NavigationLink {
            SleepView(environment: environment)
        } label: {
            DashboardCard(
                title: "Last night",
                symbol: "moon.zzz.fill",
                tint: Palette.sleep,
                showsChevron: true
            ) {
                if let night = snapshot?.sleep.latest {
                    VStack(alignment: .leading, spacing: Spacing.s8) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                            Text(Format.duration(night.asleepS))
                                .font(.metricValue)
                                .monospacedDigit()
                            Spacer(minLength: Spacing.s8)
                            Text(Format.sleepQuality(night.quality))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.sleepQuality(night.quality))
                        }
                        HStack(spacing: Spacing.s8) {
                            Text(sleepWindow(night))
                            Spacer(minLength: Spacing.s8)
                            Text("RHR \(night.restingHR.map { Format.bpm($0) } ?? "--")")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                        if night.isStaged {
                            SleepStageBar(totals: night.stageTotals)
                        } else {
                            Text("Stages not yet computed — sync to update")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No sleep yet — wear the band overnight.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last night")
        .accessibilityValue(sleepAccessibilityValue)
        .accessibilityHint("Opens sleep")
    }

    private var sleepAccessibilityValue: String {
        guard let night = snapshot?.sleep.latest else {
            return "No sleep recorded yet. Wear the band overnight."
        }
        let rhr = night.restingHR.map { Format.bpm($0) } ?? "resting heart rate unavailable"
        var value = "\(Format.duration(night.asleepS)) asleep, \(Format.sleepQuality(night.quality)), "
            + "\(sleepWindow(night)), \(rhr)"
        if night.isStaged {
            value += ", \(SleepStageTotals.accessibleSummary(night.stageTotals))"
            if let efficiency = night.efficiency {
                value += ", \(Format.percent(efficiency)) time asleep"
            }
        } else {
            value += ", stages not yet computed"
        }
        return value
    }

    private var sleepTimeZone: TimeZone {
        snapshot?.sleep.context.timeZone ?? Dashboard.fallbackZone
    }

    private func sleepWindow(_ night: Dashboard.SleepSnapshot.Night) -> String {
        let wakeMs = night.startMs + night.durationS * 1_000
        return "\(Format.clock(night.startMs, in: sleepTimeZone)) – \(Format.clock(wakeMs, in: sleepTimeZone))"
    }

    // MARK: Recovery and strain

    private var scores: DailyScores? {
        snapshot?.sleep.latestScores
    }

    /// Recovery from last night and today's strain, side by side (stacked at the largest text sizes).
    private var scoresRow: some View {
        Group {
            if dynamicTypeSize >= .xxxLarge {
                VStack(spacing: Spacing.s8) { scoreTiles }
            } else {
                HStack(alignment: .top, spacing: Spacing.s8) { scoreTiles }
            }
        }
    }

    @ViewBuilder
    private var scoreTiles: some View {
        NavigationLink {
            SleepView(environment: environment)
        } label: {
            HomeVitalTile(
                title: "Recovery",
                symbol: "bolt.heart.fill",
                tint: recoveryTint,
                value: recoveryValue,
                unit: recoveryScore == nil ? nil : "%",
                caption: recoveryCaption,
                accessibilityLabel: "Recovery",
                accessibilityValue: "\(recoveryValue) percent, \(recoveryCaption)"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens sleep")

        NavigationLink {
            HeartRateDetailView(environment: environment)
        } label: {
            HomeVitalTile(
                title: "Strain",
                symbol: "flame.fill",
                tint: Palette.strain,
                value: strainValue,
                unit: todayStrain == nil ? nil : "/ 21",
                caption: todayStrain == nil ? "No data yet" : "Today so far",
                accessibilityLabel: "Strain",
                accessibilityValue: todayStrain == nil ? "No data yet" : "\(strainValue) of 21, today so far"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens heart rate")
    }

    /// Recovery needs 14 baseline nights before it is trusted (OpenStrap's bar; NOOP scores from 4).
    private static let recoveryTrustedNights = 14

    private var recoveryScore: Recovery.Score? {
        if case let .scored(score) = scores?.recovery { return score }
        return nil
    }

    private var recoveryValue: String {
        recoveryScore.map { "\(Int($0.score.rounded()))" } ?? "—"
    }

    private var recoveryCaption: String {
        switch scores?.recovery {
        case let .scored(score)?:
            let nights = score.hrvBaseline.nValid
            return nights < Self.recoveryTrustedNights ? "Calibrating · \(nights)/\(Self.recoveryTrustedNights) nights" : "From last night"
        case let .insufficientBaseline(_, validNights)?:
            return "Calibrating · \(validNights)/\(Self.recoveryTrustedNights) nights"
        case nil:
            return "No night yet"
        }
    }

    private var recoveryTint: Color {
        recoveryScore.map { Palette.recovery($0.band) } ?? Palette.neutral
    }

    private var todayStrain: DayStrain? {
        snapshot?.todayScores.strain
    }

    private var strainValue: String {
        todayStrain.map { String(format: "%.1f", $0.whoopScale) } ?? "—"
    }

    // MARK: Vitals

    /// Three tiles across when they fit; one per line by the largest standard text size.
    private var vitalsRow: some View {
        Group {
            if dynamicTypeSize >= .xxxLarge {
                VStack(spacing: Spacing.s8) {
                    vitalTiles
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.s8) {
                    vitalTiles
                }
            }
        }
    }

    @ViewBuilder
    private var vitalTiles: some View {
        NavigationLink {
            HeartRateDetailView(environment: environment)
        } label: {
            HomeVitalTile(
                title: "Resting HR",
                symbol: "heart.fill",
                tint: Palette.sleep,
                value: restingHRText,
                unit: restingHR == nil ? nil : "bpm",
                caption: restingHR == nil ? "No data yet" : "Overnight low",
                accessibilityLabel: "Resting heart rate",
                accessibilityValue: restingHRAccessibilityValue
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens heart rate")

        NavigationLink {
            StressDetailView(environment: environment)
        } label: {
            HomeVitalTile(
                title: "HRV",
                symbol: "waveform.path.ecg",
                tint: Palette.hrv,
                value: hrvText,
                unit: rmssd == nil ? nil : "ms",
                caption: rmssd == nil ? "No data yet" : "RMSSD",
                accessibilityLabel: "Heart rate variability",
                accessibilityValue: hrvAccessibilityValue
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens stress")

        NavigationLink {
            StressDetailView(environment: environment)
        } label: {
            HomeVitalTile(
                title: "Stress",
                symbol: "gauge.with.dots.needle.67percent",
                tint: stressTint,
                value: stressValue,
                caption: stressCaption,
                captionTint: stressCaptionTint,
                accessibilityLabel: "Stress",
                accessibilityValue: stressAccessibilityValue
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens stress")
    }

    private var restingHR: Double? {
        snapshot?.today.today?.restingHR ?? snapshot?.today.context.restingHR
    }

    private var rmssd: Double? {
        snapshot?.today.today?.rmssdNight
    }

    private var restingHRText: String {
        restingHR.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private var restingHRAccessibilityValue: String {
        guard let restingHR else { return "No data yet" }
        return "\(Format.bpm(restingHR)), overnight low"
    }

    private var hrvText: String {
        rmssd.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private var hrvAccessibilityValue: String {
        guard let rmssd else { return "No data yet" }
        return "\(Format.ms(rmssd)), last night"
    }

    /// The newest stress value, else today's mean when the current window has not scored.
    private var latestStress: Int? {
        if let current = snapshot?.today.latestMinute?.stress {
            return current
        }
        guard let average = snapshot?.today.stressDay.average else { return nil }
        return Int(average.rounded())
    }

    private var stressState: StressState? {
        snapshot?.today.latestMinute?.state
    }

    private var stressValue: String {
        latestStress.map { "\($0)" } ?? "—"
    }

    /// One line: the band when there is a value, otherwise the shortest honest state.
    private var stressCaption: String {
        if let latestStress {
            return Format.stressBand(latestStress)
        }
        if stressState == .exertion {
            return "Exertion"
        }
        if stressState == .hrOnly {
            return "HR only"
        }
        if calibration.nights.isEmpty {
            return "No baseline"
        }
        if !calibration.isCalibrated {
            return "Calibrating \(calibration.qualifyingDays)/\(calibration.requiredDays)"
        }
        return "No value yet"
    }

    private var stressTint: Color {
        latestStress.map { Palette.stress(StressBand.of(stress: $0)) } ?? Palette.stressModerate
    }

    private var stressCaptionTint: Color? {
        if let latestStress {
            return Palette.stress(StressBand.of(stress: latestStress))
        }
        if stressState == .exertion || stressState == .hrOnly {
            return Palette.warn
        }
        if !calibration.nights.isEmpty, !calibration.isCalibrated {
            return Palette.warn
        }
        return nil
    }

    private var stressAccessibilityValue: String {
        if let latestStress {
            return "\(latestStress), \(Format.stressBand(latestStress))"
        }
        if stressState == .exertion {
            return "Not scored during exertion"
        }
        if stressState == .hrOnly {
            return "Heart rate only, no R-R baseline"
        }
        if calibration.nights.isEmpty {
            return "No baseline"
        }
        if !calibration.isCalibrated {
            return "Calibrating, \(calibration.qualifyingDays) of \(calibration.requiredDays) nights"
        }
        return "No value yet"
    }

    private var calibration: StressCalibrationProgress {
        snapshot?.calibration ?? .unavailable
    }

    // MARK: Activity

    private var activityCard: some View {
        NavigationLink {
            CaloriesDetailView(environment: environment)
        } label: {
            DashboardCard(
                title: "Today's activity",
                symbol: "figure.run",
                tint: .green,
                showsChevron: true
            ) {
                if hasZones || hasCalories {
                    VStack(alignment: .leading, spacing: Spacing.s12) {
                        if hasZones {
                            ZoneBar(zones: populatedZones)
                        }
                        if hasZones, hasCalories {
                            Divider()
                        }
                        if let total = todayCalories {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                                Text(Format.kcal(total))
                                    .font(.metricValue)
                                    .monospacedDigit()
                                Spacer(minLength: Spacing.s8)
                                if let active = snapshot?.today.today?.kcalActive {
                                    Text("\(Format.kcal(active)) active")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            Text("Estimated")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No activity yet today.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's activity")
        .accessibilityValue(activityAccessibilityValue)
        .accessibilityHint("Opens calories")
    }

    private var populatedZones: [ZoneMinutes] {
        snapshot?.today.zones.filter { $0.minutes > 0 } ?? []
    }

    private var hasZones: Bool {
        !populatedZones.isEmpty
    }

    private var todayCalories: Double? {
        snapshot?.today.today?.kcalTotal
    }

    private var hasCalories: Bool {
        todayCalories != nil
    }

    private var activityAccessibilityValue: String {
        var parts: [String] = []
        for zone in populatedZones {
            parts.append("\(Format.minutes(zone.minutes)) in \(Format.zoneLabel(zone.zone))")
        }
        if let total = todayCalories {
            var calories = "\(Format.kcal(total)) total"
            if let active = snapshot?.today.today?.kcalActive {
                calories += ", \(Format.kcal(active)) active"
            }
            parts.append("\(calories), estimated")
        }
        return parts.isEmpty ? "No activity yet today" : parts.joined(separator: ". ")
    }

    // MARK: Next alarm

    private var nextAlarm: (item: AlarmItem, fire: Date)? {
        let now = environment.clock.now
        return environment.alarms.items
            .filter(\.enabled)
            .compactMap { item in item.nextFire(after: now).map { (item: item, fire: $0) } }
            .min { $0.fire < $1.fire }
    }

    private var alarmRow: some View {
        HomeActionRow(
            symbol: "alarm.fill",
            tint: Palette.sleep,
            title: "Next alarm",
            value: alarmValue,
            caption: alarmCaption,
            isMuted: nextAlarm == nil,
            action: openAlarms
        )
        .accessibilityLabel("Next alarm")
        .accessibilityValue(alarmAccessibilityValue)
        .accessibilityHint("Opens alarms")
    }

    private var alarmValue: String {
        guard let nextAlarm else { return "No alarms" }
        return nextAlarm.fire.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var alarmCaption: String? {
        guard let nextAlarm else {
            return environment.alarms.items.isEmpty ? "Tap to add one" : "No enabled alarms"
        }
        return "\(nextAlarm.item.label) · \(nextAlarm.item.repeatText)"
    }

    private var alarmAccessibilityValue: String {
        guard let nextAlarm else { return "No alarms" }
        let fire = nextAlarm.fire.formatted(.dateTime.weekday(.wide).hour().minute())
        return "\(nextAlarm.item.label), \(fire), \(nextAlarm.item.repeatText)"
    }

    // MARK: Sync footer

    private var syncFooter: some View {
        Button(action: openSettings) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Palette.sync(environment.sync.status.phase))
                    .accessibilityHidden(true)
                Text(syncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.s8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.s4)
            .frame(minHeight: Spacing.s48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Server sync")
        .accessibilityValue(syncText)
        .accessibilityHint("Opens settings")
    }

    private var syncText: String {
        let sync = environment.sync
        if sync.isRunning {
            return "Server syncing"
        }
        switch sync.status.phase {
        case .notPaired:
            return "Server not paired"
        case .idle:
            guard let last = sync.status.lastSuccessAt else { return "Server up to date" }
            return "Server synced \(DataAge.text(seconds: now.timeIntervalSince(last)))"
        case .syncing:
            return "Server syncing"
        case let .retrying(at):
            return "Server retrying in \(max(0, Int(at.timeIntervalSince(now)))) s"
        case .needsRepair:
            return "Server needs re-pairing"
        }
    }
}
