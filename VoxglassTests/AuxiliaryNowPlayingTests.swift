import Foundation
import Testing
@testable import VoxglassCore

@MainActor
@Suite struct AuxiliaryNowPlayingTests {
    @Test func inactiveLiveActivityMakesMetadataPublishable() {
        let bridge = NoopPlaybackBridge()
        bridge.liveActivityReconciliation = .inactive
        bridge.updateAuxiliaryNowPlaying(title: "P1", artist: "Project")
        #expect(bridge.lastAuxiliaryEffect == .publish(AuxiliaryNowPlaying(title: "P1", artist: "Project")))
    }

    @Test func activeLiveActivityClearsAndRetainsOnlyAsPending() {
        let bridge = NoopPlaybackBridge()
        bridge.liveActivityReconciliation = .active(activityID: "a")
        bridge.updateAuxiliaryNowPlaying(title: "P1", artist: "Project")
        #expect(bridge.lastAuxiliaryEffect == .clear)
        #expect(bridge.auxiliaryGate.latest == AuxiliaryNowPlaying(title: "P1", artist: "Project"))
    }

    @Test func clearDropsAuxiliaryMetadata() {
        let bridge = NoopPlaybackBridge()
        bridge.updateAuxiliaryNowPlaying(title: "P1", artist: "Project")
        bridge.clearAuxiliaryNowPlaying()
        #expect(bridge.auxiliaryGate.latest == nil)
        #expect(bridge.lastAuxiliaryEffect == .publish(nil))
    }

    @Test func carPlayReviewControllerHasNoDirectMediaPlayerWrite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Voxglass/App/CarPlay/CarPlayReviewController.swift"), encoding: .utf8)
        #expect(!source.contains("MPNowPlayingInfoCenter"))
        #expect(source.contains("playbackBridge.updateAuxiliaryNowPlaying("))
        #expect(source.contains("playbackBridge.clearAuxiliaryNowPlaying()"))
    }
}
