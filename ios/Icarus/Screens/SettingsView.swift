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

    /// Five taps on the version row opens the hidden Debug screen (PLAN.md §14 row 18).
    private static let debugTapCount = 5

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ProfileView(environment: environment, mode: .settings)
                } label: {
                    settingsLabel("Profile", symbol: "person.fill", tint: .blue)
                }
            }

            Section("Band and Sync") {
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
                LabeledContent("Battery") {
                    Text(batteryText).monospacedDigit()
                }
                LabeledContent("Last data", value: lastDataText)
                LabeledContent("Server", value: serverText)
                NavigationLink {
                    SyncView(environment: environment)
                } label: {
                    HStack(spacing: Spacing.s8) {
                        settingsLabel("Sync", symbol: "arrow.triangle.2.circlepath", tint: Palette.syncOK)
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

            Section("Data") {
                LabeledContent("Raw heart rate kept", value: "\(RetentionPolicy.rawDays) days")
                LabeledContent("Minute metrics kept", value: "\(RetentionPolicy.minuteDays) days")
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

    private var batteryText: String {
        guard let battery = liveState.batteryPercent else { return "--" }
        return Format.percent(battery)
    }

    /// Static text, exact when the screen opens. The Device screen keeps a live age (PLAN.md 7.2).
    private var lastDataText: String {
        guard let last = liveState.lastDataAt else { return "None" }
        return DataAge.text(seconds: liveState.clock.now.timeIntervalSince(last))
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
