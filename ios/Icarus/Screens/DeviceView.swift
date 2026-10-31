import AlarmKitBridge
import BandKit
import BandProtocol
import SwiftUI

/// The band: its name and link state, then signal, battery and the age of the last reading (IOS_UI_SPEC, Screen 15).
/// The Experimental section holds the band channel (Tier B). Turning it on needs the explainer's "Turn On" first.
struct DeviceView: View {
    let liveState: LiveState

    @State private var bandChannelEnabled = BandChannel.isEnabled
    @AppStorage(AlarmCoordinator.opportunisticPullKey) private var opportunisticPull = false
    @AppStorage(BandChannel.floodDisabledKey) private var floodDisabled = false
    @State private var showsExplainer = false
    @State private var confirmsForget = false
    @State private var showsRestore = false
    /// The last restore's one-line result, read once the restore returns.
    @State private var restoreSummary: String?
    /// True from the tap until the sync returns, so the row reacts before the band's first reply.
    @State private var isSyncing = false

    private var bandName: String {
        liveState.bandName ?? "Paired Band"
    }

    var body: some View {
        Form {
            if liveState.isCollectionPaused {
                Section {
                    Label("Collection paused: open Icarus", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Palette.warn)
                }
            }

            Section {
                VStack(spacing: Spacing.s8) {
                    Text(liveState.rememberedID == nil ? "Not paired" : bandName)
                        .font(.title3.weight(.semibold))
                    Label(liveState.connectionText, systemImage: liveState.connectionSymbol)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.link(liveState.state))
                    if let bpm = liveState.latestBPM {
                        Text(Format.bpm(bpm))
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
                        Text(batteryText(battery))
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
                        Label("Last Data", systemImage: "clock")
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent {
                        linkText
                    } label: {
                        Label("Link", systemImage: "link")
                    }
                }
                // Identity the band reported in its bandInfo event (PLAN.md §14 row 15).
                LabeledContent {
                    Text(liveState.bandInfo?.firmwareVersion ?? "—")
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
                Button("Sync All Pending Band Data…") {
                    showsRestore = true
                }
                .disabled(liveState.tierBState != .ready || liveState.drainProgress.isDraining || isSyncing)
                .accessibilityIdentifier("device.drainFullHistory")
                // Every drain — the connect drain, the 15-minute cadence and the manual restore —
                // drives the same live state, so the row updates in place instead of appearing
                // only when the graphs catch up later.
                // One status row: the title on top and its detail on a left-aligned line below, so long progress
                // text never wraps into a ragged right-aligned block. A finished manual sync's summary replaces
                // the routine "Synced" line rather than sitting in a second row.
                if isSyncing || liveState.drainProgress.isDraining {
                    // Shown from the tap itself, before the band has answered, so a sync is never silent.
                    historyRow(
                        "Syncing",
                        detail: liveState.drainProgress.isDraining ? liveState.drainProgressText : "Checking the band…",
                        systemImage: "arrow.triangle.2.circlepath",
                        progress: liveState.drainProgress.isDraining ? liveState.drainProgress.fraction : nil,
                        inProgress: true
                    )
                    .accessibilityIdentifier("device.drainProgress")
                } else if let detail = restoreSummary ?? (liveState.drainProgress.lastEndedAt != nil
                    ? liveState.drainProgressText : nil) {
                    historyRow("Last Sync", detail: detail, systemImage: "checkmark.circle", progress: nil, inProgress: false)
                        .accessibilityIdentifier("device.drainProgress")
                }
            } header: {
                Text("History")
            }

            Section {
                Toggle(isOn: bandChannelBinding) {
                    Label("Band Channel", systemImage: Symbol.band)
                }
                .accessibilityIdentifier("device.bandChannel")
                LabeledContent {
                    Text(tierBStateText)
                        .foregroundStyle(tierBStateTint)
                } label: {
                    Label("Channel Status", systemImage: "dot.radiowaves.left.and.right")
                }
                if liveState.tierBState == .unavailable, let reason = liveState.tierBFailure {
                    Text(reason)
                        .foregroundStyle(Palette.error)
                }
                LabeledContent {
                    lastBandEventText
                } label: {
                    Label("Last Band Event", systemImage: "hand.tap")
                }
                Button("Test Buzz") {
                    playTestBuzz()
                }
                .disabled(liveState.tierBState != .ready)
                .accessibilityIdentifier("device.testBuzz")
                Toggle(isOn: $opportunisticPull) {
                    Label("Opportunistic Alarm Pull", systemImage: "bell.badge")
                }
                .accessibilityIdentifier("device.opportunisticPull")
                Toggle(isOn: $floodDisabled) {
                    Label("Disable Raw Sensor Flood", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
                .accessibilityIdentifier("device.floodDisabled")
                .onChange(of: floodDisabled) { _, disabled in
                    Task { await liveState.setHandshakeRealtimeRawFloodDisabled(disabled) }
                }
            } header: {
                Text("Experimental")
            } footer: {
                Text("The off form of the raw sensor flood command is unverified and may affect the band's own history banking. Leave it off unless debugging.")
            }
        }
        .labelStyle(SecondaryIconLabelStyle())
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
        .confirmationDialog("Forget \(bandName)?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget Band", role: .destructive) {
                liveState.forgetBand()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Sync all pending band data?",
            isPresented: $showsRestore,
            titleVisibility: .visible
        ) {
            Button("Sync Now") {
                startRestore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pulls everything the band has recorded but not yet sent. A large backlog takes a few minutes; live readings keep flowing.")
        }
        .navigationTitle("Band")
    }

    /// A history status row: the title with its symbol, and the detail on its own secondary line beneath.
    /// With a `progress` fraction it shows a determinate bar (a full sync knows its backlog in pages); without one,
    /// a spinner while `inProgress`.
    private func historyRow(
        _ title: String,
        detail: String,
        systemImage: String,
        progress: Double?,
        inProgress: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                Label(title, systemImage: systemImage)
                if inProgress {
                    Spacer(minLength: Spacing.s8)
                    if let progress {
                        Text(Format.percent(progress))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            if let progress {
                ProgressView(value: progress)
                    .stateAnimation(progress)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Runs the full-history restore. The button and the progress row read the shared
    /// `liveState.drainProgress`, so the manual path, the connect drain and the periodic cadence
    /// all render the same live feedback and nothing is duplicated in local view state.
    private func startRestore() {
        isSyncing = true
        restoreSummary = nil
        Task {
            await liveState.drainFullHistory()
            restoreSummary = await liveState.fullHistorySummary().map(Self.syncSummaryText)
            isSyncing = false
        }
    }

    /// The controller's summary as a sentence for the row: "synced: 3 drain(s), 1,204 record(s), oldest …" →
    /// "Synced 1,204 records · oldest …"; other outcomes are capitalized as they are.
    private static func syncSummaryText(_ summary: String) -> String {
        guard summary.hasPrefix("synced: ") else { return summary.prefix(1).uppercased() + summary.dropFirst() }
        let parts = summary.dropFirst("synced: ".count).components(separatedBy: ", ")
        let records = parts.first { $0.hasSuffix("record(s)") }?
            .replacingOccurrences(of: " record(s)", with: "") ?? "0"
        let span = parts.first { $0.hasPrefix("oldest") }
        return ["Synced \(records) records", span].compactMap { $0 }.joined(separator: " · ")
    }

    /// Off switches the channel at once. On only opens the explainer, and the switch moves when "Turn On" is tapped.
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
            Text("—")
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
        liveState.connectedRSSI.map { "\($0) dBm" } ?? "—"
    }

    /// Percent, with "Charging" after it while the strap reports charging (whoop-parity §3.7).
    private func batteryText(_ percent: Int) -> String {
        liveState.isCharging == true ? "\(Format.percent(percent)) · Charging" : Format.percent(percent)
    }

    /// The last LINK_VALID keep-alive that the link confirmed. Failures in a row replace the time (whoop-parity §3.8).
    @ViewBuilder
    private var linkText: some View {
        if liveState.linkKeepAliveFailures > 0 {
            Text("\(liveState.linkKeepAliveFailures) failed")
                .foregroundStyle(Palette.error)
        } else if let at = liveState.linkKeepAliveAt {
            if let stale = DataAge.staleText(since: at, now: liveState.now) {
                Text(stale)
            } else {
                Text(at, style: .time)
            }
        } else {
            Text("—")
        }
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
            Text("—")
        }
    }
}

/// Row icons take the secondary colour, so the rows read as plain text. Status colour stays on the text it marks.
private struct SecondaryIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(.secondary)
        }
    }
}
