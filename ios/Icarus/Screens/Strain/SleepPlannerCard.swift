import Metrics
import Store
import SwiftUI

/// Tonight's bedtimes for Peak, Perform and Get by, given the wake time and tonight's need. The card names where the
/// wake time came from. Our heuristic: see `SleepPlanner`.
struct SleepPlannerCard: View {
    let environment: AppEnvironment

    @State private var data: CoachingModel.Snapshot?

    var body: some View {
        DashboardCard(title: "Sleep planner", symbol: "moon.zzz.fill", tint: Palette.sleep) {
            if let data {
                content(data)
            } else {
                Text("No wake time yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try CoachingModel.load($0, nowMs: clock.nowMs) }) {
                    data = value
                }
            } catch {
                data = nil
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: CoachingModel.Snapshot) -> some View {
        let inputs = snapshot.inputs
        let zone = snapshot.timeZone
        if let wake = inputs.wake {
            let plans = SleepPlanner.plans(wakeSec: wake.wakeSec, needSec: inputs.tonightNeedSec, timing: inputs.timing)
            VStack(alignment: .leading, spacing: Spacing.s12) {
                ForEach(plans, id: \.target) { plan in
                    planRow(plan, zone: zone)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text("Wake \(Format.clock(wake.wakeSec * 1000, in: zone)), \(sourceText(wake.source, zone: zone, wakeSec: wake.wakeSec))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(needLine(inputs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if inputs.timing.isDefault {
                    Text("Estimated: no staged nights yet, so typical latency and efficiency are used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No wake time. Set an alarm to plan bedtimes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func planRow(_ plan: SleepPlanner.Plan, zone: TimeZone) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(plan.target.label)
                    .font(.subheadline.weight(.semibold))
                Text("\(Int(plan.target.fraction * 100)) % · \(Format.duration(plan.timeInBedSec)) in bed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Spacing.s8)
            Text(Format.clock(plan.bedtimeSec * 1000, in: zone))
                .font(.metricValue)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func needLine(_ inputs: CoachingInputs) -> String {
        var parts = ["Need \(Format.duration(Int64(inputs.tonightNeedSec.rounded())))"]
        if inputs.carriedDebtSec > 0 {
            parts.append("includes \(Format.duration(Int64(inputs.carriedDebtSec.rounded()))) of debt")
        }
        return parts.joined(separator: ", ")
    }

    /// "from 6:30 AM alarm", or "from the median of the last 7 nights" when no alarm is within a day.
    private func sourceText(_ source: WakePlan.Source, zone: TimeZone, wakeSec: Int64) -> String {
        switch source {
        case .alarm:
            "from \(Format.clock(wakeSec * 1000, in: zone)) alarm"
        case let .medianOfRecentWakes(nights):
            "from the median of the last \(nights) nights"
        }
    }
}
