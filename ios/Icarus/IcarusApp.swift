import SwiftUI

@main
struct IcarusApp: App {
    @State private var environment: AppEnvironment
    @State private var liveState: LiveState
    private let config: LaunchConfig

    init() {
        let config = LaunchConfig.current
        self.config = config
        let environment = AppEnvironment.make(config)
        _environment = State(initialValue: environment)
        _liveState = State(initialValue: LiveState.makeForLaunch(config, ingest: environment.ingestSink))
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment, liveState: liveState, config: config)
                .task {
                    environment.startIngestion()
                    liveState.start()
                }
        }
    }
}
