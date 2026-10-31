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

        // Summary is the launch tab; the old Overview / Health / Today tabs are gone.
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 30))
        for gone in ["Overview", "Health", "Today", "Trends"] {
            XCTAssertFalse(app.tabBars.buttons[gone].exists, "\(gone) is no longer a tab")
        }
        for tab in ["Sleep", "Strain", "Browse", "Summary"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 10), "missing title \(tab)")
        }

        // Every metric opens the one detail page, titled with the metric.
        app.tabBars.buttons["Browse"].tap()
        app.buttons["Heart Rate"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Heart Rate"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // One profile button holds Band, Medications, Alarms and the settings.
        app.buttons["root.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        let band = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 10))
    }
}
