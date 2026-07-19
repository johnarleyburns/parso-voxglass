import XCTest
@testable import VoxglassCore

@MainActor
final class PrefetchDepthTests: XCTestCase {

    func testOnWiFiHonorsStoredDepth() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: false, wifiOnly: true), 3)
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: 999, isCellular: false, wifiOnly: true), 999)
    }

    func testOnCellularWithWiFiOnlyClampsToOne() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: true, wifiOnly: true), 1)
    }

    func testOnCellularWithoutWiFiOnlyHonorsStoredDepth() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: true, wifiOnly: false), 3)
    }

    func testStoredDepthNeverGoesBelowOne() {
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: 0, isCellular: false, wifiOnly: true), 1)
        XCTAssertEqual(
            PlaybackCoordinator.resolvedPrefetchDepth(stored: -5, isCellular: false, wifiOnly: false), 1)
    }
}
