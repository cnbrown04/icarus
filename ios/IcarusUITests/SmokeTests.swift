import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryTabOpensItsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-IcarusUITest", "1", "-IcarusFixture", "resting_day", "-IcarusNow", "2026-10-07T14:30:00Z"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        for title in ["Trends", "Alarms", "Device", "Settings", "Today"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "missing title \(title)")
        }
    }
}
