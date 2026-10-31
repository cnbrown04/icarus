import Foundation
import Metrics
import Store
import SwiftUI
import SyncKit

/// The first tab. A day pager (Today, Yesterday, or a date) over three score dials and the day's cards. Dials open
/// the tab or screen that owns the detail. Cards hold what the morning dashboard showed: the journal prompt, the
/// Health Monitor summary, activities, the sleep planner (today only), the next alarm, the server sync line and the
/// weekly assessment.
struct OverviewView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let selectTab: (AppTab) -> Void
    let openJournal: () -> Void
    let openAlarms: () -> Void
    let openSettings: () -> Void

    /// Days before today. 0 is today; the pager never goes past it.
    @State private var daysBack = 0
    @State private var snapshot: OverviewSnapshot?

    var body: some View {
        ScrollView {
            // The clock text, sync age and next alarm all move with the minute, not only with store writes.
            TimelineView(.everyMinute) { _ in
                VStack(alignment: .leading, spacing: Spacing.s24) {
                    if environment.sync.status.phase == .needsRepair {
                        repairCard
                    }
                    if environment.storageFailed {
                        storageCard
                    }
                    StatusPill.link(liveState)
                    if let snapshot {
                        dials(snapshot)
                        if snapshot.journalPrompt {
                            journalPromptCard
                        }
                        healthMonitorCard(snapshot)
                        ActivitiesSection(environment: environment, day: snapshot.day)
                        if snapshot.isToday {
                            SleepPlannerCard(environment: environment)
                        }
                    }
                    alarmRow
                    syncFooter
                    weeklyAssessmentCard
                }
                .pagePadding()
                .padding(.vertical, Spacing.s8)
            }
        }
        .dashboardBackground()
        .simultaneousGesture(swipeToStepDays)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    daysBack += 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous day")
                .accessibilityIdentifier("overview.previousDay")

                Button {
                    daysBack = max(daysBack - 1, 0)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(daysBack == 0)
                .accessibilityLabel("Next day")
                .accessibilityIdentifier("overview.nextDay")
            }
        }
        .refreshable {
            await environment.sync.runNow()
        }
        .task(id: daysBack) {
            let back = daysBack
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ db in
                    try OverviewSnapshot.load(db, nowMs: clock.nowMs, daysBack: back)
                }) {
                    snapshot = value
                }
            } catch {
                snapshot = nil
            }
        }
    }

    // MARK: Day pager

    private var title: String {
        switch daysBack {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            guard let snapshot else { return "" }
            return Self.dayLabel(snapshot.day, in: snapshot.health.timeZone)
        }
    }

    /// "Mon, Oct 27" in the profile's zone.
    private static func dayLabel(_ day: LocalDay, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: Date(epochMs: LocalTime.localTime(day, hour: 12, in: zone)))
    }

    /// A horizontal swipe steps a day: right goes back, left goes forward (not past today).
    private var swipeToStepDays: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let horizontal = abs(value.translation.width)
                guard horizontal > abs(value.translation.height) * 1.5 else { return }
                if value.translation.width > 0 {
                    daysBack += 1
                } else {
                    daysBack = max(daysBack - 1, 0)
                }
            }
    }

    // MARK: Dials

    /// Sleep, recovery and strain in one row. Each dial opens its own detail.
    private func dials(_ snapshot: OverviewSnapshot) -> some View {
        HStack(alignment: .top, spacing: Spacing.s12) {
            sleepDial(snapshot)
            recoveryDial(snapshot)
            strainDial(snapshot)
        }
    }

    private func sleepDial(_ snapshot: OverviewSnapshot) -> some View {
        let sleep = snapshot.health.scores.sleep
        let performance = sleep?.performancePct
        return Button {
            selectTab(.sleep)
        } label: {
            ScoreDial(
                title: "Sleep",
                fraction: (performance ?? 0) / 100,
                valueText: performance.map { "\(Int($0.rounded()))" } ?? "—",
                unit: performance == nil ? nil : "%",
                caption: sleep.map { "Asleep \(Format.duration(Int64($0.asleepSec.rounded())))" } ?? "No sleep yet",
                tint: Palette.sleep,
                accessibilityValue: performance.map { "\(Int($0.rounded())) percent" } ?? "No sleep yet"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens sleep")
    }

    private func recoveryDial(_ snapshot: OverviewSnapshot) -> some View {
        let readout = RecoveryReadout(outcome: snapshot.health.scores.recovery)
        return NavigationLink {
            RecoveryDetailView(environment: environment, liveState: liveState, day: snapshot.day)
        } label: {
            ScoreDial(
                title: "Recovery",
                fraction: readout.fraction,
                valueText: readout.value,
                unit: readout.hasScore ? "%" : nil,
                caption: readout.caption,
                tint: readout.tint,
                accessibilityValue: readout.summary
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens recovery")
    }

    /// The Strain Coach target band is drawn only when recovery is scored; otherwise the dial shows strain alone.
    private func strainDial(_ snapshot: OverviewSnapshot) -> some View {
        let strain = snapshot.health.scores.strain?.whoopScale
        let target = recoveryPercent(snapshot).map { StrainCoach.target(recoveryPercent: $0) }
        let scale = StrainCoach.scaleMax
        let band = target.map { target -> ClosedRange<Double> in
            let low = min(max(target.low / scale, 0), 1)
            return low...min(max(target.high / scale, low), 1)
        }
        let valueText = strain.map { String(format: "%.1f", $0) } ?? "—"
        let caption: String
        if let target {
            caption = "\(target.label), target \(Int(target.low))–\(Int(target.high))"
        } else {
            caption = strain == nil ? "No data yet" : "Recovery calibrating"
        }
        return Button {
            selectTab(.strain)
        } label: {
            ScoreDial(
                title: "Strain",
                fraction: (strain ?? 0) / scale,
                valueText: valueText,
                unit: strain == nil ? nil : "of 21",
                caption: caption,
                tint: Palette.strain,
                band: band,
                accessibilityValue: strain.map { String(format: "%.1f of 21, ", $0) + caption } ?? "No data yet"
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens strain")
    }

    private func recoveryPercent(_ snapshot: OverviewSnapshot) -> Double? {
        if case let .scored(score)? = snapshot.health.scores.recovery { return score.score }
        return nil
    }

    // MARK: Cards

    private var journalPromptCard: some View {
        Button(action: openJournal) {
            DashboardCard(title: "Log yesterday", symbol: "book.closed.fill", tint: Palette.sleep, showsChevron: true) {
                Text("Yesterday's check-in has no answers yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the journal")
    }

    private func healthMonitorCard(_ snapshot: OverviewSnapshot) -> some View {
        NavigationLink {
            HealthMonitorView(environment: environment, liveState: liveState, day: snapshot.day)
        } label: {
            DashboardCard(title: "Health Monitor", symbol: "waveform.path.ecg", tint: Palette.heartRate, showsChevron: true) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(monitorHeadline(snapshot))
                        .font(.metricValue)
                        .monospacedDigit()
                    Text(monitorCaption(snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Health Monitor")
    }

    private func monitorHeadline(_ snapshot: OverviewSnapshot) -> String {
        let summary = HealthMonitor.summary(snapshot.health.vitals.statuses)
        guard summary.evaluated > 0 else { return "Calibrating" }
        return "\(summary.inRange) of \(summary.evaluated) in range"
    }

    private func monitorCaption(_ snapshot: OverviewSnapshot) -> String {
        let vitals = snapshot.health.vitals
        if vitals.tonight.isEmpty {
            return "No main sleep ended on this day"
        }
        if HealthMonitor.summary(vitals.statuses).evaluated == 0 {
            return "\(vitals.priorNights)/\(HealthMonitor.minimumNights) nights for a personal range"
        }
        return "Tonight against your last \(HealthMonitor.baselineNights) nights"
    }

    private var weeklyAssessmentCard: some View {
        NavigationLink {
            WeeklyAssessmentView(environment: environment)
        } label: {
            DashboardCard(title: "Weekly assessment", symbol: "calendar", tint: Palette.sleep, showsChevron: true) {
                Text("Last 7 days against the 7 before")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the weekly assessment")
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
        let now = environment.clock.now
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
