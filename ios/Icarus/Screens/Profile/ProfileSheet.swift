import Store
import SwiftUI
import SyncKit

/// The profile sheet behind the single profile button on every tab root (Apple Health's account sheet). Holds the
/// person, the band, the server, the app's display and coaching settings, storage, advanced tools and About.
struct ProfileSheet: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @Environment(\.dismiss) private var dismiss
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
    /// Applied at the app root (`IcarusApp`). Follows the system by default.
    @AppStorage("appearance") private var appearance: AppAppearance = .system

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
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProfileView(environment: environment, mode: .settings)
                    } label: {
                        Text("Profile")
                    }
                    .accessibilityIdentifier("profile.summary")
                }

                Section {
                    NavigationLink {
                        DeviceView(liveState: liveState)
                    } label: {
                        LabeledContent("Band") {
                            Text(liveState.connectionText)
                                .foregroundStyle(Palette.link(liveState.state))
                                .lineLimit(1)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        MedicationsView(environment: environment)
                    } label: {
                        Text("Medications")
                    }
                    .accessibilityIdentifier("settings.medications")
                }

                Section {
                    NavigationLink {
                        AlarmsView(environment: environment, liveState: liveState)
                    } label: {
                        Text("Alarms")
                    }
                }

                Section("Display") {
                    Picker("Length and Mass", selection: $units.lengthMass) {
                        ForEach(LengthMassUnits.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Temperature", selection: $units.temperature) {
                        ForEach(TemperatureUnits.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .accessibilityIdentifier("settings.appearance")
                }

                Section("Coaching") {
                    Toggle("Buzz at Strain Target", isOn: $buzzOnTarget)
                        .accessibilityIdentifier("settings.buzzOnTarget")
                }

                Section("Server") {
                    NavigationLink {
                        SyncView(environment: environment)
                    } label: {
                        LabeledContent("Sync") {
                            Text(syncPhaseText)
                                .foregroundStyle(Palette.sync(environment.sync.status.phase))
                                .lineLimit(1)
                        }
                    }
                    if environment.sync.status.phase == .notPaired {
                        NavigationLink {
                            ServerView(sync: environment.sync)
                        } label: {
                            Text("Pair with Server")
                        }
                    } else {
                        NavigationLink {
                            ServerView(sync: environment.sync)
                        } label: {
                            Text("Re-pair")
                        }
                        Button("Unpair", role: .destructive) {
                            confirmsUnpair = true
                        }
                    }
                }

                Section {
                    Picker("Raw Heart Rate Kept", selection: rawRetention) {
                        ForEach(Self.rawRetentionChoices) { choice in
                            Text(choice.label).tag(choice.days)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Minute Metrics Kept", selection: minuteRetention) {
                        ForEach(Self.minuteRetentionChoices) { choice in
                            Text(choice.label).tag(choice.days)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Purged data cannot be recovered")
                }

                Section("Advanced") {
                    NavigationLink {
                        RawDataView(liveState: liveState)
                    } label: {
                        Text("Raw Band Data")
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
                    Text("Not a medical device")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
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
            .navigationDestination(isPresented: $showsDebug) {
                DebugView(liveState: liveState, environment: environment)
            }
        }
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
