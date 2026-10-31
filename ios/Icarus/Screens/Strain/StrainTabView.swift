import AlarmKitBridge
import Metrics
import Store
import SwiftUI

/// The Strain tab: live heart rate, the day's strain dial with the Strain Coach target, zone time, calories, and
/// an optional activities section. `activitiesSlot` is where the Activities stream plugs in. Nil hides it.
///
/// When `coach.buzzOnTarget` is on, day strain first reaching the target plays the double buzz, once a day.
struct StrainTabView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    var activitiesSlot: AnyView?

    @State private var data: StrainModel.Snapshot?
    @State private var buzz = TargetBuzzController()
    @AppStorage(TargetBuzzController.enabledKey) private var buzzOnTarget = false

    init(environment: AppEnvironment, liveState: LiveState, activitiesSlot: AnyView? = nil) {
        self.environment = environment
        self.liveState = liveState
        self.activitiesSlot = activitiesSlot
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                heroCard
                strainCard
                zonesCard
                caloriesCard
                if let activitiesSlot {
                    activitiesSlot
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Strain")
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try StrainModel.load($0, nowMs: clock.nowMs) }) {
                    data = value
                    considerBuzz(value)
                }
            } catch {
                data = nil
            }
        }
    }

    // MARK: Buzz

    /// Records every observation so the crossing is seen even while the toggle is off. Buzzes only when on.
    private func considerBuzz(_ value: StrainModel.Snapshot) {
        let target = StrainCoach.target(recoveryPercent: value.coaching.recoveryPercent)
        let fire = buzz.observe(strain: value.coaching.todayStrain, target: target, day: value.coaching.day)
        guard fire, buzzOnTarget else { return }
        guard let rhythm = try? RhythmSpec.builtIn(.double).rhythm() else { return }
        Task { await liveState.runRhythm(rhythm) }
    }

    // MARK: Cards

    private var heroCard: some View {
        NavigationLink {
            HeartRateDetailView(environment: environment)
        } label: {
            DashboardCard(
                title: "Heart rate",
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

    private var strainCard: some View {
        DashboardCard(title: "Day strain", symbol: "bolt.fill", tint: Palette.strain) {
            HStack(alignment: .center, spacing: Spacing.s24) {
                StrainDial(strain: coaching?.todayStrain, target: target)
                    .frame(width: Spacing.s48 * 3, height: Spacing.s48 * 3)
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    Text(target.label)
                        .font(.headline)
                    Text(targetLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(recoveryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            Text("Strain is estimated from heart rate. The target is our own heuristic, not WHOOP's.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var zonesCard: some View {
        DashboardCard(title: "Zone time", symbol: "figure.run", tint: .green) {
            if let snapshot = data, !snapshot.zoneTimeline.runs.isEmpty {
                ZoneTimelineChart(
                    timeline: snapshot.zoneTimeline,
                    fromMs: snapshot.dayStartMs,
                    toMs: snapshot.today.context.nowMs
                )
                .frame(height: Spacing.s48 * 2)
                .allowsHitTesting(false)
            }
            if let zones = data?.today.zones, zones.contains(where: { $0.minutes > 0 }) {
                ZoneBar(zones: zones)
            } else {
                Text("No zone time yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caloriesCard: some View {
        DashboardCard(title: "Calories", symbol: "flame.fill", tint: Palette.caloriesActive) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text(caloriesTotal)
                    .font(.metricValue)
                    .monospacedDigit()
                Text("kcal")
                    .font(.metricUnit)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s8)
                Text(caloriesActive)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Estimated")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Values

    private var coaching: CoachingInputs? {
        data?.coaching
    }

    private var target: StrainTarget {
        StrainCoach.target(recoveryPercent: coaching?.recoveryPercent)
    }

    private var targetLine: String {
        "Target \(Int(target.low))–\(Int(target.high))"
    }

    private var recoveryLine: String {
        if let recovery = coaching?.recoveryPercent {
            return "Recovery \(Int(recovery.rounded())) %"
        }
        return "Recovery calibrating"
    }

    private var caloriesTotal: String {
        guard let total = data?.today.today?.kcalTotal else { return "--" }
        return "\(Int(total.rounded()))"
    }

    private var caloriesActive: String {
        guard let active = data?.today.today?.kcalActive else { return "" }
        return "\(Int(active.rounded())) kcal active"
    }

    private var sparklinePoints: [HRPoint] {
        let raw = (data?.today.sparkline ?? []).map { HRPoint(date: $0.date, bpm: Double($0.bpm)) }
        return HRPoint.averaged(raw, bucket: 15)
    }

    private var rangeText: String {
        let values = (data?.today.sparkline ?? []).map(\.bpm)
        guard let low = values.min(), let high = values.max() else { return "No samples in the last 15 minutes" }
        return "Range \(low) to \(high) bpm"
    }

    /// One compact line under the live chart: today's average, maximum and coverage.
    private var heroSummary: String {
        guard let snapshot = data?.today else { return "No summary yet" }
        guard snapshot.hrAvg != nil || snapshot.hrMax != nil else { return "No heart rate yet" }
        let average = snapshot.hrAvg.map { "\(Int($0.rounded()))" } ?? "--"
        let maximum = snapshot.hrMax.map { "\($0)" } ?? "--"
        return "Avg \(average) · Max \(maximum) bpm · \(Format.percent(snapshot.coverage)) coverage"
    }

    // TODO(shell): the live bpm number duplicates TodayView.bpmText. Move it into a shared component when the
    // Shell stream extracts Today's hero, so the two cannot drift.
    @ViewBuilder
    private var bpmText: some View {
        if let bpm = liveState.latestBPM {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text("\(bpm)")
                    .font(.heroValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .stateAnimation(bpm)
                    .accessibilityIdentifier("strain.hrValue")
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
}
