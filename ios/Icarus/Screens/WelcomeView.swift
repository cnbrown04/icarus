import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s32) {
            Spacer()
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text("Icarus")
                    .font(.largeTitle.weight(.bold))
                Text("Live heart rate from your band, stored on this iPhone")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.s16) {
                FeatureRow(symbol: Symbol.heartRate, title: "Live heart rate")
                FeatureRow(symbol: Symbol.stress, title: "Stress and HRV")
                FeatureRow(symbol: Symbol.alarms, title: "Alarms on your wrist")
            }
            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("welcome.continue")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .pagePadding()
        .padding(.vertical, Spacing.s24)
    }
}

/// A feature as plain text, with a secondary symbol in a fixed-width column so the labels line up.
private struct FeatureRow: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Spacing.s24)
                .accessibilityHidden(true)
            Text(title)
        }
    }
}
