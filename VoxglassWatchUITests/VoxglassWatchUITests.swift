import XCTest

/// Real watch smoke for the field-tested path. It seeds a known LibriVox Alice
/// item, opens it through the normal watch UI, starts the watch playback engine
/// against the archive.org stream URL, and fails unless Now Playing reports
/// Playing.
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchStreamsLibriVoxAliceAndShowsPlaying() {
        let app = XCUIApplication()
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_ALICE"] = "1"
        app.launchArguments += [
            "-VOXGLASS_WATCH_SMOKE_ALICE",
            "YES"
        ]
        app.launch()

        let aliceCell = app.buttons["Alice's Adventures in Wonderland"]
        XCTAssertTrue(
            aliceCell.waitForExistence(timeout: 20),
            "Alice smoke fixture did not render in My Books.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            aliceCell.isEnabled,
            "Alice row rendered but was not tappable.\n\(app.debugDescription)"
        )
        aliceCell.tap()

        let playButton = app.buttons[WatchAccessibilityID.bookStream]
        XCTAssertTrue(
            playButton.waitForExistence(timeout: 10),
            "Alice detail did not expose the Play/Stream action"
        )
        playButton.tap()

        let playingState = app.staticTexts[WatchAccessibilityID.npState]
        XCTAssertTrue(
            playingState.waitForExistence(timeout: 45),
            "Now Playing did not show a playback state after tapping Play"
        )
        XCTAssertEqual(
            playingState.label,
            "Playing",
            "Watch playback did not reach the real Playing state for LibriVox Alice"
        )

        let nextChapter = app.buttons[WatchAccessibilityID.npChapterNext]
        XCTAssertTrue(
            nextChapter.waitForExistence(timeout: 10),
            "Now Playing did not expose next chapter control"
        )
        if nextChapter.isEnabled {
            nextChapter.tap()
            sleep(1)
            let prevChapter = app.buttons[WatchAccessibilityID.npChapterPrev]
            XCTAssertTrue(prevChapter.waitForExistence(timeout: 5))
        }
    }
}

private enum WatchAccessibilityID {
    static let bookStream = "book.stream"
    static let npState = "np.state"
    static let npChapterNext = "np.chapterNext"
    static let npChapterPrev = "np.chapterPrev"
}
