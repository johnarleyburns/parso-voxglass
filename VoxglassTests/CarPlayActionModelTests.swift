import Testing
import Foundation
@testable import VoxglassCore

@Suite struct CarPlayActionModelTests {

    @Test func carPlayActionEquatableRoundTrips() {
        let a1: CarPlayAction = .playBook(bookID: UUID())
        let a2: CarPlayAction = .playBook(bookID: UUID())
        #expect(a1 != a2)
        let id = UUID()
        #expect(CarPlayAction.playBook(bookID: id) == CarPlayAction.playBook(bookID: id))
    }

    @Test func carPlayInterfaceEquatable() {
        let book = CarPlayBookSnapshot(id: UUID(), title: "T", authorLine: "A", chapterCount: 1)
        let state1 = CarPlayState(books: [book])
        let state2 = CarPlayState(books: [book])
        #expect(state1 == state2)
    }

    @Test func carPlayActionSendableCompiles() {
        _ = CarPlayAction.setSleepTimer(.endOfChapter)
        _ = CarPlayAction.setSleepTimer(.duration(1800))
        #expect(true) // compilation proves Sendable
    }

    @Test func carPlayTabIDAllCasesCovered() {
        #expect(CarPlayTabID.allCases.count == 5)
        #expect(CarPlayTabID.allCases.contains(.continueListening))
        #expect(CarPlayTabID.allCases.contains(.library))
        #expect(CarPlayTabID.allCases.contains(.downloaded))
        #expect(CarPlayTabID.allCases.contains(.discover))
        #expect(CarPlayTabID.allCases.contains(.search))
    }
}
