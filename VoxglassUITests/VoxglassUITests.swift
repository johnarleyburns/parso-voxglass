import XCTest

final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(initialTab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", initialTab
        ]
        app.launch()
        return app
    }

    func testMyBooksShowsShelfWithoutAddPanels() {
        let app = launchApp(initialTab: "library")

        XCTAssertTrue(app.staticTexts["My Audiobooks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["On This Device"].exists)
        XCTAssertFalse(app.staticTexts["Add from Internet Archive"].exists)
        XCTAssertFalse(app.staticTexts["Add Local Audiobooks"].exists)
    }

    func testExploreShowsFeaturedCollectionsWithoutAddPanels() {
        let app = launchApp(initialTab: "explore")

        XCTAssertTrue(app.staticTexts["Featured Collections"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Add from Internet Archive"].exists)
        XCTAssertFalse(app.staticTexts["Add Local Audiobooks"].exists)
        XCTAssertFalse(app.staticTexts["On This Device"].exists)
    }

    func testMoreShowsCacheSettings() {
        let app = launchApp(initialTab: "more")

        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Clear Cache"].exists)
    }

    func testHomeHasNoSearchSectionActionButSearchTabReachable() {
        let app = launchApp(initialTab: "home")

        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        // Only the tab-bar "Search" control should exist — the Home section action was removed.
        let searchButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertEqual(searchButtons.count, 1)

        // The Search tab remains reachable from the dock.
        searchButtons.firstMatch.tap()
        XCTAssertTrue(app.textFields["Search LibriVox audiobooks"].waitForExistence(timeout: 10))
    }
}
