import SwiftUI

/// The band's live heart rate as a large number with its unit, or a dash while no sample has arrived.
/// Shared so every live readout animates and reads the same way (it used to be duplicated between Today and Strain).
struct LiveBPMText: View {
    let liveState: LiveState
    /// Set only on the leaf value, for UI tests.
    var identifier: String?

    var body: some View {
        if let bpm = liveState.latestBPM {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text("\(bpm)")
                    .font(.heroValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .stateAnimation(bpm)
                    .optionalIdentifier(identifier)
                Text("bpm")
                    .font(.metricUnit)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("--")
                .font(.heroValue)
                .foregroundStyle(.secondary)
        }
    }
}
