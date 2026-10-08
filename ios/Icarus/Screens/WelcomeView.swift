import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s32) {
            Spacer()
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 72, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.heartRate)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text("Icarus")
                    .font(.largeTitle.weight(.bold))
                Text("Live heart rate from your band, stored on this iPhone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.s16) {
                FeatureRow(symbol: "waveform.path.ecg", tint: Palette.heartRate, title: "Live heart rate")
                FeatureRow(symbol: "gauge.with.dots.needle.67percent", tint: Palette.stressModerate, title: "Stress and HRV")
                FeatureRow(symbol: "alarm.fill", tint: Palette.sleep, title: "Alarms on your wrist")
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

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: Spacing.s16) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: Spacing.s48)
            Text(title)
                .font(.body)
        }
    }
}
