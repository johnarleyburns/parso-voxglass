import Testing
import Foundation
@testable import VoxglassCore

/// Tests the "which items have a tap" bookkeeping (Step 0b) with plain objects —
/// no AVFoundation. Proves the current + preloaded items can both hold taps
/// (the gapless-advance fix) and that item-changed evicts the old one.
@Suite struct EQTapRegistryTests {

    @Test func attachCurrentAndPreloadedYieldsTwoLiveEntries() {
        let registry = EQTapRegistry()
        let current = NSObject()
        let preloaded = NSObject()

        #expect(registry.attach(current))
        #expect(registry.attach(preloaded))

        #expect(registry.count == 2)
        #expect(registry.isAttached(current))
        #expect(registry.isAttached(preloaded))
    }

    @Test func itemChangedEvictsTheOldOne() {
        let registry = EQTapRegistry()
        let previous = NSObject()
        let next = NSObject()
        registry.attach(previous)
        registry.attach(next)

        // Gapless auto-advance: the previous chapter's item leaves the queue.
        #expect(registry.evict(previous))

        #expect(registry.count == 1)
        #expect(!(registry.isAttached(previous)))
        #expect(registry.isAttached(next))  // The now-playing item keeps its tap
    }

    @Test func attachIsIdempotent() {
        let registry = EQTapRegistry()
        let item = NSObject()
        #expect(registry.attach(item))
        #expect(!(registry.attach(item)))  // Re-attaching an already-tapped item is a no-op
        #expect(registry.count == 1)
    }

    @Test func evictAllClears() {
        let registry = EQTapRegistry()
        registry.attach(NSObject())
        registry.attach(NSObject())
        registry.evictAll()
        #expect(registry.isEmpty)
        #expect(registry.count == 0)
    }

    @Test func evictNonMemberReturnsFalse() {
        let registry = EQTapRegistry()
        #expect(!(registry.evict(NSObject())))
    }
}
