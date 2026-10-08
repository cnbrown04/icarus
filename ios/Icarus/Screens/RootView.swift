import SwiftUI

/// Chooses between onboarding, the tab bar and the Debug screen.
struct RootView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let config: LaunchConfig

    @AppStorage("welcome.completed") private var welcomeCompleted = false
    @State private var step: Step?
    @Environment(\.scenePhase) private var scenePhase

    enum Step: Equatable {
        case welcome
        case profile
        case pairBand
        case tabs
        case debug
    }

    /// The step after the user's own choices. Launch arguments pick the start screen for tests.
    private var currentStep: Step {
        if let step { return step }
        switch config.startScreen {
        case .welcome: return .welcome
        case .profile: return .profile
        case .pairBand: return .pairBand
        case .debug: return .debug
        case nil: return !config.isUITest && !welcomeCompleted ? .welcome : .tabs
        }
    }

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                // Leaving the foreground writes pending readings now (PLAN.md 7.2).
                if phase != .active {
                    environment.flushIngestion()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch currentStep {
        case .welcome:
            WelcomeView {
                step = .profile
            }
        case .profile:
            NavigationStack {
                ProfileView(environment: environment, mode: .onboarding(onContinue: { step = .pairBand }))
            }
        case .pairBand:
            NavigationStack {
                PairBandView(liveState: liveState, onFinish: finishOnboarding)
            }
        case .tabs:
            MainTabView(environment: environment, liveState: liveState)
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
    let environment: AppEnvironment
    let liveState: LiveState

    var body: some View {
        TabView {
            NavigationStack {
                TodayView(environment: environment, liveState: liveState)
            }
            .tabItem { Label("Today", systemImage: "heart") }

            NavigationStack {
                TrendsView(environment: environment)
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
                SettingsView(environment: environment, liveState: liveState)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
