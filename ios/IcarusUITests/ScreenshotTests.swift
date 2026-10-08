import XCTest

/// Screenshots for CI (PLAN.md §16.3). Names are fixed; CI renames files to NN-screen-device-appearance.png.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTabScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-IcarusUITest", "1",
            "-IcarusFixture", "resting_day",
            "-IcarusNow", "2026-10-07T14:30:00Z",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["today.hrValue"].waitForExistence(timeout: 30))
        attachScreenshot(named: "07-today")

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

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
