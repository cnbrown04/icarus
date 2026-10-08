import SwiftUI

/// Chooses between onboarding, the tab bar and the Debug screen.
struct RootView: View {
    let liveState: LiveState
    let config: LaunchConfig

    @AppStorage("welcome.completed") private var welcomeCompleted = false
    @State private var step: Step?

    enum Step: Equatable {
        case welcome
        case pairBand
        case tabs
        case debug
    }

    /// The step after the user's own choices. Launch arguments pick the start screen for tests.
    private var currentStep: Step {
        if let step { return step }
        switch config.startScreen {
        case .welcome: return .welcome
        case .pairBand: return .pairBand
        case .debug: return .debug
        case nil: return !config.isUITest && !welcomeCompleted ? .welcome : .tabs
        }
    }

    var body: some View {
        switch currentStep {
        case .welcome:
            WelcomeView {
                step = .pairBand
            }
        case .pairBand:
            NavigationStack {
                PairBandView(liveState: liveState, onFinish: finishOnboarding)
            }
        case .tabs:
            MainTabView(liveState: liveState)
        case .debug:
            NavigationStack {
                DebugView(liveState: liveState)
            }
        }
    }

    private func finishOnboarding() {
        welcomeCompleted = true
        step = .tabs
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
                SettingsView(liveState: liveState)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
