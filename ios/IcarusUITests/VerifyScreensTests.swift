import XCTest

/// Walks every page of the app against REAL data and attaches a screenshot of each, for a human (or Claude) to
/// check the numbers against the database. Runs only when `ICARUS_VERIFY=1` is in the test runner's environment
/// (`TEST_RUNNER_ICARUS_VERIFY=1 xcodebuild test …`), so CI and the regular UI tests never launch it: it uses the
/// installed app's own store, not a fixture. With `ICARUS_VERIFY_SYNC=1` it also runs a band sync and captures the
/// progress row (needs a paired band in range).
@MainActor
final class VerifyScreensTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ICARUS_VERIFY"] == "1", "set TEST_RUNNER_ICARUS_VERIFY=1 to walk the app against real data")
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testWalkEveryPage() {
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 30))
        settle()
        shot("01-summary")
        scrollShot("01b-summary-scrolled")

        tab("Strain")
        shot("02-strain")
        scrollShot("02b-strain-scrolled")

        tab("Sleep")
        shot("03-sleep")
        scrollShot("03b-sleep-scrolled")
        scrollShot("03c-sleep-scrolled-more")
        for range in ["W", "M", "6M"] {
            tapIfExists(app.buttons[range].firstMatch)
            shot("03-sleep-\(range)")
        }

        tab("Browse")
        shot("04-browse")
        let metrics = ["Strain", "Calories", "Heart Rate", "Resting Heart Rate", "Heart Rate Variability", "Recovery",
                       "Stress", "Respiratory Rate"]
        for (index, metric) in metrics.enumerated() {
            open(metric, index: index)
        }
        openRow("Vitals", name: "05-vitals")
        openRow("Workouts", name: "06-workouts")
        openRow("Check-in", name: "07-journal")
        openRow("Insights", name: "08-insights")
        openRow("Weekly Assessment", name: "09-weekly")

        app.buttons["root.profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 10))
        shot("10-profile")
        // Rows first, the scrolled shot last: a List unloads rows scrolled out of view, so they stop existing.
        for (row, name) in [("Medications", "11-medications"), ("Alarms", "12-alarms")] {
            let button = app.collectionViews.buttons[row].firstMatch
            scrollTo(button)
            guard button.waitForExistence(timeout: 5) else {
                XCTFail("no Profile row \(row)")
                continue
            }
            button.tap()
            settle()
            shot(name)
            back()
        }
        scrollShot("10b-profile-scrolled")
        let band = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band")).firstMatch
        scrollTo(band)
        if band.waitForExistence(timeout: 5) {
            band.tap()
            settle()
            shot("13-band")
            scrollShot("13b-band-scrolled")
            if ProcessInfo.processInfo.environment["ICARUS_VERIFY_SYNC"] == "1" {
                syncBand()
            }
        }
    }

    // MARK: Steps

    /// Opens a metric from Browse, captures its default range, then its 6M range, and returns.
    private func open(_ metric: String, index: Int) {
        // Inside the list: "Strain" is also a tab bar button.
        let row = app.collectionViews.buttons[metric].firstMatch
        scrollTo(row)
        guard row.waitForExistence(timeout: 5) else { return XCTFail("no Browse row \(metric)") }
        row.tap()
        XCTAssertTrue(app.navigationBars[metric].waitForExistence(timeout: 10), "no page titled \(metric)")
        settle()
        let slug = metric.lowercased().replacingOccurrences(of: " ", with: "-")
        shot(String(format: "04-%02d-%@", index + 1, slug))
        scrollShot(String(format: "04-%02d-%@-scrolled", index + 1, slug))
        if pickRange("6M") {
            shot(String(format: "04-%02d-%@-6m", index + 1, slug))
        }
        // Nightly vitals: last night's readings (D), then the Average / All Readings switch.
        if ["Resting Heart Rate", "Heart Rate Variability", "Respiratory Rate"].contains(metric) {
            if pickRange("D") {
                shot(String(format: "04-%02d-%@-d", index + 1, slug))
                scrollShot(String(format: "04-%02d-%@-d-scrolled", index + 1, slug))
            }
            // Every reading behind the nightly values, on the week and 6M charts.
            for range in ["W", "6M"] where pickRange(range) {
                let readings = app.buttons["All Readings"].firstMatch
                if tapIfExists(readings) {
                    shot(String(format: "04-%02d-%@-%@-readings", index + 1, slug, range.lowercased()))
                    tapIfExists(app.buttons["Average"].firstMatch)
                }
            }
        }
        back()
    }

    private func openRow(_ label: String, name: String) {
        let row = app.collectionViews.buttons[label].firstMatch
        scrollTo(row)
        guard row.waitForExistence(timeout: 5) else { return XCTFail("no Browse row \(label)") }
        row.tap()
        settle()
        shot(name)
        back()
    }

    /// Starts "Sync All Pending Band Data…", confirms, and captures the row while it runs and when it ends.
    private func syncBand() {
        let sync = app.buttons["device.drainFullHistory"]
        scrollTo(sync)
        guard sync.waitForExistence(timeout: 5), sync.isEnabled else { return XCTFail("sync button unavailable") }
        sync.tap()
        let confirm = app.buttons["Sync Now"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        sleep(1)
        shot("14-sync-started")
        sleep(4)
        shot("14b-sync-running")
        let lastSync = app.staticTexts["Last Sync"]
        _ = lastSync.waitForExistence(timeout: 120)
        shot("14c-sync-finished")
    }

    // MARK: Helpers

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "missing \(name)")
        settle()
    }

    /// The pushed page's back button. Not "the first navigation-bar button": a TabView keeps every tab's bar in the
    /// hierarchy, and that matched another tab's profile button (the walk then sat on the profile sheet).
    private func back() {
        let button = app.navigationBars.buttons["BackButton"].firstMatch
        if button.exists, button.isHittable {
            button.tap()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        settle()
    }

    /// Scrolls back to the top, where the range control sits, then picks `label` (D, W, M, 6M).
    @discardableResult
    private func pickRange(_ label: String) -> Bool {
        app.swipeDown()
        app.swipeDown()
        return tapIfExists(app.buttons[label].firstMatch)
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 3), element.isHittable else { return false }
        element.tap()
        settle()
        return true
    }

    /// Scrolls down, then back up, until `element` is on screen: a row above the current scroll position (Workouts
    /// after the metric rows) is only reachable going up.
    private func scrollTo(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        swipes = 0
        while !(element.exists && element.isHittable), swipes < 8 {
            app.swipeDown()
            swipes += 1
        }
    }

    private func scrollShot(_ name: String) {
        app.swipeUp()
        settle()
        shot(name)
    }

    /// Data loads off the main thread; give each page a moment before capturing it.
    private func settle() {
        sleep(2)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
