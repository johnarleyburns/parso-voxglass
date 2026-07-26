import Testing
import Foundation
@testable import VoxglassCore

/// Pure rate policy + per-book memory (P0-1). No AVFoundation.
@Suite struct PlaybackRateTests {

    @Test func clampBounds() {
        #expect(PlaybackRate.clamp(0.1) == 0.5)
        #expect(PlaybackRate.clamp(9.0) == 3.5)
        #expect(PlaybackRate.clamp(1.5) == 1.5)
        #expect(PlaybackRate.clamp(0.5) == 0.5)
        #expect(PlaybackRate.clamp(3.5) == 3.5)
    }

    @Test func menuLadderIsWithinBounds() {
        for rate in PlaybackRate.menuLadder {
            #expect(PlaybackRate.clamp(rate) == rate)  // \(rate) must be a valid in-range rate
        }
        #expect(PlaybackRate.menuLadder.first == 0.5)
        #expect(PlaybackRate.menuLadder.last == 3.5)
    }

    @Test func systemLadderIsASubsetOfMenu() {
        let menu = Set(PlaybackRate.systemLadder.map { PlaybackRate.clamp($0) })
        for rate in PlaybackRate.systemLadder {
            #expect(menu.contains(rate))
        }
        #expect(PlaybackRate.systemLadder.contains(1.0))
        #expect(!(PlaybackRate.systemLadder.contains(3.5)))  // 3.5× stays in-app only
    }

    @Test func labelFormatting() {
        #expect(PlaybackRate.label(1.0) == "1×")
        #expect(PlaybackRate.label(2.0) == "2×")
        #expect(PlaybackRate.label(1.5) == "1.5×")
        #expect(PlaybackRate.label(0.75) == "0.75×")
    }

    // MARK: - PlaybackRateStore per-book isolation + default fallback

    private func makeStore() -> PlaybackRateStore {
        PlaybackRateStore(defaults: UserDefaults(suiteName: "rate-\(UUID().uuidString)")!)
    }

    @Test func defaultFallbackIsNormal() {
        #expect(makeStore().rate(forBookID: UUID()) == 1.0)
    }

    @Test func perBookIsolation() {
        let store = makeStore()
        let bookA = UUID()
        let bookB = UUID()
        store.setRate(1.5, forBookID: bookA)
        #expect(store.rate(forBookID: bookA) == 1.5)
        #expect(store.rate(forBookID: bookB) == 1.0)  // Book B keeps the default
    }

    @Test func storedRateIsClamped() {
        let store = makeStore()
        let book = UUID()
        store.setRate(99, forBookID: book)
        #expect(store.rate(forBookID: book) == 3.5)
    }
}
