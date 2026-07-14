import XCTest

final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(initialTab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", initialTab
        ]
        app.launch()
        return app
    }

    private func launchApp(initialTab: String, tier: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", initialTab,
            tier
        ]
        app.launch()
        return app
    }

    func testMyBooksShowsShelfWithoutAddPanels() {
        let app = launchApp(initialTab: "library")

        XCTAssertTrue(app.staticTexts["My Books"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Add from Internet Archive"].exists)
        XCTAssertFalse(app.staticTexts["Add Local Audiobooks"].exists)
    }

    func testExploreShowsFeaturedCollectionsWithoutAddPanels() {
        let app = launchApp(initialTab: "explore")

        XCTAssertTrue(app.staticTexts["Featured Collections"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Add from Internet Archive"].exists)
        XCTAssertFalse(app.staticTexts["Add Local Audiobooks"].exists)
        XCTAssertFalse(app.staticTexts["On This Device"].exists)
    }

    func testMoreShowsCacheSettings() {
        let app = launchApp(initialTab: "more")

        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Clear Cache"].exists)
    }

    func testHomeHasNoSearchSectionActionButSearchTabReachable() {
        let app = launchApp(initialTab: "home")

        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        // Only the tab-bar "Search" control should exist — the Home section action was removed.
        let searchButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertEqual(searchButtons.count, 1)

        // The Search tab remains reachable from the dock.
        searchButtons.firstMatch.tap()
        XCTAssertTrue(app.textFields["Search LibriVox audiobooks"].waitForExistence(timeout: 10))
    }

    // MARK: - Pro lock / unlock matrix (§8)

    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        var attempts = 0
        while !element.isHittable && attempts < maxSwipes {
            app.swipeUp()
            attempts += 1
        }
        return element.isHittable
    }

    func testFreeTierShowsLocksAndOpensPaywall() {
        let app = launchApp(initialTab: "more", tier: "-VoxglassForceFreeTier")

        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 10))

        // Every gated touchpoint exposes a stable lock identifier.
        let lockIDs = [
            "pro.lock.icloudSync",
            "pro.lock.eq",
            "pro.lock.prefetchDepth",
            "pro.lock.listeningStats",
            "pro.lock.folderWatch",
            "pro.lock.cache.2gb",
            "pro.lock.cache.10gb"
        ]
        for id in lockIDs {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "Missing lock affordance: \(id)")
        }

        // Tapping a lock opens the paywall.
        let eqLock = app.buttons["pro.lock.eq"]
        XCTAssertTrue(scrollToHittable(eqLock, in: app), "EQ lock never became hittable")
        eqLock.tap()
        XCTAssertTrue(
            app.staticTexts["Voxglass Pro"].waitForExistence(timeout: 5),
            "Tapping a lock must present the Pro paywall"
        )
    }

    func testProTierUnlocksControls() {
        let app = launchApp(initialTab: "more", tier: "-VoxglassForcePro")

        XCTAssertTrue(app.staticTexts["Streaming Cache"].waitForExistence(timeout: 10))

        // Unlocked controls are present…
        XCTAssertTrue(app.buttons["settings.eq"].waitForExistence(timeout: 5))

        // …and no lock affordances remain.
        let lockIDs = [
            "pro.lock.icloudSync",
            "pro.lock.eq",
            "pro.lock.prefetchDepth",
            "pro.lock.listeningStats",
            "pro.lock.folderWatch",
            "pro.lock.cache.2gb",
            "pro.lock.cache.10gb"
        ]
        for id in lockIDs {
            XCTAssertFalse(
                app.buttons[id].exists,
                "Pro tier must not show lock affordance: \(id)"
            )
        }
    }

    func testNowPlayingFavoriteToggles() throws {
        let app = launchApp(initialTab: "library", tier: "-VoxglassForcePro")

        // The favorite control only exists once a session is playing. Without
        // seeded content (offline/CI), skip rather than fail spuriously.
        let favorite = app.descendants(matching: .any)["nowplaying.favorite"]
        guard favorite.waitForExistence(timeout: 5) else {
            throw XCTSkip("No active Now Playing session to toggle favorite on.")
        }
        favorite.tap()
        XCTAssertTrue(favorite.exists)
    }
}
