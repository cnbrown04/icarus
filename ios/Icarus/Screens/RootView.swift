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
                DebugView(liveState: liveState, environment: environment)
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

/// The Apple Health–style shell: Summary · Strain · Sleep · Browse. Each tab is its own `NavigationStack` with the
/// app's route destinations registered once at its root, and one profile button (the account sheet: band,
/// medications, alarms, settings) trails every tab root's toolbar.
struct MainTabView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    @Binding var pairingLink: PairingLink?

    @State private var tab: ShellTab = .summary
    @State private var showsProfile = false

    var body: some View {
        TabView(selection: $tab) {
            tabRoot(SummaryView(environment: environment, liveState: liveState))
                .tabItem { Label("Summary", systemImage: "heart.text.square.fill").accessibilityIdentifier("tab.summary") }
                .tag(ShellTab.summary)

            tabRoot(StrainView(environment: environment, liveState: liveState))
                .tabItem { Label("Strain", systemImage: Symbol.strain).accessibilityIdentifier("tab.strain") }
                .tag(ShellTab.strain)

            tabRoot(SleepView(environment: environment))
                .tabItem { Label("Sleep", systemImage: Symbol.sleep).accessibilityIdentifier("tab.sleep") }
                .tag(ShellTab.sleep)

            tabRoot(BrowseView(environment: environment, liveState: liveState))
                .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill").accessibilityIdentifier("tab.browse") }
                .tag(ShellTab.browse)
        }
        .environment(\.openTab) { tab = $0 }
        .sheet(isPresented: $showsProfile) {
            // ProfileSheet brings its own NavigationStack, title and Done button.
            ProfileSheet(environment: environment, liveState: liveState)
        }
        .sheet(isPresented: Binding(
            get: { pairingLink != nil },
            set: { if !$0 { pairingLink = nil } }
        )) {
            NavigationStack {
                ServerView(sync: environment.sync, link: pairingLink)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                pairingLink = nil
                            }
                        }
                    }
            }
        }
    }

    /// One tab: its root page in a `NavigationStack`, the app's routes registered once, and the profile button.
    private func tabRoot(_ root: some View) -> some View {
        NavigationStack {
            root
                .appRouteDestinations(environment: environment, liveState: liveState)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsProfile = true
                        } label: {
                            Image(systemName: Symbol.profile)
                        }
                        .accessibilityLabel("Profile")
                        .accessibilityIdentifier("root.profile")
                    }
                }
        }
    }
}
