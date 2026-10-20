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

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.tabBars.buttons["Trends"].exists)
        for title in ["Today", "Home"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "missing title \(title)")
        }

        // Settings is a top-right toolbar button now, not a tab.
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let band = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 10))
    }
}
