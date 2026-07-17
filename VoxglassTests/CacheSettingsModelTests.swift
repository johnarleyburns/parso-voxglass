import XCTest
@testable import VoxglassCore

final class CacheSettingsModelTests: XCTestCase {
    override func tearDown() async throws {
        EntitlementCache.shared.cacheEntitlement(false)
        await CacheManager.shared.setPreset(.free500MB)
        await StreamCacheStore.shared.clearAll()
        try await super.tearDown()
    }

    func testProPresetBlockedWhenNotEntitled() async {
        EntitlementCache.shared.cacheEntitlement(false)
        await CacheManager.shared.setPreset(.free500MB)

        await CacheManager.shared.setPreset(.pro2GB)

        let budget = await CacheManager.shared.currentBudget
        XCTAssertEqual(budget, CacheManager.CachePreset.free500MB.rawValue)
    }

    func testPersistedProPresetClampsToFreeWhenEntitlementLost() async {
        EntitlementCache.shared.cacheEntitlement(true)
        await CacheManager.shared.setPreset(.pro10GB)

        EntitlementCache.shared.cacheEntitlement(false)

        let preset = await CacheManager.shared.selectedPreset
        let budget = await CacheManager.shared.currentBudget
        XCTAssertEqual(preset, .free500MB, "a persisted Pro preset must clamp at the model layer for free users")
        XCTAssertEqual(budget, CacheManager.CachePreset.free500MB.rawValue)
    }

    func testProPresetAllowedWhenEntitledUpdatesBudgetAndStoreLimit() async {
        EntitlementCache.shared.cacheEntitlement(true)

        await CacheManager.shared.setPreset(.pro2GB)

        let budget = await CacheManager.shared.currentBudget
        let limit = await StreamCacheStore.shared.currentLimit()
        XCTAssertEqual(budget, CacheManager.CachePreset.pro2GB.rawValue)
        XCTAssertEqual(limit, CacheManager.CachePreset.pro2GB.rawValue)
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
