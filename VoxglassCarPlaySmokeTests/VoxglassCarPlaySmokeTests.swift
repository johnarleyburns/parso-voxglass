import CarPlay
import XCTest
@testable import Voxglass
@testable import VoxglassCore

/// The single CarPlay UI smoke test (docs/CARPLAY_DESIGN.md §8). CarPlay cannot
/// be driven by XCUITest, so this instantiates the real `CP*` templates from a
/// representative pure model and asserts the renderer's wiring. Simulator/local
/// gate only — never runs on Linux CI (`ci-no-simulator`).
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
