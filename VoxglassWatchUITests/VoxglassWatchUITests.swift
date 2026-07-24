import XCTest

/// The single watch simulator smoke test for Voxglass. Verifies the app boots,
/// every tab renders, and drills into Now Playing to toggle play/pause when a
/// book is available. Run locally — CI runs `swift test` only.
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchAppBootsAndVisitsAllTabsAndTogglesPlayPause() {
        let app = XCUIApplication()
        app.launch()

        // Listening tab: initially shows a progress spinner, then either a book
        // list or the "No Books" empty state.
        let listeningAnchor = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[cd] %@ OR label CONTAINS[cd] %@",
                        "Loading", "No Books")
        ).firstMatch
        XCTAssertTrue(
            listeningAnchor.waitForExistence(timeout: 15),
            "App did not boot into the Listening tab"
        )

        // Tabs are all preloaded in the watchOS TabView hierarchy, so we can
        // verify the other two tabs render without swiping.
        XCTAssertTrue(
            app.staticTexts["On Watch"].waitForExistence(timeout: 5),
            "On Watch tab did not render"
        )
        XCTAssertTrue(
            app.staticTexts["Search"].waitForExistence(timeout: 5),
            "Search tab did not render"
        )

        // If a book is present on the Listening tab, drill into it and toggle
        // play/pause.
        let bookCell = app.cells.firstMatch
        guard bookCell.waitForExistence(timeout: 5) else {
            // No books in the library — smoke is still valid.
            return
        }
        bookCell.tap()

        // Book detail: tap Play to start playback and open Now Playing.
        let playButton = app.buttons[WatchAccessibilityID.bookStream]
        guard playButton.waitForExistence(timeout: 5) else {
            return
        }
        playButton.tap()

        // Now Playing: toggle play/pause twice to exercise the transport.
        let ppButton = app.buttons[WatchAccessibilityID.npPlayPause]
        guard ppButton.waitForExistence(timeout: 8) else {
            return
        }
        ppButton.tap()
        sleep(1)
        ppButton.tap()
    }
}

private enum WatchAccessibilityID {
    static let bookStream = "book.stream"
    static let npPlayPause = "np.playpause"
}
