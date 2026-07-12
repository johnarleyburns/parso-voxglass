import XCTest
@testable import Voxglass

@MainActor
final class PrefetchDepthTests: XCTestCase {

    func testNotProAlwaysResolvesToOne() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: false, stored: 3, isCellular: false, wifiOnly: true), 1)
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: false, stored: 999, isCellular: true, wifiOnly: false), 1)
    }

    func testProOnWiFiHonorsStoredDepth() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: 3, isCellular: false, wifiOnly: true), 3)
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: 999, isCellular: false, wifiOnly: true), 999)
    }

    func testProOnCellularWithWiFiOnlyClampsToOne() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: 3, isCellular: true, wifiOnly: true), 1)
    }

    func testProOnCellularWithoutWiFiOnlyHonorsStoredDepth() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: 3, isCellular: true, wifiOnly: false), 3)
    }

    func testStoredDepthNeverGoesBelowOne() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: 0, isCellular: false, wifiOnly: true), 1)
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(isPro: true, stored: -5, isCellular: false, wifiOnly: false), 1)
    }
}
