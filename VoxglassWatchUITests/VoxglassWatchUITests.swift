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

        XCTAssertTrue(app.navigationBars["Voxglass"].waitForExistence(timeout: 20),
                      "Watch Home did not render.\n\(app.debugDescription)")
        XCTAssertNoThrow(try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion,
                                                                  .sufficientElementDescription, .textClipped, .trait]))
        let alice = bookRow(app, titled: "Alice's Adventures in Wonderland")
        XCTAssertTrue(alice.waitForExistence(timeout: 10),
                      "Injected library fixture did not render.\n\(app.debugDescription)")
        snapshot("H1-home")
        alice.tap()

        // Watch redesign B1: the Book page's one big button starts playback and opens the Player.
        // The fixture isn't on the watch and the iPhone is nearby (B2): Download is primary and
        // Stream Chapter 1 sits right under it.
        XCTAssertTrue(app.buttons["watch.book.download"].waitForExistence(timeout: 10))
        let start = app.buttons["watch.book.stream"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        snapshot("B2-book")
        tapFullyVisible(start, app: app)

        let artwork = app.descendants(matching: .any)["watch.book.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 20), "Player artwork did not render")
        XCTAssertTrue(app.buttons["watch.book.skipBack"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.book.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.book.skipForward"].waitForExistence(timeout: 10))
        let output = app.descendants(matching: .any)["watch.book.output"]
        XCTAssertTrue(output.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertNoThrow(try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion,
                                                                  .sufficientElementDescription, .textClipped, .trait]))
        waitForPhase("Playing", app: app)
        // The simulator's built-in output reports as "Speaker"; real hardware reports "Apple Watch"
        // — either is a resolved output route. The chip carries the source as its value.
        XCTAssertTrue(["Apple Watch", "Speaker"].contains(output.label), "Unexpected output route: \(output.label)")
        XCTAssertEqual(output.value as? String, "Downloaded")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "watch-player-transport"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        ensureVisible(app.staticTexts["watch.book.elapsed"], app: app)
        let initialElapsed = app.staticTexts["watch.book.elapsed"].label
        let elapsedChanged = NSPredicate(format: "label != %@", initialElapsed)
        expectation(for: elapsedChanged, evaluatedWith: app.staticTexts["watch.book.elapsed"])
        waitForExpectations(timeout: 4)

        // Watch redesign C1: previous/next chapter live on the Chapters list (the face skips time).
        app.buttons["watch.book.chapters"].tap()
        let previous = app.buttons["watch.book.previousChapter"]
        let next = app.buttons["watch.book.nextChapter"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        snapshot("C1-chapters")
        XCTAssertFalse(previous.isEnabled)
        next.tap()
        ensureVisible(app.staticTexts["watch.book.currentChapter"], app: app)
        XCTAssertEqual(app.staticTexts["watch.book.currentChapter"].label, "Chapter 2")
        app.buttons["watch.book.chapters"].tap()
        XCTAssertTrue(app.buttons["watch.book.previousChapter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["watch.book.previousChapter"].isEnabled)
    }

    func testWatchPlaybackFailureIsActionable() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "watch-playback-failure"]
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_ALICE"] = "1"
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_PLAYBACK_FAILURE"] = "1"
        app.launch()

        let alice = bookRow(app, titled: "Alice's Adventures in Wonderland")
        XCTAssertTrue(alice.waitForExistence(timeout: 20))
        alice.tap()
        XCTAssertTrue(app.buttons["watch.book.stream"].waitForExistence(timeout: 10))
        tapFullyVisible(app.buttons["watch.book.stream"], app: app)
        // Watch redesign S3: the Problem Card replaces the transport in place, with its action and
        // diagnostic code — never a Play button that silently does nothing.
        XCTAssertTrue(app.descendants(matching: .any)["watch.book.problem"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertFalse(app.buttons["watch.book.play"].exists)
        if !app.buttons["watch.book.retry"].waitForExistence(timeout: 2) {
            scrollDownSlightly(app: app)
        }
        XCTAssertTrue(app.buttons["watch.book.retry"].waitForExistence(timeout: 10), app.debugDescription)
        snapshot("S3-problem")
        XCTAssertEqual(app.staticTexts["watch.book.phase"].label, "Download this chapter or reconnect to stream it.")
        XCTAssertTrue(app.staticTexts["watch.book.errorCode"].label.hasSuffix("chapterUnavailable"),
                      app.staticTexts["watch.book.errorCode"].label)
    }

    /// Scrolls with the Digital Crown until the element is wholly on screen, then taps it. A row
    /// under the bottom edge reports hittable but its centre is off the display.
    private func tapFullyVisible(_ element: XCUIElement, app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 where !(element.isHittable && element.frame.maxY <= window.maxY) {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.2)
            _ = element.waitForExistence(timeout: 1)
        }
        element.tap()
    }

    /// Screenshot per mockup state, for the watch-redesign fidelity audit.
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Library rows combine their children into one button labelled with the title.
    private func bookRow(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// The play button carries the playback status as its value (P1 shows no status line while
    /// playing).
    private func waitForPhase(_ phase: String, app: XCUIApplication) {
        let reached = NSPredicate(format: "value BEGINSWITH %@", phase)
        expectation(for: reached, evaluatedWith: app.buttons["watch.book.play"])
        waitForExpectations(timeout: 20)
    }
}
