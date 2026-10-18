import BandKit
import SwiftUI

/// Scans for bands, connects to the one the user picks, and confirms the first heart-rate value
/// (PLAN.md §14 row 5). Reached from onboarding and from the Device screen.
struct PairBandView: View {
    let liveState: LiveState
    /// Set during onboarding. Nil when pushed from Device, where Done simply goes back.
    var onFinish: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var hintDue = false

    /// After this long with no band found, one line explains HR Broadcast (PLAN.md §5.3.1).
    private static let hintDelay: Duration = .seconds(20)

    var body: some View {
        List {
            Section {
                scanningRow
            }

            if liveState.bands.isEmpty {
                Section {
                    Text("No band found")
                        .foregroundStyle(.secondary)
                }
                if hintDue, !liveState.isStreaming {
                    Section {
                        Label {
                            Text("Turn on HR Broadcast in the WHOOP app.")
                                .accessibilityIdentifier("pairBand.hint")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .listRowBackground(Color.blue.opacity(0.12))
                }
            } else {
                Section("Found") {
                    ForEach(liveState.bands) { band in
                        Button {
                            liveState.pair(band.id)
                        } label: {
                            HStack(spacing: Spacing.s12) {
                                VStack(alignment: .leading, spacing: Spacing.s4) {
                                    Text(band.name ?? "Unnamed band")
                                        .foregroundStyle(.primary)
                                    Text("\(band.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Spacing.s8)
                                Image(systemName: "cellularbars", variableValue: Self.signalLevel(band.rssi))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.blue)
                            }
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityIdentifier("pairBand.row")
                    }
                }
            }
        }
        .navigationTitle("Pair band")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(finishTitle, action: finish)
                    .accessibilityIdentifier("pairBand.finish")
            }
        }
        .task {
            try? await Task.sleep(for: Self.hintDelay)
            hintDue = true
        }
    }

    private var scanningRow: some View {
        HStack(spacing: Spacing.s16) {
            if liveState.isStreaming {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.syncOK)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(liveState.connectionText)
                    .font(.headline)
                if liveState.isStreaming, let bpm = liveState.latestBPM {
                    Text("\(bpm) bpm")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pairBand.hr")
                }
            }
        }
    }

    /// Bars for a signal in dBm, from about -100 (empty) to -40 (full).
    private static func signalLevel(_ rssi: Int) -> Double {
        Double(min(max(rssi + 100, 0), 60)) / 60
    }

    private var finishTitle: String {
        onFinish != nil && !liveState.isStreaming ? "Skip" : "Done"
    }

    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }
}
