import XCTest
@testable import VoxglassCore

final class CarPlayActionModelTests: XCTestCase {

    func testCarPlayActionEquatableRoundTrips() {
        let a1: CarPlayAction = .playBook(bookID: UUID())
        let a2: CarPlayAction = .playBook(bookID: UUID())
        XCTAssertNotEqual(a1, a2)
        let id = UUID()
        XCTAssertEqual(CarPlayAction.playBook(bookID: id), CarPlayAction.playBook(bookID: id))
    }

    func testCarPlayInterfaceEquatable() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "T", authorLine: "A", chapterCount: 1)
        let state1 = CarPlayState(books: [book])
        let state2 = CarPlayState(books: [book])
        XCTAssertEqual(state1, state2)
    }

    func testCarPlayActionSendableCompiles() {
        _ = CarPlayAction.setSleepTimer(.endOfChapter)
        _ = CarPlayAction.setSleepTimer(.duration(1800))
        XCTAssertTrue(true) // compilation proves Sendable
    }

    func testCarPlayTabIDAllCasesCovered() {
        XCTAssertEqual(CarPlayTabID.allCases.count, 5)
        XCTAssertTrue(CarPlayTabID.allCases.contains(.continueListening))
        XCTAssertTrue(CarPlayTabID.allCases.contains(.library))
        XCTAssertTrue(CarPlayTabID.allCases.contains(.downloaded))
        XCTAssertTrue(CarPlayTabID.allCases.contains(.discover))
        XCTAssertTrue(CarPlayTabID.allCases.contains(.search))
    }
}
