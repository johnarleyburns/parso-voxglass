import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §6.5: StorageReport.orphanBytes is "assets referenced by nothing" —
/// takes, source blobs and the cover are referenced; anything else in the
/// asset roots is orphaned and may be vacuumed.
@Suite struct StorageAnalyzerTests {

    @Test func reportCountsOrphanedAssets() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("storage-analyzer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let package = try await ProjectPackage.create(
            title: "Pkg", author: "A", narrator: "N",
            at: tmp.appendingPathComponent("pkg"),
            clock: FixedClock(), ids: SequentialIDGenerator()
        )
        let store = FileAssetStore(root: package.root)

        let project = ProjectFixtures.tiny()

        // One asset referenced by a take.
        let referenced = Data("referenced take audio".utf8)
        let takeRef = try await store.put(referenced, ext: "wav", contentType: "audio/wav", subdirectory: .original)
        var withTake = project
        withTake.chapters[0].paragraphs[0].takes = [
            Take(
                id: UUID(),
                paragraphID: withTake.chapters[0].paragraphs[0].id,
                assetRef: takeRef,
                origin: .recorded,
                recordedAt: Date(timeIntervalSince1970: 0),
                duration: 1.0,
                format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
                processing: [],
                metrics: nil,
                label: nil,
                textHashAtRecording: "",
                isArchived: false
            )
        ]

        // One orphaned asset.
        _ = try await store.put(Data("orphaned audio bytes".utf8), ext: "wav", contentType: "audio/wav", subdirectory: .original)

        let report = try await StorageAnalyzer().report(package: package, project: withTake)

        #expect(report.originalBytes == Int64(referenced.count + 20)) // referenced + orphaned
        #expect(report.orphanBytes == 20) // only the orphaned asset
    }

    @Test func reportCountsNoOrphansWhenAllReferenced() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("storage-analyzer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let package = try await ProjectPackage.create(
            title: "Pkg", author: "A", narrator: "N",
            at: tmp.appendingPathComponent("pkg"),
            clock: FixedClock(), ids: SequentialIDGenerator()
        )
        let store = FileAssetStore(root: package.root)

        let project = ProjectFixtures.tiny()

        var withTake = project
        for ci in withTake.chapters.indices {
            for pi in withTake.chapters[ci].paragraphs.indices {
                let data = Data("take \(ci)-\(pi)".utf8)
                let ref = try await store.put(data, ext: "wav", contentType: "audio/wav", subdirectory: .original)
                withTake.chapters[ci].paragraphs[pi].takes = [
                    Take(
                        id: UUID(),
                        paragraphID: withTake.chapters[ci].paragraphs[pi].id,
                        assetRef: ref,
                        origin: .recorded,
                        recordedAt: Date(timeIntervalSince1970: 0),
                        duration: 1.0,
                        format: AudioFormatDescription(sampleRate: 48000, channels: 1, bitDepth: 16, codec: "pcm"),
                        processing: [],
                        metrics: nil,
                        label: nil,
                        textHashAtRecording: "",
                        isArchived: false
                    )
                ]
            }
        }

        let report = try await StorageAnalyzer().report(package: package, project: withTake)
        #expect(report.orphanBytes == 0)
        #expect(report.originalBytes > 0)
    }
}
