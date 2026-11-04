import Foundation
import Testing
@testable import VoxglassCore

@MainActor
@Suite struct AuxiliaryNowPlayingTests {
    @Test func auxiliaryMetadataIsRecordedForNativeNowPlaying() {
        let bridge = NoopPlaybackBridge()
        bridge.updateAuxiliaryNowPlaying(title: "P1", artist: "Project")
        #expect(bridge.auxiliaryNowPlaying == AuxiliaryNowPlaying(title: "P1", artist: "Project"))
    }

    @Test func clearDropsAuxiliaryMetadata() {
        let bridge = NoopPlaybackBridge()
        bridge.updateAuxiliaryNowPlaying(title: "P1", artist: "Project")
        bridge.clearAuxiliaryNowPlaying()
        #expect(bridge.auxiliaryNowPlaying == nil)
    }

}
