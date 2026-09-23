import XCTest

@MainActor
final class VoxglassMacUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "guru.parso.voxglass")
        app.launchArguments = ["-uiTestDisableCloudKit"]
        app.launch()
        return app
    }

    func testNativeMacShellExposesAllFourDestinations() {
        let app = launchApp()

        for destination in ["listen", "books", "discover", "narration"] {
            let item = app.descendants(matching: .any)["native-mac.sidebar.\(destination)"]
            XCTAssertTrue(item.waitForExistence(timeout: 10), "Missing native Mac destination: \(destination)")
        }
    }

    func testInspectorToolbarIsReachable() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["native-mac.toolbar.inspector"].waitForExistence(timeout: 10))
    }
}
