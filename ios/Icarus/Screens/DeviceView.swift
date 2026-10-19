import AlarmKitBridge
import BandKit
import BandProtocol
import SwiftUI

/// The band: a hero card with its state, then signal, battery and the age of the last reading (IOS_UI_SPEC, Screen 15).
/// The Experimental section holds the band channel (Tier B). Turning it on needs the explainer's "Turn on" first.
struct DeviceView: View {
    let liveState: LiveState

    @State private var bandChannelEnabled = BandChannel.isEnabled
    @AppStorage(AlarmCoordinator.opportunisticPullKey) private var opportunisticPull = false
    @AppStorage(BandChannel.floodDisabledKey) private var floodDisabled = false
    @State private var showsExplainer = false
    @State private var confirmsForget = false
    @State private var showsRestore = false
    @State private var drainingRestore = false
    @State private var restoreSummary: String?

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
                    // A plain tinted Label renders naturally in the Form's centered stack; the
                    // capsule pill fought the row height and alignment here.
                    Label(liveState.connectionText, systemImage: liveState.connectionSymbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.link(liveState.state))
                    if let bpm = liveState.latestBPM {
                        Text("\(bpm) bpm")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
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
                if let battery = liveState.batteryPercent {
                    LabeledContent {
                        Text(Format.percent(battery))
                            .monospacedDigit()
                    } label: {
                        Label("Battery", systemImage: Format.batterySymbol(battery))
                    }
                } else if liveState.tierBState == .disabled {
                    LabeledContent {
                        Text("Needs band channel")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Battery", systemImage: "battery.0percent")
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent {
                        lastDataText
                    } label: {
                        Label("Last data", systemImage: "clock")
                    }
                }
                // Identity the band reported in its bandInfo event (PLAN.md §14 row 15).
                LabeledContent {
                    Text(liveState.bandInfo?.firmwareVersion ?? "--")
                } label: {
                    Label("Firmware", systemImage: "cpu")
                }
                if let serial = liveState.bandInfo?.serial {
                    LabeledContent {
                        Text(serial)
                    } label: {
                        Label("Serial", systemImage: "barcode")
                    }
                }
            }

            Section {
                if liveState.rememberedID == nil {
                    NavigationLink {
                        PairBandView(liveState: liveState)
                    } label: {
                        Label("Pair Band", systemImage: "plus.circle")
                    }
                } else {
                    Button("Forget Band", role: .destructive) {
                        confirmsForget = true
                    }
                }
            }

            Section {
                Button("Drain full band history…") {
                    showsRestore = true
                }
                .disabled(liveState.tierBState != .ready || drainingRestore)
                .accessibilityIdentifier("device.drainFullHistory")
                if drainingRestore {
                    LabeledContent {
                        HStack(spacing: Spacing.s8) {
                            ProgressView()
                            Text("Draining…")
                        }
                    } label: {
                        Label("Restore", systemImage: "arrow.counterclockwise")
                    }
                } else if let restoreSummary {
                    LabeledContent {
                        Text(restoreSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } label: {
                        Label("Restore", systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Re-reads everything the band has in storage and rebuilds heart rate, sleep and the graphs from it. Use after deleting the app, or whenever history looks wrong. The band keeps roughly the last day and a half.")
            }

            Section {
                Toggle(isOn: bandChannelBinding) {
                    Label("Band Channel", systemImage: "waveform")
                }
                .accessibilityIdentifier("device.bandChannel")
                LabeledContent {
                    Text(tierBStateText)
                        .foregroundStyle(tierBStateTint)
                } label: {
                    Label("Channel status", systemImage: "dot.radiowaves.left.and.right")
                }
                if liveState.tierBState == .unavailable, let reason = liveState.tierBFailure {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Palette.error)
                }
                LabeledContent {
                    lastBandEventText
                } label: {
                    Label("Last band event", systemImage: "hand.tap")
                }
                Button("Test Buzz") {
                    playTestBuzz()
                }
                .disabled(liveState.tierBState != .ready)
                .accessibilityIdentifier("device.testBuzz")
                Toggle(isOn: $opportunisticPull) {
                    Label("Opportunistic alarm pull", systemImage: "bell.badge")
                }
                .accessibilityIdentifier("device.opportunisticPull")
                Toggle(isOn: $floodDisabled) {
                    Label("Disable raw sensor flood", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
                .accessibilityIdentifier("device.floodDisabled")
                .onChange(of: floodDisabled) { _, disabled in
                    Task { await liveState.setHandshakeRealtimeRawFloodDisabled(disabled) }
                }
            } header: {
                Text("Experimental")
            } footer: {
                Text("Band alarms depend on the band clock. The phone alarm is always armed too. The alarm pull checks the server for pending alarms while the band is awake; it only matters while alarm push is unavailable. Disabling the raw sensor flood speeds up history drains, but the off form of that command is unverified and may affect the strap's own history banking — leave it off unless debugging.")
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
            Button("Forget Band", role: .destructive) {
                liveState.forgetBand()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Drain the band's full history?",
            isPresented: $showsRestore,
            titleVisibility: .visible
        ) {
            Button("Drain full history") {
                startRestore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The band's stored history is re-read and everything already stored dedupes. Draining a full ring takes a few minutes; live readings keep flowing.")
        }
        .navigationTitle("Band")
    }

    /// Runs the full-history restore with UI state: the button disables while it runs, and the
    /// one-line controller summary lands when it finishes.
    private func startRestore() {
        drainingRestore = true
        restoreSummary = nil
        Task {
            await liveState.drainFullHistory()
            restoreSummary = await liveState.fullHistorySummary() ?? "finished"
            drainingRestore = false
        }
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

    private var tierBStateText: String {
        switch liveState.tierBState {
        case .disabled: "Off"
        case .awaitingLink: "Waiting for band"
        case .handshaking: "Connecting"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }

    private var tierBStateTint: Color {
        switch liveState.tierBState {
        case .disabled: Palette.neutral
        case .awaitingLink, .handshaking: Palette.warn
        case .ready: Palette.syncOK
        case .unavailable: Palette.error
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
