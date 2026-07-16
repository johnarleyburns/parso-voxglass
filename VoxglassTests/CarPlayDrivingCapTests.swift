import XCTest
@testable import VoxglassCore

final class CarPlayDrivingCapTests: XCTestCase {

    private func makeItems(_ count: Int) -> [CarPlayItem] {
        (0..<count).map { i in
            CarPlayItem(id: "\(i)", title: "Item \(i)", action: .none)
        }
    }

    func testApplyCapTruncatesToTwelve() {
        let items = makeItems(20)
        let capped = CarPlayMenuBuilder.applyCap(items)
        XCTAssertEqual(capped.count, 12)
    }

    func testApplyCapKeepsHeadOrdering() {
        let items = makeItems(20)
        let capped = CarPlayMenuBuilder.applyCap(items)
        XCTAssertEqual(capped.first?.title, "Item 0")
        XCTAssertEqual(capped.last?.title, "Item 11")
    }

    func testApplyCapNoOpUnderLimit() {
        let items = makeItems(3)
        let capped = CarPlayMenuBuilder.applyCap(items, limit: 12)
        XCTAssertEqual(capped.count, 3)
    }

    func testApplyCapCustomLimit() {
        let items = makeItems(10)
        let capped = CarPlayMenuBuilder.applyCap(items, limit: 5)
        XCTAssertEqual(capped.count, 5)
    }
}
