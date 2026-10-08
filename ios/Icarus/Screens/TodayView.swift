import SwiftUI

/// Destinations pushed from Today's cards (PLAN.md §14 rows 8-10).
enum TodayDestination: Hashable {
    case heartRate
    case stress
    case calories
}

struct TodayView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var snapshot: Dashboard.TodaySnapshot?

    var body: some View {
        List {
            Section {
                NavigationLink(value: TodayDestination.heartRate) {
                    heartRateRow
                }
                if let snapshot, !snapshot.sparkline.isEmpty {
                    HeartRateSparkline(points: snapshot.sparkline)
                        .frame(height: Spacing.s48 * 2)
                }
            } footer: {
                Text("Last 15 min")
            }

            Section {
                NavigationLink(value: TodayDestination.stress) {
                    stressRow
                }

                NavigationLink(value: TodayDestination.calories) {
                    caloriesRow
                }

                LabeledContent("Resting HR") {
                    Text(restingText)
                        .monospacedDigit()
                }
            } footer: {
                if environment.storageFailed {
                    Text("Data is not saved on this launch.")
                }
            }

            Section {
                LabeledContent("Last sync", value: liveState.rememberedID == nil ? "Not paired" : "Not synced")
            }
        }
        .navigationTitle("Today")
        .navigationDestination(for: TodayDestination.self) { destination in
            switch destination {
            case .heartRate: HeartRateDetailView(environment: environment)
            case .stress: StressDetailView(environment: environment)
            case .calories: CaloriesDetailView(environment: environment)
            }
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try Dashboard.today($0, nowMs: clock.nowMs) }) {
                    snapshot = value
                }
            } catch {
                snapshot = nil
            }
        }
    }

    private var heartRateRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                Circle()
                    .fill(liveState.isStreaming ? Color.green : Color.secondary)
                    .frame(width: Spacing.s8, height: Spacing.s8)
                Text(liveState.connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                if let bpm = liveState.latestBPM {
                    Text("\(bpm)")
                        .font(.system(.largeTitle, design: .default).weight(.semibold))
                        .monospacedDigit()
                        .accessibilityIdentifier("today.hrValue")
                    Text("bpm")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text("--")
                        .font(.system(.largeTitle, design: .default).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stressRow: some View {
        LabeledContent("Stress") {
            Text(stressText)
                .monospacedDigit()
                .accessibilityIdentifier("today.stressValue")
        }
    }

    private var caloriesRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            LabeledContent("Calories") {
                Text(caloriesText)
                    .monospacedDigit()
                    .accessibilityIdentifier("today.caloriesValue")
            }
            Text(caloriesCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var restingText: String {
        guard let value = snapshot?.context.restingHR else { return "--" }
        return Format.bpm(value)
    }

    private var stressText: String {
        guard let latest = snapshot?.latestMinute else { return "No data" }
        if let stress = latest.stress {
            return "\(stress) · \(Format.stressBand(stress))"
        }
        return Format.stressState(latest.state)
    }

    private var caloriesText: String {
        guard let total = snapshot?.today?.kcalTotal else { return "--" }
        return Format.kcal(total)
    }

    private var caloriesCaption: String {
        guard snapshot?.context.profile != nil else {
            return "Set a profile to estimate calories"
        }
        guard let active = snapshot?.today?.kcalActive else { return "Estimated" }
        return "\(Format.kcal(active)) active, Estimated"
    }
}
