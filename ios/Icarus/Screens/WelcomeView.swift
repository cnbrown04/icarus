import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Spacer()
            Text("Icarus")
                .font(.largeTitle.weight(.semibold))
            Text("Live heart rate from your band, stored on this iPhone.")
                .font(.body)
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("welcome.continue")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .pagePadding()
        .accessibilityIdentifier("welcome.screen")
    }
}
