import XCTest

/// The single simulator smoke test for Voxglass. Everything else is covered by
/// the host `swift test` logic suite (VoxglassCore); this only proves the app
/// boots and every tab renders without crashing. Run locally on iPhone 16 — CI
/// runs `swift test` only.
final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppBootsAndVisitsAllTabs() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", "home",
            "-VoxglassDisableAnimatedSplash"
        ]
        app.launch()

        // Boots into the Listen tab.
        XCTAssertTrue(
            app.staticTexts["Recommended for You"].waitForExistence(timeout: 15),
            "App did not boot into the Listen tab"
        )

        // Every tab is reachable and renders a stable anchor without crashing.
        let tabs: [(button: String, anchor: String)] = [
            ("My Books", "My Books"),
            ("Explore", "Featured Collections"),
            ("More", "Streaming Cache"),
            ("Listen", "Recommended for You")
        ]
        for tab in tabs {
            app.buttons[tab.button].tap()
            XCTAssertTrue(
                app.staticTexts[tab.anchor].waitForExistence(timeout: 10),
                "Tab \(tab.button) did not render its content"
            )
        }

        // Search renders its field (kept last: it puts focus in a text field).
        app.buttons["Search"].tap()
        XCTAssertTrue(
            app.textFields["Search LibriVox audiobooks"].waitForExistence(timeout: 10),
            "Search tab did not render its search field"
        )
    }

    func testAllTenEQBandsVisibleAndDraggable() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", "more",
            "-VoxglassDisableAnimatedSplash"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 15))

        let eqRow = app.buttons["settings.eq"]
        for _ in 0..<6 where !eqRow.isHittable {
            app.swipeUp()
            _ = eqRow.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(eqRow.exists, "EQ settings row not found.\n\(app.debugDescription)")
        XCTAssertTrue(eqRow.isHittable, "EQ settings row is not hittable.\n\(app.debugDescription)")
        eqRow.tap()

        XCTAssertTrue(
            app.staticTexts["Equalizer"].waitForExistence(timeout: 10),
            "Equalizer sheet did not open.\n\(app.debugDescription)"
        )

        for band in 0..<10 {
            let slider = app.sliders["eq.band.\(band)"]
            XCTAssertTrue(
                slider.waitForExistence(timeout: 8),
                "EQ band \(band) slider not found.\n\(app.debugDescription)"
            )
            XCTAssertTrue(
                slider.isHittable,
                "EQ band \(band) slider is not hittable.\n\(app.debugDescription)"
            )
        }

        let band9 = app.sliders["eq.band.9"]
        let start = band9.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = band9.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
