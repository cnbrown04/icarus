import SwiftUI

struct DeviceView: View {
    let liveState: LiveState

    @State private var bandChannelEnabled = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Band", value: "Not paired")
                LabeledContent("State", value: liveState.connectionText)
                LabeledContent("Source", value: liveState.sourceName)
                LabeledContent("Last data") {
                    if let date = liveState.lastDataAt {
                        Text(date, style: .time)
                    } else {
                        Text("None")
                    }
                }
            }

            Section {
                Toggle("Band channel", isOn: $bandChannelEnabled)
                    .disabled(true)
            } header: {
                Text("Experimental")
            } footer: {
                // TODO(PLAN.md §6, Phase 6): enable with the Tier B explainer.
                Text("Not available yet.")
            }
        }
        .navigationTitle("Device")
        .accessibilityIdentifier("tab.device")
    }
}
