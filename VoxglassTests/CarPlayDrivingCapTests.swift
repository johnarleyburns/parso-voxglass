import Testing
@testable import VoxglassCore

@Suite struct CarPlayDrivingCapTests {

    private func makeItems(_ count: Int) -> [CarPlayItem] {
        (0..<count).map { i in
            CarPlayItem(id: "\(i)", title: "Item \(i)", action: .none)
        }
    }

    @Test func applyCapTruncatesToTwelve() {
        let items = makeItems(20)
        let capped = CarPlayMenuBuilder.applyCap(items)
        #expect(capped.count == 12)
    }

    @Test func applyCapKeepsHeadOrdering() {
        let items = makeItems(20)
        let capped = CarPlayMenuBuilder.applyCap(items)
        #expect(capped.first?.title == "Item 0")
        #expect(capped.last?.title == "Item 11")
    }

    @Test func applyCapNoOpUnderLimit() {
        let items = makeItems(3)
        let capped = CarPlayMenuBuilder.applyCap(items, limit: 12)
        #expect(capped.count == 3)
    }

    @Test func applyCapCustomLimit() {
        let items = makeItems(10)
        let capped = CarPlayMenuBuilder.applyCap(items, limit: 5)
        #expect(capped.count == 5)
    }
}
