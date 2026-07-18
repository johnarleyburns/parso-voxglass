import StoreKitTest
import XCTest

/// Simulator-only UI test using StoreKitTest to verify the end-to-end Pro
/// purchase flow: buy → success state → auto-dismiss → re-rendered UI.
/// Does NOT pass -VoxglassForcePro or -VoxglassForceFreeTier.
final class VoxglassProPurchaseUITests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        session = try! SKTestSession(configurationFileNamed: "Pro")
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    func testProPurchaseUnlocksFeaturesLive() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-VoxglassInitialTab", "more",
            "-VoxglassDisableAnimatedSplash"
        ]
        app.launch()

        // Navigate to Pro paywall from More tab.
        let proCell = app.staticTexts["Voxglass Pro"]
        XCTAssertTrue(proCell.waitForExistence(timeout: 10), "Pro upsell cell not found on More tab")
        proCell.tap()

        // Tap the unlock button.
        let unlockButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock Pro'")).firstMatch
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10), "Unlock Pro button not found")
        unlockButton.tap()

        // Wait for success state to appear.
        let success = app.otherElements["paywall.success"]
        XCTAssertTrue(success.waitForExistence(timeout: 15), "paywall.success not shown after purchase")

        // Sheet should auto-dismiss, so wait for Settings to reappear.
        XCTAssertTrue(app.staticTexts["Voxglass Pro"].waitForExistence(timeout: 5), "Paywall did not dismiss")

        // Pro row should now read "Pro Unlocked".
        XCTAssertTrue(app.staticTexts["Pro Unlocked"].waitForExistence(timeout: 5), "Pro row did not show Pro Unlocked")

        // Lock badge should be gone — the EQ row should show as accessible.
        XCTAssertTrue(app.otherElements["settings.eq"].waitForExistence(timeout: 5), "EQ row did not unlock")
    }
}
