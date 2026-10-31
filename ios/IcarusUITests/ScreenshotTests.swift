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

        // Summary is the launch tab. File names stay fixed for CI (07-today is now the Summary tab).
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 30))
        attachScreenshot(named: "07-today")

        // Every metric has one detail page, reached from Browse.
        app.tabBars.buttons["Browse"].tap()
        XCTAssertTrue(app.navigationBars["Browse"].waitForExistence(timeout: 10))
        openFromTab(app, tap: app.buttons["Heart rate"].firstMatch, title: "Heart rate")
        attachScreenshot(named: "08-heart-rate")
        goBack(app, to: "Browse")

        openFromTab(app, tap: app.buttons["Resting heart rate"].firstMatch, title: "Resting heart rate")
        attachTrendScreenshot(app)
        goBack(app, to: "Browse")

        openFromTab(app, tap: app.buttons["Calories"].firstMatch, title: "Calories")
        attachScreenshot(named: "10-calories")
        goBack(app, to: "Browse")

        openFromTab(app, tap: app.buttons["Stress"].firstMatch, title: "Stress")
        attachScreenshot(named: "09-stress")
        goBack(app, to: "Browse")

        // Alarms and the settings live in the profile sheet.
        app.buttons["root.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        attachScreenshot(named: "17-settings")
        app.buttons["Alarms"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Alarms"].waitForExistence(timeout: 10))
        // The seed has three alarms (Store SeedData), so the list must show them before the capture.
        XCTAssertTrue(element(app, "alarms.time").waitForExistence(timeout: 10))
        attachScreenshot(named: "12-alarms")
        attachAlarmEditorScreens(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        openBand(app)
        scrollToExperimental(app)
        attachScreenshot(named: "15-device")
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

    func testServerScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusScreen", "server",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Server"].waitForExistence(timeout: 30))
        attachScreenshot(named: "06-server")
    }

    func testSyncScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusSyncFixture", "paired",
            "-IcarusNow", "2026-10-07T14:30:00Z",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 30))
        app.buttons["root.profile"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sync")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Server sync"].waitForExistence(timeout: 10))
        attachScreenshot(named: "16-sync")
    }

    /// Opens the first alarm in the editor, then its rhythm editor, and returns to the list.
    private func attachAlarmEditorScreens(_ app: XCUIApplication) {
        element(app, "alarms.time").tap()
        XCTAssertTrue(app.buttons["alarmEditor.save"].waitForExistence(timeout: 10))
        attachScreenshot(named: "13-alarm-editor")

        element(app, "alarmEditor.rhythm").tap()
        XCTAssertTrue(app.navigationBars["Rhythm"].waitForExistence(timeout: 10))
        attachScreenshot(named: "14-rhythm-editor")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["alarmEditor.save"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Alarms"].waitForExistence(timeout: 10))
    }

    /// Selects the six-month range on the resting heart rate page (Trends now lives on every metric page).
    private func attachTrendScreenshot(_ app: XCUIApplication) {
        let sixMonths = app.buttons["6M"].firstMatch
        XCTAssertTrue(sixMonths.waitForExistence(timeout: 10))
        sixMonths.tap()
        attachScreenshot(named: "11-trends")
    }

    /// Opens Profile → Band, the screen that used to be the Device tab.
    private func openBand(_ app: XCUIApplication) {
        app.buttons["root.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        let band = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        XCTAssertTrue(band.waitForExistence(timeout: 10))
        band.tap()
        XCTAssertTrue(app.navigationBars["Band"].waitForExistence(timeout: 10))
    }

    /// Scrolls the Band form until its Experimental section header is on screen.
    private func scrollToExperimental(_ app: XCUIApplication) {
        let header = app.staticTexts["Experimental"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        var swipes = 0
        while !header.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Any element with this identifier. Identifiers sit on leaf views, which may be typed as text or buttons.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps a leaf element on a tab's screen and waits for the detail screen's title.
    private func openFromTab(_ app: XCUIApplication, tap element: XCUIElement, title: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 30))
        element.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    private func goBack(_ app: XCUIApplication, to title: String) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
