import XCTest
@testable import Voxglass

/// Pure rate policy + per-book memory (P0-1). No AVFoundation.
final class PlaybackRateTests: XCTestCase {

    func testClampBounds() {
        XCTAssertEqual(PlaybackRate.clamp(0.1), 0.5)
        XCTAssertEqual(PlaybackRate.clamp(9.0), 3.5)
        XCTAssertEqual(PlaybackRate.clamp(1.5), 1.5)
        XCTAssertEqual(PlaybackRate.clamp(0.5), 0.5)
        XCTAssertEqual(PlaybackRate.clamp(3.5), 3.5)
    }

    func testMenuLadderIsWithinBounds() {
        for rate in PlaybackRate.menuLadder {
            XCTAssertEqual(PlaybackRate.clamp(rate), rate, "\(rate) must be a valid in-range rate")
        }
        XCTAssertEqual(PlaybackRate.menuLadder.first, 0.5)
        XCTAssertEqual(PlaybackRate.menuLadder.last, 3.5)
    }

    func testSystemLadderIsASubsetOfMenu() {
        let menu = Set(PlaybackRate.systemLadder.map { PlaybackRate.clamp($0) })
        for rate in PlaybackRate.systemLadder {
            XCTAssertTrue(menu.contains(rate))
        }
        XCTAssertTrue(PlaybackRate.systemLadder.contains(1.0))
        XCTAssertFalse(PlaybackRate.systemLadder.contains(3.5), "3.5× stays in-app only")
    }

    func testLabelFormatting() {
        XCTAssertEqual(PlaybackRate.label(1.0), "1×")
        XCTAssertEqual(PlaybackRate.label(2.0), "2×")
        XCTAssertEqual(PlaybackRate.label(1.5), "1.5×")
        XCTAssertEqual(PlaybackRate.label(0.75), "0.75×")
    }

    // MARK: - PlaybackRateStore per-book isolation + default fallback

    private func makeStore() -> PlaybackRateStore {
        PlaybackRateStore(defaults: UserDefaults(suiteName: "rate-\(UUID().uuidString)")!)
    }

    func testDefaultFallbackIsNormal() {
        XCTAssertEqual(makeStore().rate(forBookID: UUID()), 1.0)
    }

    func testPerBookIsolation() {
        let store = makeStore()
        let bookA = UUID()
        let bookB = UUID()
        store.setRate(1.5, forBookID: bookA)
        XCTAssertEqual(store.rate(forBookID: bookA), 1.5)
        XCTAssertEqual(store.rate(forBookID: bookB), 1.0, "Book B keeps the default")
    }

    func testStoredRateIsClamped() {
        let store = makeStore()
        let book = UUID()
        store.setRate(99, forBookID: book)
        XCTAssertEqual(store.rate(forBookID: book), 3.5)
    }
}
