import Store
import SwiftUI
import SyncKit

/// Settings in the system Settings style: icons in coloured squares, grouped sections (IOS_UI_SPEC, Screen 17).
struct SettingsView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var versionTaps = 0
    @State private var showsDebug = false
    @State private var confirmsUnpair = false
    @StateObject private var units = UnitPreferences()

    /// Retention windows, stored under the keys `RetentionPolicy` reads at purge time. The picker
    /// selection is clamped on read so a stored out-of-range value still shows and gets replaced
    /// with a valid one on the next change.
    @AppStorage(RetentionPolicy.rawDaysKey) private var rawDaysStored = Int(RetentionPolicy.rawDaysDefault)
    @AppStorage(RetentionPolicy.minuteDaysKey) private var minuteDaysStored = Int(RetentionPolicy.minuteDaysDefault)
    /// Strain Coach: buzz the band once a day when day strain reaches the target (`TargetBuzzController`).
    @AppStorage(TargetBuzzController.enabledKey) private var buzzOnTarget = false
    /// Applied at the app root (`IcarusApp`). Dark is the default.
    @AppStorage("appearance") private var appearance: AppAppearance = .dark

    /// Five taps on the version row opens the hidden Debug screen (PLAN.md §14 row 18).
    private static let debugTapCount = 5

    private struct RetentionChoice: Identifiable, Hashable {
        let days: Int
        let label: String
        var id: Int { days }
    }

    /// Covers the whole configurable raw range (PLAN.md 10.2: 30 days by default, 1–90 here).
    private static let rawRetentionChoices: [RetentionChoice] = [
        .init(days: 1, label: "1 day"),
        .init(days: 3, label: "3 days"),
        .init(days: 7, label: "1 week"),
        .init(days: 14, label: "2 weeks"),
        .init(days: 30, label: "1 month"),
        .init(days: 60, label: "2 months"),
        .init(days: 90, label: "3 months"),
    ]

    /// Covers the whole configurable minute range (PLAN.md 10.2: 400 days by default, 7–730 here).
    private static let minuteRetentionChoices: [RetentionChoice] = [
        .init(days: 7, label: "1 week"),
        .init(days: 14, label: "2 weeks"),
        .init(days: 30, label: "1 month"),
        .init(days: 90, label: "3 months"),
        .init(days: 180, label: "6 months"),
        .init(days: 365, label: "1 year"),
        .init(days: Int(RetentionPolicy.minuteDaysDefault), label: "Default (400 days)"),
        .init(days: 730, label: "2 years"),
    ]

    private var rawRetention: Binding<Int> {
        Binding(
            get: { Self.clamp(rawDaysStored, to: RetentionPolicy.rawDaysBounds) },
            set: { rawDaysStored = $0 }
        )
    }

    private var minuteRetention: Binding<Int> {
        Binding(
            get: { Self.clamp(minuteDaysStored, to: RetentionPolicy.minuteDaysBounds) },
            set: { minuteDaysStored = $0 }
        )
    }

    private static func clamp(_ value: Int, to bounds: ClosedRange<Int64>) -> Int {
        min(max(value, Int(bounds.lowerBound)), Int(bounds.upperBound))
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ProfileView(environment: environment, mode: .settings)
                } label: {
                    settingsLabel("Profile", symbol: "person.fill", tint: .blue)
                }
            }

            Section {
                Picker("Length & mass", selection: $units.lengthMass) {
                    ForEach(LengthMassUnits.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Temperature", selection: $units.temperature) {
                    ForEach(TemperatureUnits.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
            } header: {
                Text("Units")
            } footer: {
                Text("System follows the locale. Storage and sync always use metric (cm, kg, °C); only display changes.")
            }

            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.appearance")
            } header: {
                Text("Appearance")
            } footer: {
                Text("Dark is the default. System follows the iPhone setting.")
            }

            Section {
                Toggle(isOn: $buzzOnTarget) {
                    settingsLabel("Buzz at strain target", symbol: "waveform", tint: Palette.strain)
                }
                .accessibilityIdentifier("settings.buzzOnTarget")
            } header: {
                Text("Coaching")
            } footer: {
                Text("The band buzzes once a day, when day strain first reaches the Strain Coach target.")
            }

            Section {
                NavigationLink {
                    MedicationsView(environment: environment)
                } label: {
                    settingsLabel("Medications", symbol: "pills.fill", tint: Palette.sleep)
                }
                .accessibilityIdentifier("settings.medications")
            } footer: {
                Text("Stimulant windows are estimated from your profiles and logged doses. They shade the heart rate and stress charts.")
            }

            Section("Band") {
                NavigationLink {
                    DeviceView(liveState: liveState)
                } label: {
                    HStack(spacing: Spacing.s8) {
                        settingsLabel("Band", symbol: "bolt.heart.fill", tint: Palette.heartRate)
                        Spacer(minLength: Spacing.s8)
                        Text(liveState.connectionText)
                            .foregroundStyle(Palette.link(liveState.state))
                    }
                }
            }

            Section("Server") {
                LabeledContent("Server", value: serverText)
                NavigationLink {
                    SyncView(environment: environment)
                } label: {
                    HStack(spacing: Spacing.s8) {
                        settingsLabel("Server sync", symbol: "arrow.triangle.2.circlepath", tint: Palette.syncOK)
                        Spacer(minLength: Spacing.s8)
                        Text(syncPhaseText)
                            .foregroundStyle(Palette.sync(environment.sync.status.phase))
                    }
                }
                if environment.sync.status.phase == .notPaired {
                    NavigationLink {
                        ServerView(sync: environment.sync)
                    } label: {
                        settingsLabel("Pair with server", symbol: "link", tint: .blue)
                    }
                } else {
                    NavigationLink {
                        ServerView(sync: environment.sync)
                    } label: {
                        settingsLabel("Re-pair", symbol: "link", tint: .blue)
                    }
                    Button("Unpair", role: .destructive) {
                        confirmsUnpair = true
                    }
                }
            }

            Section {
                Picker("Raw heart rate kept", selection: rawRetention) {
                    ForEach(Self.rawRetentionChoices) { choice in
                        Text(choice.label).tag(choice.days)
                    }
                }
                .pickerStyle(.menu)
                Picker("Minute metrics kept", selection: minuteRetention) {
                    ForEach(Self.minuteRetentionChoices) { choice in
                        Text(choice.label).tag(choice.days)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Storage")
            } footer: {
                Text("Older rows are deleted on the nightly maintenance run. Purged data cannot be recovered; with sync on, the server keeps its own copy (raw samples 400 days, minute metrics indefinitely).")
            }

            Section("Advanced") {
                NavigationLink {
                    RawDataView(liveState: liveState)
                } label: {
                    settingsLabel("Raw band data", symbol: "waveform.path.ecg", tint: .purple)
                }
            }

            Section {
                LabeledContent("Version", value: appVersion)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        versionTaps += 1
                        if versionTaps >= Self.debugTapCount {
                            versionTaps = 0
                            showsDebug = true
                        }
                    }
            } header: {
                Text("About")
            } footer: {
                Text("Icarus is not a medical device. Stress and calorie figures are estimates.")
            }
        }
        .confirmationDialog(
            "Unpair from \(environment.sync.status.serverHost ?? "server")?",
            isPresented: $confirmsUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                Task { await environment.sync.unpair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Data stays on this iPhone. Sync stops until you pair again.")
        }
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showsDebug) {
            DebugView(liveState: liveState, environment: environment)
        }
    }

    private func settingsLabel(_ title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, tint: tint)
        }
    }

    private var serverText: String {
        environment.sync.status.serverHost ?? "Not paired"
    }

    private var syncPhaseText: String {
        switch environment.sync.status.phase {
        case .notPaired: return "Not paired"
        case .idle: return "Up to date"
        case .syncing: return "Syncing"
        case let .retrying(at):
            return "Retrying in \(max(0, Int(at.timeIntervalSince(environment.clock.now)))) s"
        case .needsRepair: return "Needs repair"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
