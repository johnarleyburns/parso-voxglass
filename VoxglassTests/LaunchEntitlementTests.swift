import XCTest
@testable import Voxglass

/// Verifies that pro entitlement is authoritative before any gate is read (A2).
/// On today's main, `StoreManager` is only ever instantiated by `ProPaywallView`'s
/// `@StateObject`, so cold launch never checks `Transaction.currentEntitlements`
/// and a paying customer who reinstalls sees the free tier until opening the paywall.
@MainActor
final class LaunchEntitlementTests: XCTestCase {

    override func tearDown() {
        EntitlementCache.shared.setTestEntitlement(nil)
        super.tearDown()
    }

    func testBootstrapRefreshesEntitlement() async {
        // Pre-set the cache to a non-default value so we can observe that
        // refreshEntitlement is called and updates the StoreManager's isPro.
        EntitlementCache.shared.setTestEntitlement(true)

        let services = AppServices()
        await services.bootstrap()

        XCTAssertTrue(StoreManager.shared.isPro,
            "After bootstrap, StoreManager must reflect the cached entitlement. On main without the fix, isPro stays false because nothing touches StoreManager at launch."
        )
    }

    func testBootstrapWithoutEntitlement() async {
        EntitlementCache.shared.setTestEntitlement(false)

        let services = AppServices()
        await services.bootstrap()

        XCTAssertFalse(StoreManager.shared.isPro,
            "Without entitlement, bootstrap must leave StoreManager.isPro as false."
        )
    }
}
