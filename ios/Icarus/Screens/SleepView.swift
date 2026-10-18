import Metrics
import SwiftUI

/// The last 7 nights of derived sleep sessions (PLAN.md 8.1, 10.2 v2). Sessions come from the band's
/// offloaded history (PLAN.md 5.3.4), so the list stays empty until a sync has drained it.
struct SleepView: View {
    let environment: AppEnvironment

    @State private var snapshot: Dashboard.SleepSnapshot?

    var body: some View {
        List {
            if let nights = snapshot?.nights, !nights.isEmpty {
                ForEach(nights) { night in
                    nightSection(night)
                }
            } else {
                Section {
                    Text("Sleep appears once the band has synced its history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep")
        .task {
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.sleep(db, nowMs: nowMs)
            }) {
                snapshot = value
            }
        }
    }

    // MARK: Nights

    private func nightSection(_ night: Dashboard.SleepSnapshot.Night) -> some View {
        Section {
            LabeledContent("Duration") {
                Text(Format.duration(night.durationS))
                    .monospacedDigit()
            }
            LabeledContent("Quality") {
                Text(Format.sleepQuality(night.quality))
                    .foregroundStyle(Palette.sleepQuality(night.quality))
            }
            LabeledContent("Median HR") {
                Text(night.restingHR.map { Format.number($0, unit: "bpm") } ?? "--")
                    .monospacedDigit()
            }
            LabeledContent("RMSSD") {
                Text(night.rmssdMs.map { Format.number($0, unit: "ms") } ?? "--")
                    .monospacedDigit()
            }
        } header: {
            // The night is labelled by the day it started (PLAN.md 8.1's evening-to-morning window).
            Text(Date(epochMs: night.startMs), style: .date)
        }
    }
}
