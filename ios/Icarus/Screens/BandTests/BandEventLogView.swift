import BandProtocol
import Store
import SwiftUI

/// Every event the band has sent, newest first and grouped by day: the time and the event's name. An unnamed id
/// reads "Event 42" with its payload bytes beneath, the material for naming it (Band Tests).
struct BandEventLogView: View {
    let environment: AppEnvironment

    @State private var events: [StoredBandEvent]?

    var body: some View {
        List {
            if let events, events.isEmpty {
                EmptyStateRow(text: "No events yet", actionTitle: nil, action: nil)
            }
            ForEach(days, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.events, id: \.self) { event in
                        EventRow(event: event)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Event Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                for try await value in environment.database.observe({ try $0.bandEvents(limit: 500) }) {
                    events = value
                }
            } catch {
                events = []
            }
        }
    }

    /// Events grouped by local day ("Oct 31"), newest day first.
    private var days: [(day: String, events: [StoredBandEvent])] {
        let groups = Dictionary(grouping: events ?? []) { event in
            Calendar.current.startOfDay(for: Date(epochMs: event.tsMs))
        }
        return groups.keys.sorted(by: >).map { start in
            (start.formatted(.dateTime.month(.abbreviated).day()), groups[start] ?? [])
        }
    }
}

extension StoredBandEvent: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(tsMs)
        hasher.combine(kind)
    }
}

/// One event: its name and time, and for an unnamed id its payload bytes.
private struct EventRow: View {
    let event: StoredBandEvent

    private var kind: BandEventKind? { BandEventKind(storageName: event.kind) }

    private var isUnnamed: Bool {
        if case .unknown? = kind { return true }
        return kind == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack {
                Text(kind?.displayName ?? event.kind)
                Spacer(minLength: Spacing.s8)
                Text(Date(epochMs: event.tsMs), format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if isUnnamed, let hex = event.hex, !hex.isEmpty {
                Text(hex)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
