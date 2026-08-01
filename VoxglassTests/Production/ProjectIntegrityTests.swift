import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

private struct StaticAssetStore: ContentAddressedStore, Sendable {
    let presentRefs: Set<String>

    func url(for ref: AudioAssetReference) -> URL {
        URL(fileURLWithPath: "/fake/\(ref.relativePath)")
    }

    func exists(_ ref: AudioAssetReference) -> Bool {
        presentRefs.contains(ref.sha256)
    }

    func put(_ data: Data, ext: String, contentType: String, subdirectory: AssetSubdirectory) async throws -> AudioAssetReference {
        AudioAssetReference(sha256: "", relativePath: "", byteCount: 0, contentType: contentType)
    }

    func ingest(fileAt url: URL, ext: String, contentType: String, subdirectory: AssetSubdirectory, moving: Bool) async throws -> AudioAssetReference {
        AudioAssetReference(sha256: "", relativePath: "", byteCount: 0, contentType: contentType)
    }

    func data(for ref: AudioAssetReference) async throws -> Data { Data() }

    func trash(_ ref: AudioAssetReference) async throws {}

    func allReferences(under subdirectory: AssetSubdirectory) async throws -> [AudioAssetReference] { [] }

    func totalBytes(under subdirectory: AssetSubdirectory) async throws -> Int64 { 0 }
}

@Suite struct ProjectIntegrityTests {

    @Test func cleanProjectHasNoFindings() {
        let project = ProjectFixtures.tiny()
        let allShas = Set(project.allParagraphs.flatMap { $0.takes }.map { $0.assetRef.sha256 })
        let store = StaticAssetStore(presentRefs: allShas)
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(findings.isEmpty)
    }

    @Test func detectsDuplicateChapterOrdinals() {
        let project = ProjectFixtures.brokenIntegrity()
        let store = StaticAssetStore(presentRefs: [])
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(findings.contains { $0.code == .duplicateChapterOrdinal })
    }

    @Test func detectsDuplicateParagraphOrdinals() {
        let project = ProjectFixtures.brokenIntegrity()
        let store = StaticAssetStore(presentRefs: [])
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(findings.contains { $0.code == .duplicateParagraphOrdinal })
    }

    @Test func detectsMissingTakeAsset() {
        var project = ProjectFixtures.tiny()

        let assetRef = AudioAssetReference(
            sha256: "deadbeef",
            relativePath: "Audio/Original/de/ad/deadbeef.wav",
            byteCount: 1000,
            contentType: "public.wav"
        )
        let take = Take(
            id: UUID(),
            paragraphID: project.chapters[0].paragraphs[0].id,
            assetRef: assetRef,
            origin: .recorded,
            recordedAt: Date(),
            duration: 5.0,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s24le"),
            textHashAtRecording: SHA256Hex.hex(Data("test".utf8))
        )
        project.chapters[0].paragraphs[0].takes = [take]
        project.chapters[0].paragraphs[0].selectedTakeID = take.id

        let store = StaticAssetStore(presentRefs: [])
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(findings.contains { $0.code == .takeAssetMissing })
    }

    @Test func findsNoAssetIssuesWhenAssetsPresent() {
        let project = ProjectFixtures.tiny()
        let shas = Set(project.allParagraphs.flatMap { $0.takes }.compactMap { $0.assetRef.sha256 })

        let store = StaticAssetStore(presentRefs: shas)
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(!findings.contains { $0.code == .takeAssetMissing })
    }

    @Test func detectsSelectedTakeMissingFromTakesList() {
        let ids = SequentialIDGenerator()
        let fakeID = UUID()
        var project = ProjectFixtures.tiny()
        project.chapters[0].paragraphs[0].selectedTakeID = fakeID

        let store = StaticAssetStore(presentRefs: [])
        let findings = ProjectIntegrity.check(project, assets: store)
        #expect(findings.contains { $0.code == .selectedTakeMissing })
    }
}
