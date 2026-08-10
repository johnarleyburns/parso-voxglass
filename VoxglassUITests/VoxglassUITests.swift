import XCTest

/// The single simulator smoke test for Voxglass. Everything else is covered by
/// the host `swift test` logic suite (VoxglassCore); this only proves the app
/// boots, every tab renders without crashing, the ten-band EQ is reachable and
/// draggable, and the My Productions surface (seeded via
/// `-uiTestSeed onePreviewProject`) is reachable — not just present in source
/// (WP-G). Run locally on iPhone 16 — CI runs `swift test` only and never runs
/// this target. One UI smoke test per device by repo convention.
final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppBootsVisitsAllTabsEQAndProductions() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-voxglass.narration.onboardingSeen.v1", "YES",
            "-VoxglassInitialTab", "home",
            "-VoxglassDisableAnimatedSplash",
            // Starts the narration flow from a clean store so the record step
            // is deterministic (resume could land on Review/Assemble instead).
            "-uiTestResetNarrations",
            // Scripted capture: the record step must never depend on the
            // simulator's audio input (unreliable since iOS 17) — the fake
            // writes silent takes so the flow runs end-to-end with no mic.
            "-uiTestFakeCapture",
            // Seeds one previewable production (WP-G) and keeps the G-8 guard
            // honest that no UI test runs without a declared test environment.
            "-uiTestSeed", "onePreviewProject",
            // On a real device MediaPlayer invokes the MPMediaItemArtwork
            // requestHandler from a background queue; a contextually @MainActor
            // handler traps there and kills the app on launch. This hook runs
            // that same off-main call on the simulator, where MediaPlayer never
            // renders Now Playing and would otherwise never exercise the path.
            "-uiTestExerciseArtworkOffMain"
        ]
        app.launch()

        // Boots into the Listen tab. The artwork requestHandler was already
        // invoked from a background queue during launch, so this proves the
        // app survived the off-main call that crashes contextually-isolated
        // handlers on device (TestFlight startup crash).
        XCTAssertTrue(
            app.staticTexts["Recommended for You"].waitForExistence(timeout: 15),
            "App did not boot into the Listen tab — artwork requestHandler may have crashed off-main.\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "App terminated after the off-main artwork requestHandler call (executor isolation trap)."
        )

        // Every tab is reachable and renders a stable anchor without crashing.
        let tabs: [(button: String, anchor: String)] = [
            ("My Books", "My Books"),
            ("Explore", "Featured Collections"),
            ("Narration", "Start a Narration"),
            ("Listen", "Recommended for You")
        ]
        for tab in tabs {
            app.buttons[tab.button].tap()
            XCTAssertTrue(
                app.staticTexts[tab.anchor].waitForExistence(timeout: 10),
                "Tab \(tab.button) did not render its content"
            )
        }

        // My Productions reachability (spec §18.2, WP-G): Library → My
        // Productions → seeded project card → detail review actions.
        app.buttons["My Books"].tap()
        let shelf = app.buttons["shelf.myProductions"]
        XCTAssertTrue(
            shelf.waitForExistence(timeout: 10),
            "My Productions entry not on the Library tab.\n\(app.debugDescription)"
        )
        shelf.tap()

        let card = app.descendants(matching: .any)["production.themurderofrogerackroyd"]
        XCTAssertTrue(
            card.waitForExistence(timeout: 10),
            "Seeded production card did not render.\n\(app.debugDescription)"
        )
        card.tap()
        XCTAssertTrue(
            app.buttons["detail.playWholeBook"].waitForExistence(timeout: 10),
            "detail.playWholeBook not reachable.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.buttons["detail.reviewFlagged"].exists,
            "detail.reviewFlagged not reachable.\n\(app.debugDescription)"
        )

        // Narration recording (regression gate): the record button must
        // actually start a take. Catches OSStatus -50 / setCategory capture
        // failures that previously made recording impossible on device.
        app.buttons["Narration"].tap()
        XCTAssertTrue(
            app.staticTexts["Start a Narration"].waitForExistence(timeout: 10),
            "Narration tab did not render after returning\n\(app.debugDescription)"
        )

        let startNarrationShelf = app.descendants(matching: .any)["home.startNarrationShelf"]
        XCTAssertTrue(
            startNarrationShelf.exists,
            "Start a Narration shelf not found on Narration tab.\n\(app.debugDescription)"
        )

        let featuredNeed = app.buttons["needs.featured"]
        for _ in 0..<8 where !featuredNeed.exists {
            app.swipeUp()
            _ = featuredNeed.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(
            featuredNeed.waitForExistence(timeout: 30),
            "Featured narration need not found after ladder load.\n\(app.debugDescription)"
        )
        for _ in 0..<4 where featuredNeed.exists && !featuredNeed.isHittable {
            app.swipeUp()
            _ = featuredNeed.waitForExistence(timeout: 2)
        }
        featuredNeed.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["record.teleprompter"].waitForExistence(timeout: 10),
            "Record screen did not open.\n\(app.debugDescription)"
        )

        let recordButton = app.buttons["record.transport.record"]
        XCTAssertTrue(
            recordButton.waitForExistence(timeout: 10),
            "Record transport not found.\n\(app.debugDescription)"
        )
        recordButton.tap()

        XCTAssertTrue(
            app.staticTexts["● REC"].waitForExistence(timeout: 10),
            "Recording did not start — capture failed.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'failed'")).firstMatch.exists,
            "Recording error card shown.\n\(app.debugDescription)"
        )

        recordButton.tap() // stop

        XCTAssertTrue(
            app.staticTexts["record.take.1"].waitForExistence(timeout: 10),
            "Take was not saved after stopping.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.buttons["record.acceptAndNext"].isEnabled,
            "Accept & Next should be enabled once a take exists.\n\(app.debugDescription)"
        )

        // Back out of the narration flow to continue the smoke path.
        app.buttons["Close"].tap()
        XCTAssertTrue(
            app.staticTexts["Start a Narration"].waitForExistence(timeout: 10),
            "Narration flow did not close.\n\(app.debugDescription)"
        )

        // Search renders its field (kept last: it puts focus in a text field).
        app.buttons["Search"].tap()
        XCTAssertTrue(
            app.textFields["Search LibriVox audiobooks"].waitForExistence(timeout: 10),
            "Search tab did not render its search field"
        )

        // The ten-band EQ is reachable from the "…" menu on the home view and
        // every band is draggable — folded into the smoke test so this target
        // has exactly one.
        app.buttons["Listen"].tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        let moreMenu = app.buttons["home.moreMenu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), "More menu not on home view.\n\(app.debugDescription)")
        moreMenu.tap()
        app.buttons["Equalizer"].tap()

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
