import SwiftUI

struct SettingsView: View {
    let liveState: LiveState

    @State private var versionTaps = 0
    @State private var showsDebug = false

    /// Five taps on the version row opens the hidden Debug screen (PLAN.md §14 row 18).
    private static let debugTapCount = 5

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Formula sex", value: "Not set")
                LabeledContent("Birth year", value: "Not set")
                LabeledContent("Height", value: "Not set")
                LabeledContent("Weight", value: "Not set")
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
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showsDebug) {
            DebugView(liveState: liveState)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
