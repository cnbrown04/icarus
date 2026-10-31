import Metrics
import SwiftUI

/// The per-metric sections under a detail page's details: zones for heart rate, contributors for recovery, the
/// active and resting split for calories, and one calibration row for stress until it is calibrated. Every other
/// metric has none.
struct MetricSpecificSections: View {
    let data: MetricDetailData

    var body: some View {
        switch data.kind {
        case .heartRate:
            if data.zones.contains(where: { $0.minutes > 0 }) {
                Section("Zones") {
                    ZoneBar(zones: data.zones)
                        .padding(.vertical, Spacing.s4)
                }
            }
        case .recovery:
            if let snapshot = data.snapshot {
                // Same calibration line as Summary's ring caption, so both screens agree the score is provisional.
                if case let .scored(score)? = snapshot.scores.recovery, score.hrvBaseline.nValid < Recovery.minNightsTrust {
                    Section {
                        Text("Calibrating · \(score.hrvBaseline.nValid) of \(Recovery.minNightsTrust) nights")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Contributors") {
                    ContributorRows(snapshot: snapshot, day: snapshot.day)
                }
            }
        case .calories:
            if let calories = data.calories, calories.total != nil || calories.active != nil {
                Section("Today") {
                    LabeledRow(title: "Active", value: calories.active.map { MetricFormat.withUnit($0, .calories) } ?? "—")
                    LabeledRow(title: "Resting", value: restingText(calories))
                }
            }
        case .stress:
            if let calibration = data.calibration, !calibration.isCalibrated {
                Section {
                    Text("Calibrating · \(calibration.qualifyingDays) of \(calibration.requiredDays) days")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .hrv, .restingHR, .respiratoryRate, .strain, .sleep:
            EmptyView()
        }
    }

    private func restingText(_ calories: CaloriesSplit) -> String {
        guard let total = calories.total, let active = calories.active else { return "—" }
        // From the rounded figures, so Active and Resting add up to the Total shown above them.
        return MetricFormat.withUnit(max(total.rounded() - active.rounded(), 0), .calories)
    }
}

/// A title and a right-aligned value on one list row.
struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: Spacing.s8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }
}

/// Recovery's contributors: each vital tonight against its 30-night reference, and sleep performance against the
/// median of the prior nights in the window. One row notes a stimulant active near sleep onset.
private struct ContributorRows: View {
    let snapshot: HealthSnapshot
    let day: LocalDay

    var body: some View {
        vitalRow(.hrv)
        vitalRow(.restingHR)
        vitalRow(.respiratoryRate)
        sleepPerformanceRow
        if snapshot.scores.stimulantNearSleepOnset == true {
            Text("Stimulant active within 1 h of sleep onset")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// One vital: tonight, the 30-night reference it is judged against, and the difference.
    private func vitalRow(_ vital: HealthMonitor.Vital) -> some View {
        let tonight = snapshot.vitals.tonight[vital]
        let reference = snapshot.vitals.baselines[vital]?.center
        return ContributorRow(
            title: vital.title,
            tonight: tonight.map(vital.text) ?? "—",
            reference: reference.map { "30-night \(vital.text($0))" },
            delta: difference(tonight, reference),
            deltaUnit: vital.unit
        )
    }

    /// Sleep performance has no personal range in `HealthMonitor`, so its reference is the median of the prior
    /// days in the window (needs `HealthMonitor.minimumNights` of them).
    private var sleepPerformanceRow: some View {
        let tonight = snapshot.scores.sleep?.performancePct
        let prior = snapshot.series.filter { $0.day != day }.compactMap(\.sleepPerformance)
        let reference = prior.count >= HealthMonitor.minimumNights ? HealthMonitor.median(prior) : nil
        return ContributorRow(
            title: "Sleep Performance",
            tonight: tonight.map { Format.percent(Int($0.rounded())) } ?? "—",
            reference: reference.map { "\(prior.count)-night \(Format.percent(Int($0.rounded())))" },
            delta: difference(tonight, reference),
            deltaUnit: "%"
        )
    }

    private func difference(_ value: Double?, _ reference: Double?) -> Double? {
        guard let value, let reference else { return nil }
        return value - reference
    }
}

/// A contributor: its name, tonight's value, the reference and the change against it.
private struct ContributorRow: View {
    let title: String
    let tonight: String
    let reference: String?
    let delta: Double?
    let deltaUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Spacing.s8)
                Text(tonight)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: Spacing.s8) {
                if let reference {
                    Text(reference)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.s8)
                if let delta {
                    DeltaChip(change: delta, unit: deltaUnit)
                }
            }
            .font(.footnote)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
