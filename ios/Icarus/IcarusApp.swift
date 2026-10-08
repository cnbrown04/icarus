import SwiftUI

@main
struct IcarusApp: App {
    @State private var liveState: LiveState
    private let config: LaunchConfig

    init() {
        let config = LaunchConfig.current
        self.config = config
        _liveState = State(initialValue: LiveState.makeForLaunch(config))
    }

    var body: some Scene {
        WindowGroup {
            RootView(liveState: liveState, config: config)
                .task { liveState.start() }
        }
    }
}
