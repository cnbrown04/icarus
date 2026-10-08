import Foundation
import Testing
@testable import Icarus

struct LaunchConfigTests {
    @Test func parsesUITestArguments() {
        let config = LaunchConfig(arguments: [
            "Icarus", "-IcarusUITest", "1", "-IcarusFixture", "resting_day",
            "-IcarusNow", "2026-10-07T14:30:00Z", "-AppleLanguages", "(en)",
        ])
        #expect(config.isUITest)
        #expect(config.fixtureName == "resting_day")
        #expect(config.fixedNow == Date(timeIntervalSince1970: 1_791_383_400))
        #expect(config.startScreen == nil)
    }

    @Test func defaultsWithoutArguments() {
        let config = LaunchConfig(arguments: ["Icarus"])
        #expect(config == LaunchConfig(arguments: []))
        #expect(!config.isUITest)
        #expect(config.fixedNow == nil)
    }

    @Test func parsesWelcomeScreen() {
        let config = LaunchConfig(arguments: ["Icarus", "-IcarusScreen", "welcome"])
        #expect(config.startScreen == .welcome)
    }

    @Test func parsesPairBandAndDebugScreens() {
        #expect(LaunchConfig(arguments: ["Icarus", "-IcarusScreen", "pairBand"]).startScreen == .pairBand)
        #expect(LaunchConfig(arguments: ["Icarus", "-IcarusScreen", "debug"]).startScreen == .debug)
    }

    @Test func parsesSyntheticFlag() {
        #expect(LaunchConfig(arguments: ["Icarus", "-IcarusSynthetic", "1"]).isSynthetic)
        #expect(!LaunchConfig(arguments: ["Icarus"]).isSynthetic)
    }
}
