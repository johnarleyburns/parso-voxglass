import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct NeedsCacheTests {

    @Test func fileCacheRoundTripsSnapshot() async throws {
        let url = tempURL()
        let cache = FileNeedsCache(url: url, clock: FixedClock())
        let snapshot = NeedsSnapshot(needs: [makeNeed(title: "Cache Me", author: "Poet")], freshness: .liveEnriched)
        await cache.save(snapshot)

        let reloaded = FileNeedsCache(url: url, clock: FixedClock())
        let loaded = await reloaded.load()
        #expect(loaded != nil)
        #expect(loaded!.needs.count == 1)
        #expect(loaded!.needs.first!.work.title == "Cache Me")
        #expect(loaded!.freshness == .liveEnriched)
    }

    @Test func missingFileLoadsNil() async {
        let cache = FileNeedsCache(url: tempURL(), clock: FixedClock())
        let loaded = await cache.load()
        #expect(loaded == nil)
    }

    @Test func perSourceBreakerStatePersistsAcrossInstances() async throws {
        let url = tempURL()
        let cache = FileNeedsCache(url: url, clock: FixedClock())
        await cache.save(NeedsSnapshot(needs: [makeNeed(title: "X", author: "Y")]))
        await cache.setState(NeedsSourceCacheState(consecutiveFailures: 3, openUntil: FixedClock().now.addingTimeInterval(100)), for: .snapshot)

        let reloaded = FileNeedsCache(url: url, clock: FixedClock())
        let state = await reloaded.state(for: .snapshot)
        #expect(state.consecutiveFailures == 3)
        #expect(state.openUntil != nil)
    }

    @Test func lastGoodSurvivesBadWrite() async {
        let url = tempURL()
        let cache = FileNeedsCache(url: url, clock: FixedClock())
        await cache.save(NeedsSnapshot(needs: [makeNeed(title: "Good", author: "A")]))
        // A fresh instance over a corrupt file on disk → treated as a miss; the
        // seed floor carries the feature (freshness, not correctness, degrades).
        try? Data("not json".utf8).write(to: url)
        let reloaded = FileNeedsCache(url: url, clock: FixedClock())
        let loaded = await reloaded.load()
        #expect(loaded == nil)
    }

    @Test func inMemoryCacheRoundTrips() async {
        let cache = InMemoryNeedsCache()
        #expect(await cache.load() == nil)
        await cache.save(NeedsSnapshot(needs: [makeNeed(title: "M", author: "N")], freshness: .cached))
        let loaded = await cache.load()
        #expect(loaded?.needs.first?.work.title == "M")
        #expect(loaded?.freshness == .cached)
        let state = await cache.state(for: .gutendex)
        #expect(state.consecutiveFailures == 0)
    }

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("needs-cache-\(UUID().uuidString).json")
    }
}
