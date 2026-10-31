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

        // Overview is the launch tab (titled with the selected day, here Today).
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "overview.nextDay").waitForExistence(timeout: 30))
        attachScreenshot(named: "07-today")

        // Heart rate and calories live on Strain; stress lives on Health.
        app.tabBars.buttons["Strain"].tap()
        XCTAssertTrue(element(app, "strain.hrValue").waitForExistence(timeout: 30))
        openFromTab(app, tap: element(app, "strain.hrValue"), title: "Heart Rate")
        attachScreenshot(named: "08-heart-rate")
        attachTrendScreenshot(app)
        goBack(app, to: "Strain")

        openFromTab(app, tap: element(app, "strain.caloriesValue"), title: "Calories")
        attachScreenshot(named: "10-calories")
        goBack(app, to: "Strain")

        app.tabBars.buttons["Health"].tap()
        XCTAssertTrue(element(app, "health.stressValue").waitForExistence(timeout: 30))
        openFromTab(app, tap: element(app, "health.stressValue"), title: "Stress")
        attachScreenshot(named: "09-stress")
        goBack(app, to: "Health")

        // Alarms and Settings are top-right toolbar sheets now.
        for title in ["Alarms", "Settings"] {
            app.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            if title == "Alarms" {
                // The seed has three alarms (Store SeedData), so the list must show them before the capture.
                XCTAssertTrue(element(app, "alarms.time").waitForExistence(timeout: 10))
            }
            attachScreenshot(named: title == "Alarms" ? "12-alarms" : "17-settings")
            if title == "Alarms" {
                attachAlarmEditorScreens(app)
            }
            app.buttons["Done"].tap()
        }

        // Band sits behind Settings → Band.
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

        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        app.buttons["Server sync"].firstMatch.tap()
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

    /// Selects the 90-day span on the resting-HR card, where the old Trends chart now lives, and captures it.
    private func attachTrendScreenshot(_ app: XCUIApplication) {
        let quarter = app.buttons["90 d"].firstMatch
        XCTAssertTrue(quarter.waitForExistence(timeout: 10))
        var swipes = 0
        while !quarter.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        quarter.tap()

        XCTAssertTrue(app.staticTexts["Resting HR"].waitForExistence(timeout: 10))
        let chart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Resting HR, 90 d"))
            .firstMatch
        _ = chart.waitForExistence(timeout: 5)
        attachScreenshot(named: "11-trends")
    }

    /// Opens Settings → Band, the screen that used to be the Device tab.
    private func openBand(_ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
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
