import Testing
import ParsoAudioStreaming
@testable import VoxglassCore

@Suite(.serialized) struct CacheSettingsModelTests {

    @Test func clearCacheEmptiesTheStore() async {
        await AudioCache.shared.registerComplete(key: "art_test_clear", bytes: 1024, kind: "artwork")
        let before = await AudioCache.shared.totalCachedBytes()
        #expect(before >= 1024)

        await AudioCache.clearCache()

        let after = await AudioCache.shared.totalCachedBytes()
        #expect(after == 0)
    }
}
