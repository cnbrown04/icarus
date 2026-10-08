import Charts
import SwiftUI

/// Stress over the last 24 h, with RMSSD and sqrt(Baevsky SI) (PLAN.md §14 row 9).
struct StressDetailView: View {
    let environment: AppEnvironment

    @State private var snapshot: Dashboard.StressSnapshot?
    @State private var showsMethod = false

    var body: some View {
        List {
            Section {
                LabeledContent("Now", value: currentText)
            }

            Section("Last 24 h") {
                chart
                    .frame(height: Spacing.s48 * 3)
            }

            Section("Measures") {
                LabeledContent("RMSSD", value: snapshot?.rmssd.map(Format.ms) ?? "--")
                    .monospacedDigit()
                LabeledContent("Sqrt Baevsky SI", value: snapshot?.baevskySqrt.map(Self.decimal) ?? "--")
                    .monospacedDigit()
            }

            Section {
                Button("How stress is estimated") {
                    showsMethod = true
                }
            }
        }
        .navigationTitle("Stress")
        .task {
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try Dashboard.stress(db, nowMs: nowMs)
            }) {
                snapshot = value
            }
        }
        .sheet(isPresented: $showsMethod) {
            StressMethodSheet()
        }
    }

    private var currentText: String {
        guard let latest = snapshot?.latest else { return "No data" }
        if let stress = latest.stress {
            return "\(stress) · \(Format.stressBand(stress))"
        }
        return Format.stressState(latest.state)
    }

    @ViewBuilder
    private var chart: some View {
        if let points = snapshot?.points, !points.isEmpty {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Stress", point.stress)
                )
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .accessibilityLabel("Stress, last 24 hours")
        } else {
            Text("No stress values yet")
                .foregroundStyle(.secondary)
        }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Method and caveats (PLAN.md §8.3), shown from a row rather than as a page subtitle (PLAN.md §15.1).
private struct StressMethodSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Method") {
                    Text("Stress compares your heart rate and RMSSD in 5-minute windows with your own nights from the last 14 days.")
                    Text("Values need 7 days of nights before they appear. Until then the state reads Calibrating.")
                }
                Section("Limits") {
                    Text("Band readings are less precise than an ECG. Motion adds noise. Windows above 40 % heart-rate reserve are excluded as exertion.")
                    Text("Caffeine, alcohol, illness and posture also change HRV.")
                    Text("This is an estimate, not WHOOP's Stress Monitor, and not a medical measure.")
                }
            }
            .navigationTitle("Stress method")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
