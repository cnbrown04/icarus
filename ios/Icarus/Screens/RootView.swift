import SwiftUI
import SyncKit

/// Chooses between onboarding, the tab bar and the Debug screen.
struct RootView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let config: LaunchConfig

    @AppStorage("welcome.completed") private var welcomeCompleted = false
    @State private var step: Step?
    @State private var pairingLink: PairingLink?
    @Environment(\.scenePhase) private var scenePhase

    enum Step: Equatable {
        case welcome
        case profile
        case pairBand
        case server
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
        case .server: return .server
        case .debug: return .debug
        case nil: return !config.isUITest && !welcomeCompleted ? .welcome : .tabs
        }
    }

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                environment.scenePhaseChanged(phase)
            }
            .onOpenURL { url in
                openPairingLink(url)
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
                PairBandView(liveState: liveState, onFinish: { step = .server })
            }
        case .server:
            NavigationStack {
                ServerView(sync: environment.sync, onFinish: finishOnboarding, onSkip: finishOnboarding, link: pairingLink)
            }
        case .tabs:
            MainTabView(environment: environment, liveState: liveState, pairingLink: $pairingLink)
        case .debug:
            NavigationStack {
                DebugView(liveState: liveState)
            }
        }
    }

    /// The website's QR code opens `icarus://pair`. Before onboarding ends, the Server step takes the link.
    /// After it, the pairing sheet opens over the tabs.
    private func openPairingLink(_ url: URL) {
        guard let link = PairingLink(url: url) else { return }
        pairingLink = link
        if !welcomeCompleted {
            step = .server
        }
    }

    private func finishOnboarding() {
        welcomeCompleted = true
        pairingLink = nil
        step = .tabs
    }
}

struct MainTabView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    @Binding var pairingLink: PairingLink?

    var body: some View {
        TabView {
            NavigationStack {
                TodayView(environment: environment, liveState: liveState)
            }
            .tabItem { Label("Today", systemImage: "heart.fill") }

            NavigationStack {
                TrendsView(environment: environment)
            }
            .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack {
                AlarmsView(environment: environment, liveState: liveState)
            }
            .tabItem { Label("Alarms", systemImage: "alarm.fill") }

            NavigationStack {
                DeviceView(liveState: liveState)
            }
            .tabItem { Label("Device", systemImage: "antenna.radiowaves.left.and.right") }

            NavigationStack {
                SettingsView(environment: environment, liveState: liveState)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(isPresented: Binding(
            get: { pairingLink != nil },
            set: { if !$0 { pairingLink = nil } }
        )) {
            NavigationStack {
                ServerView(sync: environment.sync, link: pairingLink)
            }
        }
    }
}
