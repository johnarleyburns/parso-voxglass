import XCTest
import VoxglassCore

/// The single simulator smoke test for Voxglass. Everything else is covered by
/// the host `swift test` logic suite (VoxglassCore); this proves the app
/// boots, every tab renders, Settings/History/Storage/Featured-Collections
/// open without crashing, and the EQ is reachable and toggleable.
///
/// Run locally on iPhone 16 — CI runs `swift test` only and never runs this
/// target. One UI smoke test per device by repo convention.
@MainActor
final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppBootsVisitsAllTabsEQAndProductions() throws {
        let app = XCUIApplication()

        app.launchArguments += [
            "-VoxglassInitialTab", "home",
            // build-for-testing runs this simulator bundle unsigned, so the
            // local smoke path must not initialize entitlement-backed CloudKit.
            "-uiTestDisableCloudKit",
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
            ("Find", "Featured Collections"),
            ("Listen", "Recommended for You")
        ]
        for tabSpec in tabs {
            tab(tabSpec.button, in: app).tap()
            XCTAssertTrue(
                app.staticTexts[tabSpec.anchor].waitForExistence(timeout: 10),
                "Tab \(tabSpec.button) did not render its content"
            )
            XCTAssertNoThrow(try auditAccessibility(app, tabSpec.button))
        }

        assertSettingsOpensFromHomeWithoutCrashing(app: app)
        XCTAssertNoThrow(try auditAccessibility(app, "Settings"))
        assertEQTogglesFromSettingsWithoutCrashing(app: app)
        assertStorageCardsFitCompactWidth(app: app)
        assertHistoryOpensFromExploreWithoutCrashing(app: app)
        assertFeaturedCollectionsRespectSelectedLanguage(app: app)
        auditBookPageIfPresent(app: app)

        // The EQ step needs the Listen tab anyway; switch there first, then Discover.
        tab("Listen", in: app).tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        // Discover renders the catalog search field (kept last: it puts focus in a text field).
        tab("Find", in: app).tap()
        let searchField = app.textFields["discover.catalogSearch"]
        if !searchField.waitForExistence(timeout: 20) {
            tab("Find", in: app).tap()
            _ = searchField.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(
            searchField.exists,
            "Find did not render its catalog search field.\n\(app.debugDescription)"
        )

        // The ten-band EQ is reachable from Settings (Audio section) and
        // every band is draggable — folded into the smoke test so this
        // target has exactly one.
        tab("Listen", in: app).tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        let settingsButton = app.buttons["home.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Settings button not on home view.\n\(app.debugDescription)")
        settingsButton.tap()
        app.buttons["settings.eq"].tap()

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

        // One accessibility-size leg catches clipping in the two most important
        // listening surfaces without multiplying the single smoke test.
        app.terminate()
        app.launchArguments.append(contentsOf: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        app.launch()
        tab("Listen", in: app).tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 15))
        XCTAssertNoThrow(try auditAccessibility(app, "Listen accessibility XL"))
        auditBookPageIfPresent(app: app)
    }

    /// Runs Xcode's accessibility audit on the current screen. Only system
    /// chrome may be allowlisted; Voxglass views remain actionable failures.
    private func auditAccessibility(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion,
                                                 .sufficientElementDescription, .textClipped, .trait]) { issue in
            guard let identifier = issue.element?.identifier else { return false }
            return Self.auditAllowlist.contains(identifier)
        }
    }

    private static let auditAllowlist: Set<String> = []

    private func auditBookPageIfPresent(app: XCUIApplication) {
        tab("Listen", in: app).tap()
        let continueListening = app.descendants(matching: .any)["listen.continueListening"]
        guard continueListening.waitForExistence(timeout: 4) else { return }
        continueListening.tap()
        let player = app.buttons["bookpage.play"].exists
            ? app.buttons["bookpage.play"]
            : app.buttons["bookpage.togglePlayback"]
        guard player.waitForExistence(timeout: 10) else { return }
        XCTAssertNoThrow(try auditAccessibility(app, "Book page"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// User-reported: tapping Settings from the Listen tab crashes the app.
    /// Isolated from `assertStorageCardsFitCompactWidth` (which also opens
    /// Settings, but only as a step on the way to Storage & iCloud) so a
    /// Settings-only failure is unambiguous rather than buried under a
    /// storage-specific assertion.
    private func assertSettingsOpensFromHomeWithoutCrashing(app: XCUIApplication) {
        tab("Listen", in: app).tap()
        app.buttons["home.settingsButton"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 10),
            "Settings root missing.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Settings sheet must be titled Settings.")
        XCTAssertFalse(app.navigationBars["More"].exists, "Settings sheet must not be titled More.")
        XCTAssertFalse(app.buttons["Close"].exists, "Settings sheet must not inject a Close button.")
        XCTAssertFalse(app.buttons["settings.close"].exists)
        app.buttons["Sheet Grabber"].swipeDown()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForNonExistence(timeout: 5),
                      "Settings root should be gone after dismissal.")
        app.buttons["home.settingsButton"].tap()

        XCTAssertTrue(
            app.staticTexts["Languages"].waitForExistence(timeout: 10),
            "Settings did not render after tapping the Listen tab's settings button.\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "App terminated after tapping Settings from the Listen tab."
        )

        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
        } else {
            app.buttons["Sheet Grabber"].swipeDown()
        }
    }

    /// Browsing/previewing a catalog result must not silently add it to My
    /// Books any more — only the book page's own "+" does that. This checks
    /// the other half of that change: the "Listening History" entry point
    /// (Discover's history icon) renders and opens without crashing.
    private func assertHistoryOpensFromExploreWithoutCrashing(app: XCUIApplication) {
        tab("Find", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Featured Collections"].waitForExistence(timeout: 10),
            "Find did not render before opening History.\n\(app.debugDescription)"
        )

        let historyButton = app.buttons["Listening History"]
        XCTAssertTrue(
            historyButton.waitForExistence(timeout: 10),
            "Find is missing its Listening History button.\n\(app.debugDescription)"
        )
        historyButton.tap()

        XCTAssertTrue(
            app.navigationBars["History"].waitForExistence(timeout: 10),
            "History did not open from Discover.\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.state, .runningForeground,
            "App terminated after opening History from Explore."
        )

        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 2) {
            done.tap()
        }
    }

    /// Regression guard (this bug has recurred more than once): Great Books
    /// ships five language-specific variants (English/Spanish/German/
    /// Italian/Ancient Greek) that must only show up for a language the
    /// user has actually selected — the default onboarding selection is
    /// English only, so the German/Spanish titles must not appear.
    private func assertFeaturedCollectionsRespectSelectedLanguage(app: XCUIApplication) {
        tab("Find", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Featured Collections"].waitForExistence(timeout: 10),
            "Find did not render.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.buttons["discover.collection.great-books"].waitForExistence(timeout: 10),
            "The English Great Books collection should be visible by default.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.buttons["discover.collection.great-books-spa"].exists,
            "The Spanish Great Books collection must not show for an English-only selection.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.buttons["discover.collection.great-books-deu"].exists,
            "The German Great Books collection must not show for an English-only selection.\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.buttons["discover.collection.great-books-ita"].exists,
            "The Italian Great Books collection must not show for an English-only selection.\n\(app.debugDescription)"
        )
    }

    /// Opens the equalizer from Settings and toggles it, so a crash in the
    /// EQ engage/playback wiring (as opposed to just rendering the sheet)
    /// would surface here.
    private func assertEQTogglesFromSettingsWithoutCrashing(app: XCUIApplication) {
        tab("Listen", in: app).tap()
        app.buttons["home.settingsButton"].tap()
        XCTAssertTrue(
            app.staticTexts["Languages"].waitForExistence(timeout: 10),
            "Settings did not render before opening the equalizer.\n\(app.debugDescription)"
        )

        let eqRow = app.buttons["settings.eq"]
        XCTAssertTrue(eqRow.waitForExistence(timeout: 10), "Equalizer row should be visible in Settings")
        eqRow.tap()

        let engage = app.switches["eq.engage"]
        XCTAssertTrue(engage.waitForExistence(timeout: 10),
                      "Equalizer sheet did not render after tapping it from Settings.\n\(app.debugDescription)")
        let before = engage.value as? String
        engage.tap()
        XCTAssertTrue(
            app.state == .runningForeground,
            "App terminated after toggling the equalizer engage switch."
        )
        // iOS 27 delivers the accessibility value on the next run-loop turn;
        // reading it immediately after the synthesized tap races SwiftUI's
        // state update and produced a false negative in this smoke test.
        var after = engage.value as? String
        let deadline = Date().addingTimeInterval(3)
        while after == before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            after = engage.value as? String
        }
        XCTAssertNotEqual(before, after, "Toggling the equalizer switch should change its state")

        app.buttons["Done"].tap()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
        } else {
            app.buttons["Sheet Grabber"].swipeDown()
        }
    }

    private func assertStorageCardsFitCompactWidth(app: XCUIApplication) {
        tab("Listen", in: app).tap()
        app.buttons["home.settingsButton"].tap()

        let storageLink = app.buttons["settings.storage"]
        for _ in 0..<6 where !storageLink.isHittable {
            app.swipeUp()
            _ = storageLink.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(storageLink.isHittable, "Storage & iCloud is not reachable from Settings.\n\(app.debugDescription)")
        storageLink.tap()

        let screen = app.descendants(matching: .any)["storage.icloud"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "Storage & iCloud did not open.\n\(app.debugDescription)")

        let checks = [
            (card: "storage.workingCache", text: "storage.workingCache.total"),
            (card: "storage.audiobookCache", text: "storage.audiobookCache.description"),
            (card: "storage.iCloudBackup", text: "storage.iCloudBackup.description"),
            (card: "storage.evictionOrder", text: "storage.evictionOrder.never")
        ]

        for (index, check) in checks.enumerated() {
            let card = app.otherElements[check.card]
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Missing storage card \(check.card).\n\(app.debugDescription)")
            if index > 0 {
                let previousCard = app.otherElements[checks[index - 1].card]
                XCTAssertGreaterThan(card.frame.minY, previousCard.frame.maxY, "Storage card order changed at \(check.card).")
            }

            for _ in 0..<6 where !card.frame.intersects(app.frame) {
                app.swipeUp()
            }

            let longText = app.staticTexts[check.text]
            XCTAssertTrue(longText.exists, "Missing compact-width text probe \(check.text).\n\(app.debugDescription)")
            XCTAssertLessThanOrEqual(card.frame.width, screen.frame.width, "\(check.card) is wider than the compact screen.")
            XCTAssertTrue(
                card.frame.insetBy(dx: -1, dy: -1).contains(longText.frame),
                "\(check.text) clips outside \(check.card). Card: \(card.frame), text: \(longText.frame)."
            )
        }

        assertFinalContentClearsBottomControls(
            app.staticTexts["storage.evictionOrder.never"],
            app: app,
            screen: "Storage & iCloud"
        )

        app.navigationBars["Storage & iCloud"].buttons.element(boundBy: 0).tap()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
        } else {
            app.buttons["Sheet Grabber"].swipeDown()
        }
        let settingsGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: storageLink
        )
        wait(for: [settingsGone], timeout: 10)
    }

    /// Scrolls a screen's final accessibility probe fully above the visible
    /// bottom controls. When the root dock is present its complete frame
    /// includes both the mini-player and tab bar; modal screens use their own
    /// safe-area bottom instead.
    private func assertFinalContentClearsBottomControls(
        _ finalElement: XCUIElement,
        app: XCUIApplication,
        screen: String
    ) {
        XCTAssertTrue(
            finalElement.waitForExistence(timeout: 10),
            "\(screen) final content is missing.\n\(app.debugDescription)"
        )

        func obstructionTop() -> CGFloat {
            // A sheet can leave the root tab bar in the accessibility tree
            // while it is fully covered and non-hittable. It is not an
            // obstruction for modal content, so only use its frame when the
            // bar is actually visible to the user.
            let tabBar = app.tabBars.firstMatch
            let tabTop = tabBar.exists && tabBar.isHittable ? tabBar.frame.minY : app.frame.maxY
            let accessory = app.otherElements["chrome.miniPlayer"]
            let accessoryTop = accessory.exists && accessory.isHittable ? accessory.frame.minY : app.frame.maxY
            return min(tabTop, accessoryTop)
        }

        for _ in 0..<8 where finalElement.frame.maxY > obstructionTop() {
            app.swipeUp()
        }

        XCTAssertLessThanOrEqual(
            finalElement.frame.maxY,
            obstructionTop() + 1,
            "\(screen) final content intersects the tab bar, accessory, or bottom safe area. Final: \(finalElement.frame)."
        )
    }

    func testSwitchingTabDismissesNowPlaying() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-VoxglassInitialTab", "listen", "-uiTestDisableCloudKit"]
        app.launch()
        let mini = app.otherElements["chrome.miniPlayer"]
        guard mini.waitForExistence(timeout: 10) else {
            throw XCTSkip("No seeded playback session; mini-player unavailable.")
        }
        mini.tap()
        let nowPlaying = app.otherElements["nowplaying.cover"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 5))

        tab("My Books", in: app).tap()

        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: nowPlaying)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.otherElements["chrome.miniPlayer"].waitForExistence(timeout: 5))
    }

    private func tab(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[label]
    }
}
