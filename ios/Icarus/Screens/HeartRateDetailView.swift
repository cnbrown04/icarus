import Charts
import SwiftUI

/// Heart rate over 1 h to 7 d, with zones and min, average and max (PLAN.md §14 row 8).
struct HeartRateDetailView: View {
    let environment: AppEnvironment

    @State private var range: Dashboard.HeartRateRange = .hour
    @State private var snapshot: Dashboard.HeartRateSnapshot?

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(Dashboard.HeartRateRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                chart
                    .frame(height: Spacing.s48 * 3)
            }

            Section("Summary") {
                LabeledContent("Min", value: snapshot?.minimum.map { Format.bpm($0) } ?? "--")
                LabeledContent("Average", value: snapshot?.average.map { Format.bpm($0) } ?? "--")
                LabeledContent("Max", value: snapshot?.maximum.map { Format.bpm($0) } ?? "--")
            }

            Section {
                if let zones = snapshot?.zones, !zones.isEmpty {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, entry in
                        LabeledContent(Format.zoneLabel(entry.zone), value: Format.minutes(entry.minutes))
                            .monospacedDigit()
                    }
                } else {
                    Text("Set a profile to see zones")
                }
            } header: {
                Text("Zones")
            } footer: {
                Text("Zones are a share of heart-rate reserve, from last night's resting HR.")
            }
        }
        .navigationTitle("Heart rate")
        .task(id: range) {
            let selected = range
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try Dashboard.heartRate(db, nowMs: nowMs, range: selected)
            }) {
                snapshot = value
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let buckets = snapshot?.buckets, !buckets.isEmpty {
            Chart(buckets, id: \.startMs) { bucket in
                LineMark(
                    x: .value("Time", Date(epochMs: bucket.startMs)),
                    y: .value("Average heart rate", bucket.avg)
                )
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .accessibilityLabel(summary)
        } else {
            Text("No heart rate in this range")
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        guard let snapshot, let average = snapshot.average else { return "Heart rate, no data" }
        return "Heart rate, average \(Format.bpm(average))"
    }
}
