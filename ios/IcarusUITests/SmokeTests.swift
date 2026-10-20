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
        XCTAssertFalse(app.tabBars.buttons["Trends"].exists)
        for title in ["Alarms", "Settings", "Today"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "missing title \(title)")
        }

        // Band is no longer a tab: Settings pushes the Band screen.
        app.tabBars.buttons["Settings"].tap()
        let band = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 10))
    }
}
