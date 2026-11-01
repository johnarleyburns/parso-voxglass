import Foundation
import Testing

@Suite struct NativeNowPlayingOwnershipContractTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func swiftSources(under paths: [String]) -> [(path: String, text: String)] {
        var result: [(String, String)] = []
        for path in paths {
            let dir = root.appendingPathComponent(path)
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    result.append((url.path, text))
                }
            }
        }
        return result
    }

    @Test func widgetBundleDoesNotRegisterBookLiveActivity() throws {
        let source = try read("VoxglassWidgets/VoxglassWidgets.swift")
        #expect(!source.contains("BookLiveActivity()"))
    }

    @Test func iPhoneAudioCodeCreatesNoBookActivity() {
        let files = swiftSources(under: ["Voxglass/App", "Voxglass/Core/Playback", "VoxglassShared"])
        #expect(!files.isEmpty)
        for file in files {
            #expect(!file.text.contains("Activity<BookActivityAttributes>"), "\(file.path)")
            #expect(!file.text.contains("Activity.request"), "\(file.path)")
        }
    }

    @Test func coordinatorDoesNotDriveLiveActivity() throws {
        let source = try read("Voxglass/Core/Playback/PlaybackCoordinator.swift")
        #expect(!source.contains("liveActivity:"))
        #expect(!source.contains("lastLiveActivityContent"))
    }

    @Test func bridgeHasSingleNativePublishingOwner() throws {
        let source = try read("Voxglass/App/SystemPlaybackBridge.swift")
        let marker = "private func publishNowPlaying()"
        let start = try #require(source.range(of: marker))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        let helper = String(source[start.lowerBound..<end])
        let assignment = "MPNowPlayingInfoCenter.default().nowPlayingInfo ="
        let total = source.components(separatedBy: assignment).count - 1
        let inHelper = helper.components(separatedBy: assignment).count - 1
        #expect(inHelper >= 1)
        #expect(total == inHelper, "nowPlayingInfo assigned outside publishNowPlaying()")
    }

    @Test func togglePlaybackIntentIsAudioPlaybackIntent() throws {
        let source = try read("VoxglassShared/PlaybackControlIntents.swift")
        #expect(source.contains("struct TogglePlaybackIntent: AudioPlaybackIntent"))
    }
}
