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

    @Test func carPlayReviewControllerDoesNotTouchNowPlayingInfoCenter() throws {
        let text = try source(Self.carPlayReview)
        #expect(!text.contains("MPNowPlayingInfoCenter"))
    }

    @Test func coordinatorDoesNotSubmitNowPlayingDirectly() throws {
        let text = try source(Self.coordinator)
        #expect(!text.contains("bridge.updateNowPlaying("))
    }

    @Test func bridgePublishesNativeNowPlayingOnly() throws {
        let text = try source(Self.bridge)
        #expect(text.contains("func updateLockScreen(nowPlaying: NowPlayingInfo?)"))
        #expect(text.contains("MPNowPlayingInfoCenter.default().nowPlayingInfo = mpInfo(from: info)"))
    }

    @Test func noCustomAudiobookActivityKitInIPhoneOrWidgetSources() throws {
        let forbidden = ["Activity.request", "ActivityConfiguration(for: BookActivityAttributes",
                         "LiveActivityController", "BookActivityAttributes"]
        for dir in ["Voxglass/App", "Voxglass/Core/Playback", "VoxglassShared", "VoxglassWidgets"] {
            let root = repoRoot.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "No sources under \(dir)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!text.contains(token), "\(token) found in \(file.lastPathComponent)")
                }
            }
        }
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
