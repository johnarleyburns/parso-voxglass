import Testing
@testable import VoxglassCore

@MainActor
@Suite struct PrefetchDepthTests {

    @Test func onWiFiHonorsStoredDepth() {
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: false, wifiOnly: true) == 3)
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: 999, isCellular: false, wifiOnly: true) == 999)
    }

    @Test func onCellularWithWiFiOnlyClampsToOne() {
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: true, wifiOnly: true) == 1)
    }

    @Test func onCellularWithoutWiFiOnlyHonorsStoredDepth() {
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: 3, isCellular: true, wifiOnly: false) == 3)
    }

    @Test func storedDepthNeverGoesBelowOne() {
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: 0, isCellular: false, wifiOnly: true) == 1)
        #expect(PlaybackCoordinator.resolvedPrefetchDepth(stored: -5, isCellular: false, wifiOnly: false) == 1)
    }
}
