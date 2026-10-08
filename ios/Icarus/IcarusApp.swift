import SwiftUI

@main
struct IcarusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var liveState: LiveState
    private let config: LaunchConfig

    init() {
        let config = LaunchConfig.current
        self.config = config
        let environment = AppEnvironment.make(config)
        _environment = State(initialValue: environment)
        _liveState = State(initialValue: LiveState.makeForLaunch(config, ingest: environment.ingestSink))
        // Must run before launch finishes (PLAN.md 11.2).
        BackgroundTasks.register(environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment, liveState: liveState, config: config)
                .tint(Palette.heartRate)
                .task {
                    environment.startIngestion()
                    liveState.start()
                    environment.startSync()
                }
        }
    }
}
