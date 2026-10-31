import Metrics
import Store
import SwiftUI

/// Tonight's nightly vitals against the user's own 30-night range, as an inset list: a summary ("3 of 4 in range")
/// and one row per vital with its typical band and tonight's marker. Each vital with a metric opens that metric's
/// detail page. Vitals without enough nights say so.
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
        List {
            summarySection
            if snapshot != nil {
                Section {
                    ForEach(statuses) { status in
                        VitalRowLink(status: status, priorNights: snapshot?.vitals.priorNights ?? 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: snapshot == nil ? .placeholder : [])
        .navigationTitle("Vitals")
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

    @ViewBuilder private var summarySection: some View {
        Section {
            if let snapshot, snapshot.vitals.tonight.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    Text("No main sleep ended on \(snapshot.dayLabel)")
                        .font(.subheadline)
                    EmptyStateRow(
                        text: "Vitals come from the night's sleep, so they appear after the band syncs it.",
                        actionTitle: "Sync Now"
                    ) {
                        Task { await environment.sync.runNow() }
                    }
                }
            } else if summary.evaluated == 0 {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text("Calibrating")
                        .font(.figure)
                    Text("\(snapshot?.vitals.priorNights ?? 0) of \(HealthMonitor.minimumNights) nights for a personal range")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text("\(summary.inRange) of \(summary.evaluated) in range")
                        .font(.figure)
                        .monospacedDigit()
                    Text("Tonight against your last \(HealthMonitor.baselineNights) nights")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The metric a vital's row opens, or nil for a vital with no metric page (skin temperature).
private func metricKind(for vital: HealthMonitor.Vital) -> MetricKind? {
    switch vital {
    case .restingHR: .restingHR
    case .hrv: .hrv
    case .respiratoryRate: .respiratoryRate
    case .skinTemp: nil
    }
}

/// One vital row: its name and tonight's value, the range bar, and the state word with the typical range. A row
/// with a metric links to that metric's page.
private struct VitalRowLink: View {
    let status: HealthMonitor.Status
    let priorNights: Int

    var body: some View {
        if let kind = metricKind(for: status.vital) {
            NavigationLink(value: AppRoute.metric(kind)) {
                VitalRow(status: status, priorNights: priorNights)
            }
        } else {
            VitalRow(status: status, priorNights: priorNights)
        }
    }
}

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
        return "Typical \(low) to \(high)"
    }

    private var stateText: String {
        switch status.state {
        case .inRange: "In range"
        case .above: "Above range"
        case .below: "Below range"
        case .noTonight: "No value tonight"
        case .calibrating: "Calibrating · \(priorNights) of \(HealthMonitor.minimumNights) nights"
        }
    }

    private var stateTint: Color {
        switch status.state {
        case .above, .below: Palette.warn
        case .inRange, .noTonight, .calibrating: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(vital.title)
                    .font(.body)
                Spacer(minLength: Spacing.s8)
                Text(tonightText)
                    .font(.figure)
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
            .font(.footnote)
            .monospacedDigit()
        }
        .padding(.vertical, Spacing.s4)
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
