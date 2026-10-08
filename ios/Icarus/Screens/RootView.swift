import SwiftUI

/// Chooses between Welcome and the tab bar.
struct RootView: View {
    let liveState: LiveState
    let config: LaunchConfig

    @AppStorage("welcome.completed") private var welcomeCompleted = false
    @State private var welcomeDismissed = false

    private var showsWelcome: Bool {
        guard !welcomeDismissed else { return false }
        if config.startScreen == .welcome { return true }
        return !config.isUITest && !welcomeCompleted
    }

    var body: some View {
        if showsWelcome {
            WelcomeView {
                welcomeDismissed = true
                welcomeCompleted = true
            }
        } else {
            MainTabView(liveState: liveState)
        }
    }
}

struct MainTabView: View {
    let liveState: LiveState

    var body: some View {
        TabView {
            NavigationStack {
                TodayView(liveState: liveState)
            }
            .tabItem { Label("Today", systemImage: "heart") }

            NavigationStack {
                TrendsView()
            }
            .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack {
                AlarmsView()
            }
            .tabItem { Label("Alarms", systemImage: "alarm") }

            NavigationStack {
                DeviceView(liveState: liveState)
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
