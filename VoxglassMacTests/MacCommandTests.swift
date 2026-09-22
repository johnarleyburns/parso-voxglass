import XCTest
@testable import Voxglass

@MainActor
final class MacCommandTests: XCTestCase {
    func testCommandRouterDeliversTypedEventsInOrder() {
        let router = MacCommandRouter()
        var received: [MacCommandAction] = []
        router.handler = { received.append($0) }

        router.send(.destination(.books))
        router.setDestination(.narration)
        router.setWorkspaceSelection(hasParagraph: true, hasTake: false)
        router.send(.record)

        XCTAssertEqual(received, [.destination(.books), .record])
        XCTAssertEqual(router.latestEvent?.id, 2)
        XCTAssertEqual(router.latestEvent?.action, .record)
    }

    func testNarrationCommandsAreGatedByFocusedEditorAndTakeState() {
        let router = MacCommandRouter()
        var received: [MacCommandAction] = []
        router.handler = { received.append($0) }

        router.setDestination(.narration)
        router.setWorkspaceSelection(hasParagraph: true, hasTake: false)
        router.send(.acceptAndNext)
        XCTAssertTrue(received.isEmpty)

        router.setWorkspaceSelection(hasParagraph: true, hasTake: true)
        router.setTextEditorFocused(true)
        router.send(.acceptAndNext)
        XCTAssertTrue(received.isEmpty)

        router.setTextEditorFocused(false)
        router.send(.acceptAndNext)
        XCTAssertEqual(received, [.acceptAndNext])
    }

    func testPlaybackCommandsRequireAnActiveSession() {
        let router = MacCommandRouter()
        var received: [MacCommandAction] = []
        router.handler = { received.append($0) }

        router.send(.showNowPlaying)
        XCTAssertTrue(received.isEmpty)

        router.setHasPlaybackSession(true)
        router.send(.showNowPlaying)
        router.send(.stopPlayback)
        XCTAssertEqual(received, [.showNowPlaying, .stopPlayback])
    }

    func testDestinationsExposeTheFourNativeMacProductSurfaces() {
        XCTAssertEqual(MacDestination.allCases.map(\.title), ["Listen", "My Books", "Discover", "Narration"])
    }
}
