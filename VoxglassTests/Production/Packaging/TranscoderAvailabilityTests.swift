import Foundation
import Testing
import VoxglassCore
import VoxglassEncoders
import VoxglassCoreTestSupport

/// §16.3 / §19.3 — when an encoder is unavailable, `availableEncoders` excludes
/// it and the destination builder fails *before* writing any file.
@Suite struct TranscoderAvailabilityTests {

    @Test func availableEncodersExcludesDisabledCodecs() {
        let disabled = VoxTranscoder(mp3Available: false, flacAvailable: false)
        #expect(!disabled.availableEncoders.contains(.mp3))
        #expect(!disabled.availableEncoders.contains(.flac))
        #expect(disabled.availableEncoders.contains(.pcm))
        #expect(disabled.availableEncoders.contains(.aacLC))
    }

    @Test func librivoxBuilderFailsBeforeWritingWhenMp3Unavailable() async throws {
        let transcoder = VoxTranscoder(mp3Available: false)
        let project = ProjectFixtures.librivoxReady()

        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let builder = LibriVoxPackageBuilder()
        do {
            _ = try await builder.build(
                project: project,
                renders: ToneChapterRenderer(),
                transcoder: transcoder,
                assets: InMemoryAssetStore(),
                into: exportsRoot,
                options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
                progress: { _ in }
            )
            Issue.record("Expected PackagingError.encoderUnavailable")
        } catch let error as PackagingError {
            guard case .encoderUnavailable("mp3") = error else {
                Issue.record("Unexpected packaging error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
            return
        }

        // Precondition 3 runs before any I/O — nothing may have been written.
        let contents = try FileManager.default.contentsOfDirectory(at: exportsRoot, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test func librivoxBuilderRejectsIneligibleProject() async throws {
        let transcoder = VoxTranscoder()
        let project = ProjectFixtures.aiTainted()

        let exportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportsRoot) }

        let builder = LibriVoxPackageBuilder()
        do {
            _ = try await builder.build(
                project: project,
                renders: ToneChapterRenderer(),
                transcoder: transcoder,
                assets: InMemoryAssetStore(),
                into: exportsRoot,
                options: ExportOptions(generatedAt: Date(timeIntervalSinceReferenceDate: 0)),
                progress: { _ in }
            )
            Issue.record("Expected PackagingError.ineligible")
        } catch let error as PackagingError {
            guard case .ineligible(.librivox, _) = error else {
                Issue.record("Unexpected packaging error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let contents = try FileManager.default.contentsOfDirectory(at: exportsRoot, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }
}
