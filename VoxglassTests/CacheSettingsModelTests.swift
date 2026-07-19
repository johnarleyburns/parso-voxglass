import XCTest
@testable import VoxglassCore

final class CacheSettingsModelTests: XCTestCase {
    override func tearDown() async throws {
        await CacheManager.shared.setPreset(.m500MB)
        await StreamCacheStore.shared.clearAll()
        try await super.tearDown()
    }

    func testClearCacheEmptiesTheStore() async {
        await StreamCacheStore.shared.registerArtwork(key: "art_test_clear", bytes: 1024)
        let before = await CacheManager.shared.currentCacheBytes()
        XCTAssertGreaterThanOrEqual(before, 1024)

        await CacheManager.shared.clearCache()

        let after = await CacheManager.shared.currentCacheBytes()
        XCTAssertEqual(after, 0)
    }
}
