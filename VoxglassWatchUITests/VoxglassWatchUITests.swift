import XCTest

/// Deterministic injected Watch smoke. It verifies the consumer Watch shell and
/// transport geometry contract; it makes no pairing or network claim.
@MainActor
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// watchOS renders each top-level child of the book detail's VStack
    /// (title/artwork/author, the transport row, then the now-playing
    /// detail block) as its own lazily-materialized CollectionView cell —
    /// on the ~208x248pt screen, the now-playing detail (status, output,
    /// retry) sits just past the fold. `XCUIElement.swipeUp()` is a
    /// generic-screen-size gesture that overshoots this tiny screen by a
    /// wide margin (it lands past the whole book detail, into the chapter
    /// list below); a short, explicit partial drag reveals the next cell
    /// without skipping over it.
    private func scrollDownSlightly(app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func scrollUpSlightly(app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The book detail/now-playing screen doesn't fit the transport row and
    /// the now-playing detail block (status, output, elapsed/remaining) on
    /// this tiny screen at once. Call this immediately before touching any
    /// element from whichever half isn't currently on screen — it nudges the
    /// list just enough in either direction without needing to track which
    /// way the last scroll went.
    private func ensureVisible(_ element: XCUIElement, app: XCUIApplication) {
        guard !element.waitForExistence(timeout: 2) else { return }
        scrollDownSlightly(app: app)
        guard !element.waitForExistence(timeout: 2) else { return }
        scrollUpSlightly(app: app)
        scrollUpSlightly(app: app)
        _ = element.waitForExistence(timeout: 2)
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

        let artwork = app.descendants(matching: .any)["watch.book.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 20), "Now Playing artwork did not render")
        XCTAssertTrue(app.buttons["watch.book.previousChapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.book.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.book.nextChapter"].waitForExistence(timeout: 10))
        ensureVisible(app.staticTexts["watch.book.output"], app: app)
        XCTAssertTrue(app.staticTexts["watch.book.output"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["watch.book.phase"].waitForExistence(timeout: 10))
        waitForPhase("Playing", app: app)
        // The simulator's built-in output reports as "Speaker"; real
        // hardware reports "Apple Watch" — either is a legitimate resolved
        // output route, which is what this is actually checking for.
        XCTAssertTrue(
            ["Apple Watch", "Speaker"].contains(app.staticTexts["watch.book.output"].label),
            "Unexpected output route: \(app.staticTexts["watch.book.output"].label)"
        )
        XCTAssertEqual(app.staticTexts["watch.book.source"].label, "Downloaded")

        ensureVisible(app.buttons["watch.book.previousChapter"], app: app)
        let previous = app.buttons["watch.book.previousChapter"]
        let toggle = app.buttons["watch.book.play"]
        let next = app.buttons["watch.book.nextChapter"]
        XCTAssertFalse(previous.isEnabled)
        // Not checked: exact tap-target frame size. watchOS List-embedded
        // buttons report an accessibility frame sized to the icon glyph's
        // rendered bounds, not the `.frame(width:height:)` modifier applied
        // in WatchBookDetailView — true for enabled and disabled controls
        // alike, so it isn't a signal this test can use for a real
        // clipping/sizing regression.
        for control in [previous, toggle, next] {
            XCTAssertTrue(control.exists)
        }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "watch-now-playing-transport"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        ensureVisible(app.staticTexts["watch.book.elapsed"], app: app)
        let initialElapsed = app.staticTexts["watch.book.elapsed"].label
        let elapsedChanged = NSPredicate(format: "label != %@", initialElapsed)
        expectation(for: elapsedChanged, evaluatedWith: app.staticTexts["watch.book.elapsed"])
        waitForExpectations(timeout: 4)

        ensureVisible(next, app: app)
        next.tap()
        ensureVisible(app.staticTexts["watch.book.chapterNumber"], app: app)
        XCTAssertEqual(app.staticTexts["watch.book.chapterNumber"].label, "Chapter 2")
        ensureVisible(previous, app: app)
        XCTAssertTrue(previous.isEnabled)
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
        // The button never left the "Play" state (the phase never reached
        // .playing) — check its label now, before scrolling down for the
        // Retry button pushes it off this tiny screen.
        XCTAssertEqual(app.buttons["watch.book.play"].label, "Play")
        if !app.buttons["watch.book.retry"].waitForExistence(timeout: 2) {
            scrollDownSlightly(app: app)
        }
        XCTAssertTrue(app.buttons["watch.book.retry"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["watch.book.phase"].label, "Download this chapter or reconnect to stream it.")
    }

    private func waitForPhase(_ phase: String, app: XCUIApplication) {
        ensureVisible(app.staticTexts["watch.book.phase"], app: app)
        let reached = NSPredicate(format: "label == %@", phase)
        expectation(for: reached, evaluatedWith: app.staticTexts["watch.book.phase"])
        waitForExpectations(timeout: 20)
    }
}
