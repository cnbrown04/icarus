import SwiftUI
import SyncKit

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
            Section("Profile") {
                NavigationLink("Profile") {
                    ProfileView(environment: environment, mode: .settings)
                }
            }

            Section("Server") {
                LabeledContent("Server", value: serverText)
                NavigationLink("Sync") {
                    SyncView(environment: environment)
                }
                if environment.sync.status.phase == .notPaired {
                    NavigationLink("Pair with server") {
                        ServerView(sync: environment.sync)
                    }
                } else {
                    NavigationLink("Re-pair") {
                        ServerView(sync: environment.sync)
                    }
                    Button("Unpair", role: .destructive) {
                        confirmsUnpair = true
                    }
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
                Text("Icarus is not a medical device. Stress and calorie figures are estimates.")
            } header: {
                Text("About")
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
            DebugView(liveState: liveState)
        }
    }

    private var serverText: String {
        environment.sync.status.serverHost ?? "Not paired"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
