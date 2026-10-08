import XCTest

/// Screenshots for CI (PLAN.md §16.3). Names are fixed; CI renames files to NN-screen-device-appearance.png.
/// The data screens launch on the 30-day seed so every number is deterministic.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDataScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusFixture", "resting_day",
            "-IcarusSeedDB", "seed_30d",
            "-IcarusNow", "2026-10-07T14:30:00Z",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["today.hrValue"].waitForExistence(timeout: 30))
        attachScreenshot(named: "07-today")

        openFromToday(app, tap: app.staticTexts["today.hrValue"], title: "Heart rate")
        attachScreenshot(named: "08-heart-rate")
        goBack(app)

        openFromToday(app, tap: app.staticTexts["today.stressValue"], title: "Stress")
        attachScreenshot(named: "09-stress")
        goBack(app)

        openFromToday(app, tap: app.staticTexts["today.caloriesValue"], title: "Calories")
        attachScreenshot(named: "10-calories")
        goBack(app)

        let tabs: [(label: String, attachmentName: String)] = [
            ("Trends", "11-trends"),
            ("Alarms", "12-alarms"),
            ("Device", "15-device"),
            ("Settings", "17-settings"),
        ]
        for tab in tabs {
            app.tabBars.buttons[tab.label].tap()
            XCTAssertTrue(app.navigationBars[tab.label].waitForExistence(timeout: 10))
            attachScreenshot(named: tab.attachmentName)
        }
    }

    func testProfileScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusScreen", "profile",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 30))
        attachScreenshot(named: "04-profile")
    }

    func testWelcomeScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusScreen", "welcome",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["welcome.continue"].waitForExistence(timeout: 30))
        attachScreenshot(named: "01-welcome")
    }

    func testPairBandScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusScreen", "pairBand",
            "-IcarusFixture", "resting_day",
            "-IcarusNow", "2026-10-07T14:30:00Z",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        // The fixture scan reports one band; no real Bluetooth is involved.
        XCTAssertTrue(app.buttons.matching(identifier: "pairBand.row").firstMatch.waitForExistence(timeout: 30))
        attachScreenshot(named: "05-pair-band")
    }

    func testDebugScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusScreen", "debug",
            "-IcarusFixture", "resting_day",
            "-IcarusNow", "2026-10-07T14:30:00Z",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 30))
        attachScreenshot(named: "18-debug")
    }

    /// Taps a leaf element on Today and waits for the detail screen's title.
    private func openFromToday(_ app: XCUIApplication, tap element: XCUIElement, title: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        element.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
