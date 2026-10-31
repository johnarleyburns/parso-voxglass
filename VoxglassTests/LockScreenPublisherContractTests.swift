import Foundation
import Testing

/// Source contract: exactly one iPhone publisher owns the lock screen.
///
/// The app target is not compiled by `swift test`, so these checks read the
/// production iPhone sources. Watch code is intentionally not inspected.
struct LockScreenPublisherContractTests {
    private static let bridge = "Voxglass/App/SystemPlaybackBridge.swift"
    private static let carPlayReview = "Voxglass/App/CarPlay/CarPlayReviewController.swift"
    private static let coordinator = "Voxglass/Core/Playback/PlaybackCoordinator.swift"
    private static let liveActivity = "Voxglass/App/LiveActivityController.swift"

    @Test func carPlayReviewControllerDoesNotTouchNowPlayingInfoCenter() throws {
        let text = try source(Self.carPlayReview)
        #expect(!text.contains("MPNowPlayingInfoCenter"))
    }

    @Test func coordinatorDoesNotSubmitNowPlayingDirectly() throws {
        let text = try source(Self.coordinator)
        #expect(!text.contains("bridge.updateNowPlaying("))
    }

    @Test func coordinatorDoesNotSubmitLiveActivityDirectly() throws {
        let text = try source(Self.coordinator)
        #expect(!text.contains("bridge.updateLiveActivity("))
    }

    @Test func bridgeReconcilesThroughUpdateLockScreenAndClearsMediaPlayerWhenActive() throws {
        let text = try source(Self.bridge)
        #expect(text.contains("func updateLockScreen("))
        #expect(text.contains("nowPlayingAction"))
        #expect(text.contains("case .clear: MPNowPlayingInfoCenter.default().nowPlayingInfo = nil"))
        #expect(try source(Self.liveActivity).contains("Activity.request"))
    }

    @Test func widgetBundleNoLongerRegistersCustomAudiobookLiveActivity() throws {
        let text = try source("VoxglassWidgets/VoxglassWidgets.swift")
        #expect(!text.contains("BookLiveActivity()"))
        #expect(text.contains("VoxglassContinueWidget()"))
        #expect(text.contains("ResumeVoxglassControl()"))
        #expect(text.contains("SleepTimerControl()"))
        #expect(text.contains("SkipBackControl()"))
        #expect(!FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("VoxglassWidgets/BookLiveActivity.swift").path))
    }

    // MARK: - Helpers

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
