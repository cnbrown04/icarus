import Metrics
import Store
import SwiftUI

/// Tonight's nightly vitals against the user's own 30-night range: a summary ("3 of 4 in range") and one
/// row per vital with its typical band and tonight's marker. Vitals without enough nights say so.
struct HealthMonitorView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let day: LocalDay

    @State private var snapshot: HealthSnapshot?

    private var statuses: [HealthMonitor.Status] {
        snapshot?.vitals.statuses ?? []
    }

    private var summary: HealthMonitor.Summary {
        HealthMonitor.summary(statuses)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s24) {
                summaryCard
                if snapshot != nil {
                    vitalsCard
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
            .redacted(reason: snapshot == nil ? .placeholder : [])
        }
        .dashboardBackground()
        .navigationTitle("Health Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
        }
        .task {
            let day = day
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try HealthSnapshot.load(db, nowMs: nowMs, day: day, seriesDays: 0)
            }) {
                snapshot = value
            }
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            if let snapshot, snapshot.vitals.tonight.isEmpty {
                Text("No main sleep ended on \(snapshot.dayLabel).")
                    .font(.headline)
                Text("Vitals come from the night's sleep, so they appear after the band syncs it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Sync now") {
                    Task { await environment.sync.runNow() }
                }
                .buttonStyle(.bordered)
                .padding(.top, Spacing.s4)
            } else if summary.evaluated == 0 {
                Text("Calibrating")
                    .font(.headline)
                Text("\(snapshot?.vitals.priorNights ?? 0)/\(HealthMonitor.minimumNights) nights. A personal range needs \(HealthMonitor.minimumNights) nights with a value.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(summary.inRange) of \(summary.evaluated) in range")
                    .font(.metricValue)
                    .monospacedDigit()
                Text("Tonight against your last \(HealthMonitor.baselineNights) nights")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }

    // MARK: Vitals

    private var vitalsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            ForEach(statuses) { status in
                if status.vital != statuses.first?.vital {
                    Divider()
                }
                VitalRow(status: status, priorNights: snapshot?.vitals.priorNights ?? 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }
}

/// One vital: its name, tonight's value, the typical range, the state and a range bar.
private struct VitalRow: View {
    let status: HealthMonitor.Status
    let priorNights: Int

    private var vital: HealthMonitor.Vital { status.vital }

    /// Tonight as shown: the value, or the deviation from the mean for skin temperature.
    private var tonightText: String {
        guard let shown = shownTonight else { return "—" }
        return vital.isRelative ? "\(vital.text(shown)) \(vital.unit)" : vital.text(shown)
    }

    /// The value in display units. Skin temperature shows the deviation, not the raw mean.
    private var shownTonight: Double? {
        if vital.isRelative { return status.deviation }
        return status.tonight
    }

    private var rangeText: String? {
        guard let baseline = status.baseline else { return nil }
        let offset = vital.isRelative ? baseline.center : 0
        let low = vital.text(baseline.low - offset)
        let high = vital.text(baseline.high - offset)
        let typical = vital.isRelative ? "\(low) to \(high) \(vital.unit)" : "\(low) to \(high)"
        return "Typical \(typical)"
    }

    private var stateText: String {
        switch status.state {
        case .inRange: "In range"
        case .above: "Above range"
        case .below: "Below range"
        case .noTonight: "No value tonight"
        case .calibrating: "Calibrating · \(priorNights)/\(HealthMonitor.minimumNights) nights"
        }
    }

    private var stateTint: Color {
        switch status.state {
        case .above, .below: Palette.warn
        case .inRange: Palette.syncOK
        case .noTonight, .calibrating: Palette.neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(vital.title)
                    .font(.headline)
                Spacer(minLength: Spacing.s8)
                Text(tonightText)
                    .font(.metricValue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let baseline = status.baseline, let value = shownTonight {
                VitalRangeBar(
                    low: baseline.low - (vital.isRelative ? baseline.center : 0),
                    high: baseline.high - (vital.isRelative ? baseline.center : 0),
                    value: value,
                    inRange: status.state == .inRange
                )
                .padding(.vertical, Spacing.s4)
            }
            HStack(spacing: Spacing.s8) {
                Text(stateText)
                    .foregroundStyle(stateTint)
                Spacer(minLength: Spacing.s8)
                if let rangeText {
                    Text(rangeText)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A horizontal bar for a personal range: the typical band shaded, tonight's value as a marker. The scale runs
/// past the band and the marker, so an out-of-range value is still visible.
struct VitalRangeBar: View {
    let low: Double
    let high: Double
    let value: Double
    let inRange: Bool

    private let trackHeight = Spacing.s8
    private let markerSize = Spacing.s16

    var body: some View {
        GeometryReader { proxy in
            let scale = scaleBounds
            let width = proxy.size.width
            let bandStart = fraction(low, in: scale) * width
            let bandEnd = fraction(high, in: scale) * width
            let markerX = fraction(value, in: scale) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: max(bandEnd - bandStart, trackHeight), height: trackHeight)
                    .offset(x: bandStart)
                Circle()
                    .fill(inRange ? Palette.syncOK : Palette.warn)
                    .frame(width: markerSize, height: markerSize)
                    .offset(x: min(max(markerX - markerSize / 2, 0), width - markerSize))
            }
            .frame(height: markerSize)
        }
        .frame(height: markerSize)
        .accessibilityHidden(true)
    }

    /// The band, widened by its own width on each side, and the value when it falls outside.
    private var scaleBounds: ClosedRange<Double> {
        let width = max(high - low, 1)
        let lower = min(low, value) - width / 2
        let upper = max(high, value) + width / 2
        return lower...max(upper, lower + 1)
    }

    private func fraction(_ x: Double, in scale: ClosedRange<Double>) -> Double {
        (x - scale.lowerBound) / (scale.upperBound - scale.lowerBound)
    }
}
