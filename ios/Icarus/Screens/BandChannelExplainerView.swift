import SwiftUI

/// Shown before the band channel turns on (PLAN.md 6.2, 19 Phase 6). Plain statements: the protocol comes from
/// community documentation, it carries WHOOP terms risk, WHOOP does not support it, and a firmware update can end it.
/// The owner accepted this risk on 2026-10-08. Nothing is turned on until "Turn on" is tapped.
struct BandChannelExplainerView: View {
    let onTurnOn: () -> Void
    let onCancel: () -> Void

    private static let paragraphs = [
        "The band channel talks to the band's custom Bluetooth service. WHOOP does not document that service. The protocol comes from community research.",
        "WHOOP's terms of use restrict reverse engineering and any use beyond its Services. Turning this on may breach those terms, and WHOOP could act on your account or warranty.",
        "WHOOP does not support this channel. A firmware update can stop it working at any time. Icarus then keeps alarms on the phone.",
        "While the channel is off, Icarus sends nothing on that service.",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Palette.warn)
                    Text("Turn on the band channel?")
                        .font(.title2.weight(.semibold))
                    ForEach(Self.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pagePadding()
                .padding(.vertical, Spacing.s24)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Turn on", action: onTurnOn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .pagePadding()
                    .padding(.vertical, Spacing.s12)
                    .accessibilityIdentifier("bandChannel.turnOn")
            }
            .navigationTitle("Band channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.large])
    }
}
