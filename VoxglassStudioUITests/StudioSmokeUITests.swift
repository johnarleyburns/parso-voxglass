import XCTest

/// The macOS Studio smoke tests — three, one per audiobook destination.
/// These are the only macOS UI tests in the repository; everything else runs
/// under `swift test`. They run locally (`scripts/test.sh --all`), never on
/// GitHub Actions.
final class StudioSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
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

    func test_createLibrivoxAudiobook() throws {
        try createAndImport(destination: "librivox")
    }

    func test_createInternetArchiveAudiobook() throws {
        try createAndImport(destination: "internetArchive")
    }

    func test_createCommercialAudiobook() throws {
        try createAndImport(destination: "acx")
    }
}
