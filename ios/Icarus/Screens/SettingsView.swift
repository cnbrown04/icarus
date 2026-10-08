import SwiftUI

struct SettingsView: View {
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
                Text("Icarus is not a medical device. Stress and calorie figures are estimates.")
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("tab.settings")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
