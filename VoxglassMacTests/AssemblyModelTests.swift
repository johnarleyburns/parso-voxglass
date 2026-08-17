import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
import VoxglassStudioKit

/// Spec §18.1.11 / §12.6: the Assembly model computes render cache keys, diffs
/// them against the store cache, renders missing chapters, and invalidates a
/// chapter's render when its inputs change.
@Suite @MainActor struct AssemblyModelTests {

    private final class FakeChapterRenderer: ChapterRenderable, @unchecked Sendable {
        private(set) var renderCount = 0
        private(set) var lastPlan: RenderPlan?

        func render(
            _ plan: RenderPlan,
            to url: URL,
            progress: @Sendable (Double) -> Void
        ) async throws -> ChapterRendering {
            renderCount += 1
            lastPlan = plan
            try Data("fake-render".utf8).write(to: url)
            return ChapterRendering(
                ref: AudioAssetReference(sha256: "fake", relativePath: url.lastPathComponent, byteCount: 11, contentType: "audio/caf"),
                duration: 10,
                paragraphOffsets: [:]
            )
        }
    }

    private func makeProject() -> AudiobookProject {
        var chapters: [ProductionChapter] = []
        for c in 0..<2 {
            var paragraphs: [Paragraph] = []
            for i in 0..<3 {
                let pid = UUID()
                let take = Take(
                    id: UUID(),
                    paragraphID: pid,
                    assetRef: AudioAssetReference(sha256: "s\(c)-\(i)", relativePath: "p\(c)-\(i).wav", byteCount: 10, contentType: "audio/wav"),
                    origin: .recorded,
                    recordedAt: Date(),
                    duration: 5.0,
                    format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                    textHashAtRecording: "h"
                )
                paragraphs.append(Paragraph(id: pid, ordinal: i, text: "t\(c)-\(i)", textHash: "h", takes: [take], selectedTakeID: take.id))
            }
            chapters.append(ProductionChapter(id: UUID(), ordinal: c, title: "Ch\(c)", paragraphs: paragraphs))
        }
        return AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Assembly Test", author: "A", narrator: "N"),
            chapters: chapters,
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    private func makeModel() async throws -> (model: AssemblyModel, store: InMemoryProductionStore, renderer: FakeChapterRenderer, project: AudiobookProject) {
        let project = makeProject()
        let store = InMemoryProductionStore()
        try await store.save(project)
        let renderer = FakeChapterRenderer()
        let model = AssemblyModel(
            project: project,
            store: store,
            assets: InMemoryAssetStore(),
            renderer: renderer,
            player: FakeSegmentPlayer()
        )
        return (model, store, renderer, project)
    }

    @Test func loadFlagsUncachedChaptersAsNeedsRebuild() async throws {
        let (model, _, _, project) = try await makeModel()
        await model.load()

        #expect(model.chapterStates.count == project.chapters.count)
        #expect(model.chapterStates.allSatisfy { !$0.isCached })
        #expect(model.changedChapterCount == project.chapters.count)
    }

    @Test func renderChapterStoresRenderInCache() async throws {
        let (model, store, renderer, project) = try await makeModel()
        await model.load()

        let chapter = project.chapters[0]
        await model.renderChapter(chapter.id)

        let state = model.chapterStates.first { $0.id == chapter.id }
        #expect(state != nil)
        let cached = try await store.cachedRender(forKey: state!.cacheKey)
        #expect(cached != nil)
        #expect(renderer.renderCount == 1)
        #expect(renderer.lastPlan?.chapterID == chapter.id)
    }

    @Test func renderOnlyCachedChapterInvalidatesOneChapter() async throws {
        let (model, store, _, project) = try await makeModel()
        await model.load()

        let ch1 = project.chapters[0]
        await model.renderChapter(ch1.id)
        await model.load()

        #expect(model.chapterStates.first { $0.id == ch1.id }!.isCached == true)
        // Only chapter 1 is cached; chapter 2 still needs a rebuild.
        #expect(model.changedChapterCount == 1)
    }

    @Test func changingSpacingInvalidatesPreviouslyCachedRender() async throws {
        let (model, store, _, project) = try await makeModel()
        await model.load()

        let ch1 = project.chapters[0]
        await model.renderChapter(ch1.id)
        await model.load()
        #expect(model.chapterStates.first { $0.id == ch1.id }!.isCached == true)

        model.settings.paragraphGap = 0.9
        await model.load()

        #expect(model.chapterStates.first { $0.id == ch1.id }!.isCached == false)
    }
}
