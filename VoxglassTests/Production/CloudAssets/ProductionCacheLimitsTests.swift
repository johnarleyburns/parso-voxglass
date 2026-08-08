import Foundation
import Testing
import VoxglassCore

/// D-5 (§19): the first-run working-cache default is clamped to about 15% of
/// free space so a small device never adopts a cache it cannot afford, while
/// staying within the 2–100 GB valid range and never exceeding the 10 GB
/// default.
@Suite struct ProductionCacheLimitsTests {

    private let gb: Int64 = 1_024 * 1024 * 1024

    @Test func largeFreeSpaceKeepsTheTenGBDefault() {
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 512 * gb) == ProductionCacheLimits.defaultWorkingCacheBytes)
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 120 * gb) == ProductionCacheLimits.defaultWorkingCacheBytes)
    }

    @Test func fifteenPercentOfFreeSpaceWhenBelowDefault() {
        // 40 GB free → 6 GB (15%).
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 40 * gb) == 6 * gb)
        // 100 GB free → 15 GB, still clamped to the 10 GB default.
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 100 * gb) == ProductionCacheLimits.defaultWorkingCacheBytes)
    }

    @Test func neverBelowTwoGBFloor() {
        // 4 GB free → 15% is 0.6 GB → floor of 2 GB.
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 4 * gb) == 2 * gb)
        // No free space reported → floor of 2 GB.
        #expect(ProductionCacheLimits.firstRunWorkingCache(freeBytes: 0) == 2 * gb)
    }

    @Test func resultIsAlwaysWithinValidRange() {
        for freeBytes in [0, 1, 4 * gb, 32 * gb, 128 * gb, 1_000 * gb] {
            let value = ProductionCacheLimits.firstRunWorkingCache(freeBytes: freeBytes)
            #expect(ProductionCacheLimits.isValidWorkingCacheSize(value))
            #expect(value <= ProductionCacheLimits.defaultWorkingCacheBytes)
        }
    }
}
