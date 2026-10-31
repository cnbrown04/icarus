import SwiftUI

@main
struct IcarusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var liveState: LiveState
    @AppStorage("appearance") private var appearance: AppAppearance = .dark
    private let config: LaunchConfig

    init() {
        let config = LaunchConfig.current
        self.config = config
        let environment = AppEnvironment.make(config)
        let liveState = LiveState.makeForLaunch(config, ingest: environment.ingestSink)
        _environment = State(initialValue: environment)
        _liveState = State(initialValue: liveState)
        environment.alarms.connect(band: liveState)
        environment.connectHistoricalRecords(band: liveState)
        // [push disabled] Re-enable for PLAN.md 12.5 (alarm push dispatch).
        // PushRouter.shared.attach(sync: environment.sync, band: liveState)
        // Must run before launch finishes (PLAN.md 11.2).
        BackgroundTasks.register(environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment, liveState: liveState, config: config)
                .tint(Palette.heartRate)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    environment.startIngestion()
                    liveState.start()
                    environment.startSync()
                    environment.alarms.start()
                    #if DEBUG
                    // Serves the store's rows to a computer on this Wi-Fi (DebugView shows the URL).
                    // Not in UI tests, so fixtures launch with no listener.
                    if !config.isUITest {
                        DebugServer.shared.start(database: environment.database)
                    }
                    #endif
                }
        }
    }
}
