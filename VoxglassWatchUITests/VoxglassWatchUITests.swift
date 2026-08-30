import XCTest

/// Deterministic injected Watch smoke. It verifies the consumer Watch shell and
/// transport geometry contract; it makes no pairing or network claim.
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchLibraryAndNowPlayingSmoke() {
        let app = XCUIApplication()
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_ALICE"] = "1"
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_RESET_CACHE"] = "1"
        app.launchArguments += [
            "-VOXGLASS_WATCH_SMOKE_ALICE", "YES",
            "-VOXGLASS_WATCH_SMOKE_RESET_CACHE", "YES"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["My Books"].waitForExistence(timeout: 20),
                      "Watch My Books did not render.\n\(app.debugDescription)")
        let alice = app.staticTexts["Alice's Adventures in Wonderland"]
        XCTAssertTrue(alice.waitForExistence(timeout: 10),
                      "Injected My Books fixture did not render.\n\(app.debugDescription)")
        alice.tap()

        let play = app.buttons["watch.book.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let artwork = app.descendants(matching: .any)["watch.player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 20), "Now Playing artwork did not render")
        XCTAssertTrue(app.buttons["watch.player.previousChapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.player.playPause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.player.nextChapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["watch.player.output"].waitForExistence(timeout: 10))
    }
}
