import Testing
@testable import VoxglassCore

@Suite(.serialized) struct CacheSettingsModelTests {

    @Test func clearCacheEmptiesTheStore() async {
        await StreamCacheStore.shared.registerArtwork(key: "art_test_clear", bytes: 1024)
        let before = await CacheManager.shared.currentCacheBytes()
        #expect(before >= 1024)

        await CacheManager.shared.clearCache()

        let after = await CacheManager.shared.currentCacheBytes()
        #expect(after == 0)
    }
}
