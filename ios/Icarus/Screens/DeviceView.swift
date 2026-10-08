import SwiftUI

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
                    Text("Collection paused: open Icarus")
                        .font(.body.weight(.semibold))
                }
            }

            Section {
                LabeledContent("Band", value: liveState.rememberedID == nil ? "Not paired" : bandName)
                LabeledContent("State", value: liveState.connectionText)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    lastDataRow
                }
            }

            Section {
                if liveState.rememberedID == nil {
                    NavigationLink("Pair band") {
                        PairBandView(liveState: liveState)
                    }
                } else {
                    Button("Forget band", role: .destructive) {
                        confirmsForget = true
                    }
                }
            }

            Section {
                Toggle("Band channel", isOn: $bandChannelEnabled)
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

    @ViewBuilder
    private var lastDataRow: some View {
        LabeledContent("Last data") {
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
}
