import Store
import SwiftUI
import SyncKit

/// Status, pending rows, batches and the interval setting (PLAN.md 14 row 16). Reached from Settings and from
/// Today's "Band and sync" card.
struct SyncView: View {
    let environment: AppEnvironment

    @AppStorage(SyncInterval.storageKey) private var intervalMinutes = SyncInterval.defaultValue.rawValue
    @State private var data: SyncScreenData?

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.s8) {
                    Text("Status")
                    Spacer(minLength: Spacing.s8)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        StatusPill(
                            text: stateText(now: context.date),
                            symbol: stateSymbol,
                            tint: Palette.sync(environment.sync.status.phase)
                        )
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("Last success", value: lastSuccessText(now: context.date))
                }
                LabeledContent("Pending rows") {
                    Text("\(data?.pendingRows ?? 0) rows")
                        .monospacedDigit()
                }
            } footer: {
                if environment.sync.status.clockSkewWarning {
                    Text("This iPhone's clock differs from the server by more than 2 min.")
                }
            }

            Section {
                Picker(selection: $intervalMinutes) {
                    ForEach(SyncInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
                } label: {
                    Label("Sync every", systemImage: "timer")
                }
            } footer: {
                Text("Also syncs when you pull to refresh on Today.")
            }

            if let quarantined = data?.quarantined, !quarantined.isEmpty {
                Section("Quarantined") {
                    ForEach(quarantined, id: \.batchID) { row in
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            Text("\(row.rows) rows, HTTP \(row.httpStatus ?? 0)")
                                .monospacedDigit()
                            Text(row.error ?? "Rejected by the server")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Batches") {
                if let batches = data?.batches, !batches.isEmpty {
                    ForEach(batches, id: \.batchID) { row in
                        HStack(alignment: .top, spacing: Spacing.s12) {
                            Image(systemName: Self.statusSymbol(row))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Self.statusTint(row))
                                .frame(width: Spacing.s24)
                            VStack(alignment: .leading, spacing: Spacing.s4) {
                                HStack {
                                    Text(Date(epochMs: row.createdAt), style: .time)
                                    Spacer(minLength: Spacing.s8)
                                    Text("\(row.rows) rows")
                                        .monospacedDigit()
                                }
                                Text(Self.statusText(row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No batches yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sync")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sync now") {
                    Task { await environment.sync.runNow() }
                }
                .disabled(environment.sync.isRunning)
                .accessibilityIdentifier("sync.now")
            }
        }
        .task {
            await environment.sync.refresh()
        }
        .task {
            do {
                for try await value in environment.database.observe({ try SyncScreenData.load($0) }) {
                    data = value
                }
            } catch {
                data = nil
            }
        }
    }

    private var stateSymbol: String {
        let sync = environment.sync
        if sync.isRunning { return "arrow.triangle.2.circlepath" }
        switch sync.status.phase {
        case .idle: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .retrying: return "clock"
        case .notPaired: return "minus.circle"
        case .needsRepair: return "exclamationmark.triangle.fill"
        }
    }

    private func stateText(now: Date) -> String {
        let sync = environment.sync
        if sync.isRunning { return "Syncing" }
        switch sync.status.phase {
        case .notPaired: return "Not paired"
        case .idle: return "Up to date"
        case .syncing: return "Syncing"
        case let .retrying(at): return "Retrying in \(max(0, Int(at.timeIntervalSince(now)))) s"
        case .needsRepair: return "Re-pair this iPhone"
        }
    }

    private func lastSuccessText(now: Date) -> String {
        guard let last = environment.sync.status.lastSuccessAt else { return "Never" }
        return DataAge.text(seconds: now.timeIntervalSince(last))
    }

    private static func statusSymbol(_ row: SyncBatchRow) -> String {
        switch row.status {
        case "acked": "checkmark.seal.fill"
        case "rejected": "exclamationmark.triangle.fill"
        case "sent": "arrow.up.circle.fill"
        default: "clock"
        }
    }

    private static func statusTint(_ row: SyncBatchRow) -> Color {
        switch row.status {
        case "acked": Palette.syncOK
        case "rejected": Palette.error
        case "sent": Palette.warn
        default: Palette.neutral
        }
    }

    private static func statusText(_ row: SyncBatchRow) -> String {
        switch row.status {
        case "acked": return "Synced"
        case "rejected": return "Rejected by the server"
        case "sent": return "Uploading"
        default: return row.error ?? "Waiting"
        }
    }
}
