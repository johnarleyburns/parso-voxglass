import XCTest

/// The single macOS Studio smoke test (repo convention: one UI smoke test per
/// device). Drives the New Project wizard for all three destinations — the
/// destination is the only thing that changes between them; everything else
/// runs under `swift test`. Runs locally (`scripts/test.sh --all`), never on
/// GitHub Actions.
final class StudioSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_createAllDestinationAudiobooks() throws {
        try createAndImport(destination: "librivox")
        try createAndImport(destination: "internetArchive")
        try createAndImport(destination: "acx")
    }

    private func createAndImport(destination: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestSeed", "empty", "-useTemporaryStore"]
        app.launch()
        app.buttons["library.newAudiobook"].click()
        app.textFields["wizard.title"].click(); app.typeText("Smoke Book")
        app.textFields["wizard.author"].click(); app.typeText("Tester")
        app.textFields["wizard.narrator"].click(); app.typeText("Tester")
        app.popUpButtons["wizard.destination"].click()
        app.staticTexts[destination].click()
        app.buttons["wizard.continueToImport"].click()
        XCTAssertTrue(app.staticTexts["import.chapterCount"].waitForExistence(timeout: 5))
        app.buttons["import.acceptStructure"].click()
        XCTAssertTrue(app.buttons["dashboard.recordNext"].waitForExistence(timeout: 5))
    }
}
