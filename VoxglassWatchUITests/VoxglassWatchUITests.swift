import XCTest

/// Deterministic injected Watch smoke. It verifies the consumer Watch shell and
/// transport geometry contract; it makes no pairing or network claim.
@MainActor
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchLibraryAndNowPlayingSmoke() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "watch-library"]
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
        XCTAssertTrue(app.staticTexts["watch.player.phase"].waitForExistence(timeout: 10))
        waitForPhase("Playing", app: app)
        XCTAssertEqual(app.staticTexts["watch.player.output"].label, "Apple Watch")
        XCTAssertEqual(app.staticTexts["watch.player.source"].label, "Downloaded")

        let previous = app.buttons["watch.player.previousChapter"]
        let toggle = app.buttons["watch.player.playPause"]
        let next = app.buttons["watch.player.nextChapter"]
        XCTAssertFalse(previous.isEnabled)
        for control in [previous, toggle, next] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(app.frame.contains(control.frame), "Transport control is clipped: \(control.frame) in \(app.frame)")
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "watch-now-playing-transport"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let initialElapsed = app.staticTexts["watch.player.elapsed"].label
        let elapsedChanged = NSPredicate(format: "label != %@", initialElapsed)
        expectation(for: elapsedChanged, evaluatedWith: app.staticTexts["watch.player.elapsed"])
        waitForExpectations(timeout: 4)

        toggle.tap()
        waitForPhase("Paused", app: app)
        XCTAssertEqual(toggle.label, "Play")
        toggle.tap()
        waitForPhase("Playing", app: app)
        XCTAssertEqual(toggle.label, "Pause")

        next.tap()
        XCTAssertEqual(app.staticTexts["watch.player.chapter"].label, "Chapter 2")
        XCTAssertTrue(previous.isEnabled)
        previous.tap()
        XCTAssertEqual(app.staticTexts["watch.player.chapter"].label, "Chapter 1")
        next.tap()
        next.tap()
        XCTAssertEqual(app.staticTexts["watch.player.chapter"].label, "Chapter 3")
        XCTAssertFalse(next.isEnabled)
    }

    func testWatchPlaybackFailureIsActionable() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "watch-playback-failure"]
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_ALICE"] = "1"
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_PLAYBACK_FAILURE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Alice's Adventures in Wonderland"].waitForExistence(timeout: 20))
        app.staticTexts["Alice's Adventures in Wonderland"].tap()
        XCTAssertTrue(app.buttons["watch.book.play"].waitForExistence(timeout: 10))
        app.buttons["watch.book.play"].tap()
        XCTAssertTrue(app.buttons["watch.player.retry"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["watch.player.phase"].label, "Download this chapter or reconnect to stream it.")
        XCTAssertEqual(app.buttons["watch.player.playPause"].label, "Play")
    }

    private func waitForPhase(_ phase: String, app: XCUIApplication) {
        let reached = NSPredicate(format: "label == %@", phase)
        expectation(for: reached, evaluatedWith: app.staticTexts["watch.player.phase"])
        waitForExpectations(timeout: 10)
    }
}
