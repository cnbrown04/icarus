import SwiftUI

/// The band sync in progress, as one list row: a determinate bar with the percent when the band reported its
/// backlog (a full sync or catch-up), a spinner otherwise, and the records received so far. Shown only while a
/// drain runs.
struct BandSyncRow: View {
    let liveState: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                Label("Syncing Band Data", systemImage: "arrow.triangle.2.circlepath")
                Spacer(minLength: Spacing.s8)
                if let fraction = liveState.drainProgress.fraction {
                    Text(Format.percent(fraction))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            if let fraction = liveState.drainProgress.fraction {
                ProgressView(value: fraction)
                    .stateAnimation(fraction)
            }
            Text(liveState.drainProgressText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bandSync.progress")
    }
}
