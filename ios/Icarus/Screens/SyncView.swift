import Store
import SwiftUI
import SyncKit

/// Status, pending rows, batches and the interval setting (PLAN.md 14 row 16). Reached from Settings and from
/// Today's "Last sync" row.
struct SyncView: View {
    let environment: AppEnvironment

    @AppStorage(SyncInterval.storageKey) private var intervalMinutes = SyncInterval.defaultValue.rawValue
    @State private var data: SyncScreenData?

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("State", value: stateText(now: context.date))
                    LabeledContent("Last success", value: lastSuccessText(now: context.date))
                }
                LabeledContent("Pending rows", value: "\(data?.pendingRows ?? 0) rows")
            } footer: {
                if environment.sync.status.clockSkewWarning {
                    Text("This iPhone's clock differs from the server by more than 2 min.")
                }
            }

            Section {
                Picker("Sync every", selection: $intervalMinutes) {
                    ForEach(SyncInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
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
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            HStack {
                                Text(Date(epochMs: row.createdAt), style: .time)
                                Spacer()
                                Text("\(row.rows) rows")
                                    .monospacedDigit()
                            }
                            Text(Self.statusText(row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No batches yet")
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

    private static func statusText(_ row: SyncBatchRow) -> String {
        switch row.status {
        case "acked": return "Synced"
        case "rejected": return "Rejected by the server"
        case "sent": return "Uploading"
        default: return row.error ?? "Waiting"
        }
    }
}
