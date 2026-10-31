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

        // Overview is the launch tab; its title is the selected day.
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.tabBars.buttons["Trends"].exists)
        XCTAssertFalse(app.tabBars.buttons["Home"].exists)
        XCTAssertFalse(app.tabBars.buttons["Today"].exists)
        for (tab, title) in [("Sleep", "Sleep"), ("Strain", "Strain"), ("Health", "Health"), ("Overview", "Today")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "missing title \(title)")
        }

        // Journal, Alarms and Settings are top-right toolbar sheets, not tabs.
        app.buttons["root.journal"].tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        app.buttons["root.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let band = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 10))
    }
}
