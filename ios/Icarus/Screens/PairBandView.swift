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
                LabeledContent("State", value: liveState.connectionText)
                if liveState.isStreaming, let bpm = liveState.latestBPM {
                    LabeledContent("Heart rate") {
                        Text("\(bpm) bpm")
                            .monospacedDigit()
                            .accessibilityIdentifier("pairBand.hr")
                    }
                }
            }

            if liveState.bands.isEmpty {
                Section {
                    Text("No band found")
                } footer: {
                    if hintDue, !liveState.isStreaming {
                        Text("Turn on HR Broadcast in the WHOOP app.")
                            .accessibilityIdentifier("pairBand.hint")
                    }
                }
            } else {
                Section("Found") {
                    ForEach(liveState.bands) { band in
                        Button {
                            liveState.pair(band.id)
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.s4) {
                                Text(band.name ?? "Unnamed band")
                                    .foregroundStyle(.primary)
                                Text("Signal \(band.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
