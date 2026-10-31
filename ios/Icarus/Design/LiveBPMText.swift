import SwiftUI

/// The band's live heart rate as a figure with its unit, or a dash while no sample has arrived. The digits roll only
/// when Reduce Motion is off (and never under UI tests); there is no pulse.
struct LiveBPMText: View {
    let liveState: LiveState
    /// Set only on the leaf value, for UI tests.
    var identifier: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let bpm = liveState.latestBPM {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text("\(bpm)")
                    .font(.figure)
                    .monospacedDigit()
                    .contentTransition(rollsDigits ? .numericText() : .identity)
                    .stateAnimation(bpm)
                    .optionalIdentifier(identifier)
                Text("bpm")
                    .font(.figureUnit)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("—")
                .font(.figure)
                .foregroundStyle(.secondary)
        }
    }

    private var rollsDigits: Bool {
        !reduceMotion && !LaunchConfig.current.isUITest
    }
}
