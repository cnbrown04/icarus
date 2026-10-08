import AlarmKitBridge
import BandKit
import BandProtocol
import SwiftUI

/// The band: a hero card with its state, then signal, battery and the age of the last reading (IOS_UI_SPEC, Screen 15).
/// The Experimental section holds the band channel (Tier B). Turning it on needs the explainer's "Turn on" first.
struct DeviceView: View {
    let liveState: LiveState

    @State private var bandChannelEnabled = BandChannel.isEnabled
    @State private var showsExplainer = false
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
                Toggle(isOn: bandChannelBinding) {
                    Label("Band channel", systemImage: "waveform")
                }
                .accessibilityIdentifier("device.bandChannel")
                LabeledContent {
                    tierBPill
                } label: {
                    Text("Channel status")
                }
                LabeledContent {
                    lastBandEventText
                } label: {
                    Label("Last band event", systemImage: "hand.tap")
                }
                Button("Test buzz") {
                    playTestBuzz()
                }
                .disabled(liveState.tierBState != .ready)
                .accessibilityIdentifier("device.testBuzz")
            } header: {
                Text("Experimental")
            } footer: {
                Text("Band alarms depend on the band clock. The phone alarm is always armed too.")
            }
        }
        .sheet(isPresented: $showsExplainer) {
            BandChannelExplainerView(
                onTurnOn: {
                    showsExplainer = false
                    setBandChannel(true)
                },
                onCancel: {
                    showsExplainer = false
                }
            )
        }
        .confirmationDialog("Forget '\(bandName)'?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget band", role: .destructive) {
                liveState.forgetBand()
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationTitle("Device")
    }

    /// Off switches the channel at once. On only opens the explainer, and the switch moves when "Turn on" is tapped.
    private var bandChannelBinding: Binding<Bool> {
        Binding(
            get: { bandChannelEnabled },
            set: { newValue in
                if newValue {
                    showsExplainer = true
                } else {
                    setBandChannel(false)
                }
            }
        )
    }

    private func setBandChannel(_ enabled: Bool) {
        BandChannel.set(enabled)
        bandChannelEnabled = enabled
        Task { await liveState.setTierBEnabled(enabled) }
    }

    private func playTestBuzz() {
        guard let double = try? RhythmSpec.builtIn(.double).rhythm() else { return }
        Task { await liveState.runRhythm(double) }
    }

    private var tierBPill: StatusPill {
        switch liveState.tierBState {
        case .disabled:
            StatusPill(text: "Off", symbol: "pause.circle", tint: Palette.neutral)
        case .awaitingLink:
            StatusPill(text: "Waiting for band", symbol: "antenna.radiowaves.left.and.right", tint: Palette.warn)
        case .handshaking:
            StatusPill(text: "Connecting", symbol: "arrow.triangle.2.circlepath", tint: Palette.warn)
        case .ready:
            StatusPill(text: "Ready", symbol: "checkmark.seal.fill", tint: Palette.syncOK)
        case .unavailable:
            StatusPill(text: "Unavailable", symbol: "exclamationmark.triangle.fill", tint: Palette.error)
        }
    }

    @ViewBuilder
    private var lastBandEventText: some View {
        if let kind = liveState.lastBandEvent, let at = liveState.lastBandEventAt {
            HStack(spacing: Spacing.s4) {
                Text(Self.eventName(kind))
                Text(at, style: .time)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("None")
        }
    }

    private static func eventName(_ kind: BandEventKind) -> String {
        switch kind {
        case .wristOn: "Wrist on"
        case .wristOff: "Wrist off"
        case .doubleTap: "Double tap"
        default: "Other event"
        }
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
