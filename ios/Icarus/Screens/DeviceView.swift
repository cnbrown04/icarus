import SwiftUI

/// The band: a hero card with its state, then signal, battery and the age of the last reading (IOS_UI_SPEC, Screen 15).
struct DeviceView: View {
    let liveState: LiveState

    @State private var bandChannelEnabled = false
    @State private var confirmsForget = false

    private var bandName: String {
        liveState.bandName ?? "Paired band"
    }

    var body: some View {
        Form {
            if liveState.isCollectionPaused {
                Section {
                    Label("Collection paused: open Icarus", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warn)
                }
            }

            Section {
                VStack(spacing: Spacing.s12) {
                    Image(systemName: "bolt.heart.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Palette.heartRate)
                    Text(liveState.rememberedID == nil ? "Not paired" : bandName)
                        .font(.title3.weight(.semibold))
                    StatusPill.link(liveState)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.s8)
            }

            Section {
                LabeledContent {
                    Text(signalText)
                        .monospacedDigit()
                } label: {
                    Label("Signal", systemImage: "cellularbars")
                }
                LabeledContent {
                    Text(batteryText)
                        .monospacedDigit()
                } label: {
                    Label("Battery", systemImage: batterySymbol)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent {
                        lastDataText
                    } label: {
                        Label("Last data", systemImage: "clock")
                    }
                }
            }

            Section {
                if liveState.rememberedID == nil {
                    NavigationLink {
                        PairBandView(liveState: liveState)
                    } label: {
                        Label("Pair band", systemImage: "plus.circle")
                    }
                } else {
                    Button("Forget band", role: .destructive) {
                        confirmsForget = true
                    }
                }
            }

            Section {
                Toggle(isOn: $bandChannelEnabled) {
                    Label("Band channel", systemImage: "waveform")
                }
                .disabled(true)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Available in a later phase")
            }
        }
        .confirmationDialog("Forget '\(bandName)'?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget band", role: .destructive) {
                liveState.forgetBand()
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationTitle("Device")
    }

    private var signalText: String {
        liveState.connectedRSSI.map { "\($0) dBm" } ?? "--"
    }

    private var batteryText: String {
        liveState.batteryPercent.map { Format.percent($0) } ?? "--"
    }

    private var batterySymbol: String {
        liveState.batteryPercent.map { Format.batterySymbol($0) } ?? "battery.0percent"
    }

    @ViewBuilder
    private var lastDataText: some View {
        if let last = liveState.lastDataAt {
            if let stale = DataAge.staleText(since: last, now: liveState.now) {
                Text(stale)
            } else {
                Text(last, style: .time)
            }
        } else {
            Text("None")
        }
    }
}
