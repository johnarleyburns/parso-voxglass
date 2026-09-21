import XCTest
@testable import Voxglass

@MainActor
final class MacCommandTests: XCTestCase {
    func testCommandRouterDeliversTypedEventsInOrder() {
        let router = MacCommandRouter()
        var received: [MacCommandAction] = []
        router.handler = { received.append($0) }

        router.send(.destination(.books))
        router.send(.record)

        XCTAssertEqual(received, [.destination(.books), .record])
        XCTAssertEqual(router.latestEvent?.id, 2)
        XCTAssertEqual(router.latestEvent?.action, .record)
    }

    func testDestinationsExposeTheFourNativeMacProductSurfaces() {
        XCTAssertEqual(MacDestination.allCases.map(\.title), ["Listen", "My Books", "Discover", "Narration"])
    }
}
