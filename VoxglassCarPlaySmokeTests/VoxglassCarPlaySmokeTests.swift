import CarPlay
import XCTest
@testable import Voxglass
@testable import VoxglassCore

/// Part of the iPhone smoke test (docs/voxglass-mvp/VOXGLASS_STUDIO_SPEC.md
/// §19.5). CarPlay cannot be driven by XCUITest, so this hosted scene test
/// runs in the same iOS-simulator test action as `VoxglassUITests`
/// (`xcodebuild test -scheme Voxglass`). It is not a separate UI smoke test
/// and never runs on GitHub Actions.
final class VoxglassCarPlaySmokeTests: XCTestCase {
    @MainActor
    func testRendererBuildsFiveTabsAndResumeRowFromModel() throws {
        let state = CarPlayState.fixtureWithOneInProgressBook()
        let interface = CarPlayMenuBuilder.root(state)

        let tabBar = CarPlayTemplateRenderer.render(interface,
                                                    dispatcher: .noop,
                                                    artwork: .noop)

        XCTAssertEqual(tabBar.templates.count, 5)
        let continueList = try XCTUnwrap(tabBar.templates.first as? CPListTemplate)
        XCTAssertEqual(continueList.tabTitle, "Continue")
        let firstItem = try XCTUnwrap(continueList.sections.first?.items.first as? CPListItem)
        XCTAssertEqual(firstItem.text, state.recentlyPlayed.first?.title)
        XCTAssertNotNil(firstItem.handler)
    }
}
