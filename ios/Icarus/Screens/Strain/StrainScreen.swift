import AlarmKitBridge
import Metrics
import Store
import SwiftUI

/// The Strain tab: today's strain against the Strain Coach target, live heart rate, today's zones, calories and
/// today's workouts. Every row links by `AppRoute`, so the stack that hosts this view must register
/// `appRouteDestinations`. Entry view for the tab (`environment`, `liveState`).
///
/// When `coach.buzzOnTarget` is on, day strain first reaching the target plays the double buzz, once a day.
struct StrainView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var data: StrainModel.Snapshot?
    @State private var buzz = TargetBuzzController()
    @State private var isRecording = false
    @AppStorage(TargetBuzzController.enabledKey) private var buzzOnTarget = false

    var body: some View {
        List {
            Section {
                ring
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.s8)
            }
            Section {
                NavigationLink(value: AppRoute.metric(.heartRate)) {
                    heartRateRow
                }
                NavigationLink(value: AppRoute.metric(.calories)) {
                    MetricRow(kind: .calories, value: caloriesText, unit: "kcal", caption: nil)
                }
            }
            Section("Zones") {
                zones
            }
            Section("Workouts") {
                workoutRows
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Strain")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isRecording = true
                } label: {
                    Image(systemName: Symbol.record)
                }
                .accessibilityLabel("Record activity")
                .accessibilityIdentifier("strain.record")
            }
        }
        .sheet(isPresented: $isRecording) {
            NavigationStack {
                RecordActivityView(environment: environment, liveState: liveState)
            }
        }
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
        let fire = buzz.observe(strain: value.strain, target: target, day: value.coaching.day)
        guard fire, buzzOnTarget else { return }
        guard let rhythm = try? RhythmSpec.builtIn(.double).rhythm() else { return }
        Task { await liveState.runRhythm(rhythm) }
    }

    // MARK: Rows

    private var ring: some View {
        let target = target
        return ScoreDial(
            title: "Strain",
            fraction: (strain ?? 0) / StrainCoach.scaleMax,
            valueText: ActivitiesModel.strainText(strain),
            unit: "of \(Int(StrainCoach.scaleMax))",
            caption: "Target \(Int(target.low))–\(Int(target.high))",
            tint: MetricKind.strain.category.color,
            band: (target.low / StrainCoach.scaleMax)...(target.high / StrainCoach.scaleMax),
            accessibilityValue: "\(ActivitiesModel.strainText(strain)) of 21, target \(Int(target.low)) to \(Int(target.high))"
        )
    }

    /// The only live heart rate in the app. Its value updates from the band; the row opens the heart-rate detail.
    private var heartRateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s12) {
            Image(systemName: MetricKind.heartRate.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MetricKind.heartRate.category.color)
            Text(MetricKind.heartRate.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MetricKind.heartRate.category.color)
            Spacer(minLength: Spacing.s8)
            LiveBPMText(liveState: liveState, identifier: "strain.hrValue")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var zones: some View {
        if let zones = data?.today.zones, zones.contains(where: { $0.minutes > 0 }) {
            ZoneBar(zones: zones)
                .padding(.vertical, Spacing.s4)
        } else {
            EmptyStateRow(text: "No zone time yet", actionTitle: nil, action: nil)
        }
    }

    @ViewBuilder
    private var workoutRows: some View {
        if let data {
            if data.activities.isEmpty {
                EmptyStateRow(text: "No workouts today", actionTitle: "Record") {
                    isRecording = true
                }
            } else {
                ForEach(data.activities, id: \.id) { row in
                    NavigationLink(value: AppRoute.workout(id: row.id)) {
                        ActivityRowView(row: row, timeZone: data.timeZone)
                    }
                }
            }
        }
        NavigationLink(value: AppRoute.workouts) {
            Text("Show all")
        }
    }

    // MARK: Values

    private var target: StrainTarget {
        StrainCoach.target(recoveryPercent: data?.coaching.recoveryPercent)
    }

    private var strain: Double? {
        data?.strain
    }

    private var caloriesText: String? {
        data?.calories.map { Int($0.rounded()).formatted() }
    }
}

/// The Strain tab's view. Kept under its old name so the tab shell compiles until Wave C wires `StrainView`.
typealias StrainScreen = StrainView
