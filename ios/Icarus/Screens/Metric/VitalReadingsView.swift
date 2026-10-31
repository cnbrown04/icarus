import Metrics
import Store
import SwiftUI

/// Every reading behind a nightly vital, as Apple Health's "Show All Data": one section per night, newest first,
/// headed by the date, the sleep's span and the night's value, with that night's window readings listed newest
/// first. A night's readings load when its section scrolls into view.
struct VitalReadingsView: View {
    let kind: MetricKind
    let environment: AppEnvironment

    @State private var nights: [VitalNight]?
    @State private var timeZone: TimeZone = .current

    /// Half a year of nights, the same reach as the 6M chart.
    private static let nightLimit = 182

    var body: some View {
        List {
            if let nights, nights.isEmpty {
                EmptyStateRow(text: "No nights recorded yet", actionTitle: nil, action: nil)
            }
            ForEach(nights ?? []) { night in
                Section {
                    NightReadingRows(kind: kind, night: night, timeZone: timeZone, environment: environment)
                } header: {
                    Text(header(night))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("All Recorded Data")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let kind = kind
            let nowMs = environment.clock.nowMs
            let loaded = try? await environment.database.writer.read { db in
                let zone = try Dashboard.Context.load(db, nowMs: nowMs).timeZone
                return (zone, try db.vitalNights(kind, nowMs: nowMs, limit: Self.nightLimit, in: zone))
            }
            if let loaded {
                timeZone = loaded.0
                nights = loaded.1
            } else {
                nights = []
            }
        }
    }

    /// "Oct 31 · 01:33–12:20 · 62 bpm".
    private func header(_ night: VitalNight) -> String {
        let date = MetricFormat.shortDate(night.day, in: timeZone)
        let span = "\(Format.clock(night.startMs, in: timeZone))–\(Format.clock(night.endMs, in: timeZone))"
        guard let value = night.value else { return "\(date) · \(span)" }
        return "\(date) · \(span) · \(MetricFormat.withUnit(value, kind))"
    }
}

/// One night's readings: the value on the left and its time on the right, newest first.
private struct NightReadingRows: View {
    let kind: MetricKind
    let night: VitalNight
    let timeZone: TimeZone
    let environment: AppEnvironment

    @State private var readings: [MetricPoint]?

    var body: some View {
        Group {
            if let readings {
                if readings.isEmpty {
                    Text("No readings")
                        .foregroundStyle(.secondary)
                }
                ForEach(readings.reversed(), id: \.tsMs) { reading in
                    HStack {
                        Text(MetricFormat.withUnit(reading.value, kind))
                            .monospacedDigit()
                        Spacer(minLength: Spacing.s8)
                        Text(Format.clock(reading.tsMs, in: timeZone))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: night.id) {
            let kind = kind
            let night = night
            readings = (try? await environment.database.writer.read { db in
                try db.nightReadings(kind, night: night)
            }) ?? []
        }
    }
}
