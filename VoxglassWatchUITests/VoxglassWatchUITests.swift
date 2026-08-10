import XCTest

/// The single watch smoke test (repo convention: one UI smoke test per device).
/// Everything else runs under `swift test`; this target proves the two
/// field-tested flows — production review (seeded via
/// `-uiTestSeed watchQueue`, never touching CloudKit or the microphone) and
/// real LibriVox Alice playback with download — both launch and drive the real
/// watch UI.
final class VoxglassWatchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testWatchProductionReviewAndStreamingSmoke() {
        runProductionReviewSmoke()
        runAliceStreamingSmoke()
    }

    /// Production review smoke (spec §19.6): production → Review Flagged →
    /// review player → approve → confirmation sheet.
    private func runProductionReviewSmoke() {
        let app = XCUIApplication()
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_PRODUCTION"] = "1"
        app.launchArguments += ["-uiTestSeed", "watchQueue", "-VOXGLASS_WATCH_SMOKE_PRODUCTION", "YES"]
        app.launch()

        // Productions is the third of five tabs; swipe to it if needed.
        let ackroyd = app.buttons["watch.production.rogerAckroyd"]
        if !ackroyd.waitForExistence(timeout: 4) {
            app.swipeLeft()
            if !ackroyd.waitForExistence(timeout: 4) {
                app.swipeLeft()
            }
        }
        XCTAssertTrue(
            ackroyd.waitForExistence(timeout: 5),
            "Production row did not render.\n\(app.debugDescription)"
        )
        ackroyd.tap()

        let reviewFlagged = app.buttons["watch.reviewFlagged"]
        XCTAssertTrue(
            reviewFlagged.waitForExistence(timeout: 5),
            "Production home did not render Review Flagged.\n\(app.debugDescription)"
        )
        reviewFlagged.tap()

        let approve = app.buttons["watch.player.approve"]
        XCTAssertTrue(
            approve.waitForExistence(timeout: 5),
            "Review player did not render.\n\(app.debugDescription)"
        )
        approve.tap()

        let confirmed = app.staticTexts["watch.confirmation.approved"]
        XCTAssertTrue(
            confirmed.waitForExistence(timeout: 5),
            "Approval confirmation sheet did not appear.\n\(app.debugDescription)"
        )
    }

    private func runAliceStreamingSmoke() {
        let app = XCUIApplication()
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_ALICE"] = "1"
        app.launchEnvironment["VOXGLASS_WATCH_SMOKE_RESET_CACHE"] = "1"
        app.launchArguments += [
            "-VOXGLASS_WATCH_SMOKE_ALICE",
            "YES",
            "-VOXGLASS_WATCH_SMOKE_RESET_CACHE",
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

        let chapterNumber = app.staticTexts[WatchAccessibilityID.npChapterNumber]
        XCTAssertTrue(
            chapterNumber.waitForExistence(timeout: 10),
            "Now Playing did not expose the current chapter number.\n\(app.debugDescription)"
        )
        XCTAssertEqual(chapterNumber.label, "Chapter 1 of 3")

        let elapsed = app.staticTexts[WatchAccessibilityID.npElapsed]
        let remaining = app.staticTexts[WatchAccessibilityID.npRemaining]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Now Playing did not expose elapsed time")
        XCTAssertTrue(remaining.waitForExistence(timeout: 10), "Now Playing did not expose remaining time")
        let initialElapsed = seconds(fromClock: elapsed.label)
        let initialRemaining = seconds(fromClock: remaining.label)
        XCTAssertNotNil(initialElapsed, "Elapsed time was not parseable: \(elapsed.label)")
        XCTAssertNotNil(initialRemaining, "Remaining time was not parseable: \(remaining.label)")
        XCTAssertTrue(
            waitForClock(elapsed, toAdvancePast: initialElapsed ?? 0, timeout: 20),
            "Elapsed time did not advance while Alice was playing. Initial: \(elapsed.label)"
        )
        XCTAssertTrue(
            waitForClock(remaining, toDecreaseBelow: initialRemaining ?? Int.max, timeout: 20),
            "Remaining time did not decrease while Alice was playing. Initial: \(remaining.label)"
        )

        let playPause = app.buttons[WatchAccessibilityID.npPlayPause]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Now Playing did not expose play/pause")
        playPause.tap()
        XCTAssertTrue(
            waitForLabel(playingState, "Paused", timeout: 10),
            "Alice did not pause after tapping play/pause"
        )
        playPause.tap()
        XCTAssertTrue(
            waitForLabel(playingState, "Playing", timeout: 20),
            "Alice did not resume playback after tapping play/pause"
        )

        let nextChapter = app.buttons[WatchAccessibilityID.npChapterNext]
        XCTAssertTrue(
            nextChapter.waitForExistence(timeout: 10),
            "Now Playing did not expose next chapter control"
        )
        XCTAssertTrue(nextChapter.isEnabled, "Alice chapter 1 should allow skipping to chapter 2")
        nextChapter.tap()
        XCTAssertTrue(
            waitForLabel(chapterNumber, "Chapter 2 of 3", timeout: 20),
            "Skipping to the next chapter did not update the chapter number"
        )
        let prevChapter = app.buttons[WatchAccessibilityID.npChapterPrev]
        XCTAssertTrue(prevChapter.waitForExistence(timeout: 5))
        XCTAssertTrue(prevChapter.isEnabled, "Chapter 2 should allow skipping back")

        XCTAssertTrue(
            tapWhenHittable(app.buttons[WatchAccessibilityID.npDownload], in: app, timeout: 10),
            "Now Playing did not expose the watch download/status control"
        )
        let fetchStatus = app.descendants(matching: .any)[WatchAccessibilityID.fetchStatus]
        XCTAssertTrue(
            fetchStatus.waitForExistence(timeout: 10),
            "Download status sheet did not open.\n\(app.debugDescription)"
        )
        let downloadButton = app.buttons[WatchAccessibilityID.bookFetch]
        XCTAssertTrue(
            tapWhenHittable(downloadButton, in: app, timeout: 12),
            "Download button was not tappable"
        )

        let chapter1 = app.staticTexts[WatchAccessibilityID.fetchChapterState(1)]
        XCTAssertTrue(
            waitForAnyLabel(chapter1, ["Downloading", "Downloaded"], timeout: 45),
            "Chapter 1 did not show download progress. Current: \(chapter1.exists ? chapter1.label : "missing")\n\(app.debugDescription)"
        )
        for chapter in 1...3 {
            let state = app.staticTexts[WatchAccessibilityID.fetchChapterState(chapter)]
            XCTAssertTrue(
                waitForLabel(state, "Downloaded", timeout: 180),
                "Chapter \(chapter) did not finish downloading to the watch. Current: \(state.exists ? state.label : "missing")\n\(app.debugDescription)"
            )
        }
        let overall = app.staticTexts[WatchAccessibilityID.fetchOverallState]
        XCTAssertTrue(
            waitForLabel(overall, "Ready", timeout: 30),
            "Book-level watch download state did not reach Ready. Current: \(overall.exists ? overall.label : "missing")\n\(app.debugDescription)"
        )
    }

    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable {
                element.tap()
                return true
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        if element.exists, element.isHittable {
            element.tap()
            return true
        }
        return false
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        waitForAnyLabel(element, [label], timeout: timeout)
    }

    private func waitForAnyLabel(_ element: XCUIElement, _ labels: Set<String>, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, labels.contains(element.label) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return element.exists && labels.contains(element.label)
    }

    private func waitForAnyLabel(_ element: XCUIElement, _ labels: [String], timeout: TimeInterval) -> Bool {
        waitForAnyLabel(element, Set(labels), timeout: timeout)
    }

    private func waitForClock(_ element: XCUIElement, toAdvancePast initial: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists,
               let current = seconds(fromClock: element.label),
               current > initial {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func waitForClock(_ element: XCUIElement, toDecreaseBelow initial: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists,
               let current = seconds(fromClock: element.label),
               current < initial {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func seconds(fromClock label: String) -> Int? {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let pieces = normalized.split(separator: ":").compactMap { Int($0) }
        switch pieces.count {
        case 2:
            return pieces[0] * 60 + pieces[1]
        case 3:
            return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        default:
            return nil
        }
    }
}

private enum WatchAccessibilityID {
    static let bookStream = "book.stream"
    static let bookFetch = "book.fetch"
    static let npPlayPause = "np.playpause"
    static let npState = "np.state"
    static let npChapterNumber = "np.chapterNumber"
    static let npElapsed = "np.elapsed"
    static let npRemaining = "np.remaining"
    static let npDownload = "np.download"
    static let npChapterNext = "np.chapterNext"
    static let npChapterPrev = "np.chapterPrev"
    static let fetchStatus = "fetch.status"
    static let fetchOverallState = "fetch.overallState"

    static func fetchChapterState(_ chapterNumber: Int) -> String {
        "fetch.chapter.\(chapterNumber).state"
    }
}
