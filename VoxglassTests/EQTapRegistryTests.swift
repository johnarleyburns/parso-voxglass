import XCTest
@testable import VoxglassCore

/// Tests the "which items have a tap" bookkeeping (Step 0b) with plain objects —
/// no AVFoundation. Proves the current + preloaded items can both hold taps
/// (the gapless-advance fix) and that item-changed evicts the old one.
final class EQTapRegistryTests: XCTestCase {

    func testAttachCurrentAndPreloadedYieldsTwoLiveEntries() {
        let registry = EQTapRegistry()
        let current = NSObject()
        let preloaded = NSObject()

        XCTAssertTrue(registry.attach(current))
        XCTAssertTrue(registry.attach(preloaded))

        XCTAssertEqual(registry.count, 2)
        XCTAssertTrue(registry.isAttached(current))
        XCTAssertTrue(registry.isAttached(preloaded))
    }

    func testItemChangedEvictsTheOldOne() {
        let registry = EQTapRegistry()
        let previous = NSObject()
        let next = NSObject()
        registry.attach(previous)
        registry.attach(next)

        // Gapless auto-advance: the previous chapter's item leaves the queue.
        XCTAssertTrue(registry.evict(previous))

        XCTAssertEqual(registry.count, 1)
        XCTAssertFalse(registry.isAttached(previous))
        XCTAssertTrue(registry.isAttached(next), "The now-playing item keeps its tap")
    }

    func testAttachIsIdempotent() {
        let registry = EQTapRegistry()
        let item = NSObject()
        XCTAssertTrue(registry.attach(item))
        XCTAssertFalse(registry.attach(item), "Re-attaching an already-tapped item is a no-op")
        XCTAssertEqual(registry.count, 1)
    }

    func testEvictAllClears() {
        let registry = EQTapRegistry()
        registry.attach(NSObject())
        registry.attach(NSObject())
        registry.evictAll()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertEqual(registry.count, 0)
    }

    func testEvictNonMemberReturnsFalse() {
        let registry = EQTapRegistry()
        XCTAssertFalse(registry.evict(NSObject()))
    }
}
