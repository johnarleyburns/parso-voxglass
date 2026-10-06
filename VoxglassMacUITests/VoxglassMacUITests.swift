import XCTest

@MainActor
final class VoxglassMacUITests: XCTestCase {
    private func launchApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "guru.parso.voxglass")
        // Keep the native macOS window layout deterministic. macOS persists the
        // sidebar/window state between launches, which can otherwise hide the
        // destination list from tests that start on a seeded book flow.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-uiTestDisableCloudKit"] + arguments
        app.launch()
        return app
    }

    func testNativeMacShellExposesAllFourDestinations() {
        let app = launchApp()

        for destination in ["listen", "books", "discover", "narration"] {
            let item = app.descendants(matching: .any)["native-mac.sidebar.\(destination)"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), "Missing native Mac destination: \(destination)")
        }
    }

    func testInspectorToolbarIsReachable() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["native-mac.toolbar.inspector"].waitForExistence(timeout: 10))
    }

    func testBookDetailAndNowPlayingExposeTheFullPlaybackSurface() {
        let app = launchApp(arguments: ["-uiTestSeedBook"])

        let booksDestination = app.descendants(matching: .any)["native-mac.sidebar.books"]
        XCTAssertTrue(booksDestination.waitForExistence(timeout: 10))
        booksDestination.click()
        let openBook = app.buttons["native-mac.book.open.8B4C7B13-3A1F-4D69-9BE5-ED65C8B8A4D0"]
        XCTAssertTrue(openBook.waitForExistence(timeout: 10))
        openBook.click()

        XCTAssertTrue(app.descendants(matching: .any)["native-mac.book-detail"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["native-mac.book-detail.listen"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Artwork for The Mac Playback Test Book"].exists)

        app.buttons["native-mac.book-detail.listen"].click()

        XCTAssertTrue(app.descendants(matching: .any)["native-mac.now-playing"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["native-mac.now-playing.playPause"].exists)
        XCTAssertTrue(app.sliders["native-mac.now-playing.scrubber"].exists)
        XCTAssertTrue(app.buttons["native-mac.now-playing.previousChapter"].exists)
        XCTAssertTrue(app.buttons["native-mac.now-playing.nextChapter"].exists)
        XCTAssertTrue(app.buttons["native-mac.now-playing.skipBack"].exists)
        XCTAssertTrue(app.buttons["native-mac.now-playing.skipForward"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["native-mac.now-playing.speed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["native-mac.now-playing.sleepTimer"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["native-mac.now-playing.bookmark"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["native-mac.now-playing.equalizer"].exists)
    }

    func testBookDetailChapterHasAnAccessiblePlaybackLabel() {
        let app = launchApp(arguments: ["-uiTestSeedBook"])

        let booksDestination = app.descendants(matching: .any)["native-mac.sidebar.books"]
        XCTAssertTrue(booksDestination.waitForExistence(timeout: 10))
        booksDestination.click()
        app.buttons["native-mac.book.open.8B4C7B13-3A1F-4D69-9BE5-ED65C8B8A4D0"].waitForExistence(timeout: 10)
        app.buttons["native-mac.book.open.8B4C7B13-3A1F-4D69-9BE5-ED65C8B8A4D0"].click()

        let chapter = app.buttons["native-mac.book-detail.chapter.0"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        XCTAssertTrue(chapter.label.contains("Play Chapter 1"))
    }
}
