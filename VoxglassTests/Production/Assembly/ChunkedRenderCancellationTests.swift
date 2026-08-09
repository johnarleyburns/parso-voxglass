import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §11.2 / M-4 acceptance: a chapter render cancels cleanly mid-run and
/// resumes at the first incomplete chapter. The `ChunkedRenderCoordinator`
/// renders one chapter at a time, checks `Task` cancellation between and during
/// chapters, treats cached chapters as complete, and never loses completed
/// work — so a force-quit or user cancel leaves every finished chapter cached.
@Suite struct ChunkedRenderCancellationTests {

    /// A thread-safe count shared between the renderer closure and the test.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// Writes a placeholder render file so the content store can ingest it,
    /// exactly like a real renderer writes audio.
    private static func renderedFile(_ plan: RenderPlan, to url: URL) throws -> ChapterRendering {
        let data = Data("render-\(plan.cacheKey)".utf8)
        try data.write(to: url)
        let sha = SHA256Hex.hex(data)
        return ChapterRendering(
            ref: AudioAssetReference(sha256: sha, relativePath: url.lastPathComponent, byteCount: data.count, contentType: "audio/caf"),
            duration: 10,
            paragraphOffsets: [:]
        )
    }

    /// A `ChapterRenderable` whose behavior is scripted per render call.
    private struct ScriptedRenderer: ChapterRenderable {
        var calls = Counter()
        var behavior: @Sendable (RenderPlan, URL, Counter) throws -> ChapterRendering

        func render(_ plan: RenderPlan, to url: URL, progress: @Sendable (Double) -> Void) async throws -> ChapterRendering {
            calls.value += 1
            progress(0.5)
            return try behavior(plan, url, calls)
        }
    }

    private actor MemoryRenderCache: RenderCache {
        var entries: [String: AudioAssetReference] = [:]
        func cachedRender(for key: String) async throws -> AudioAssetReference? {
            entries[key]
        }
        func store(_ ref: AudioAssetReference, for key: String) async throws {
            entries[key] = ref
        }
    }

    /// Builds a three-chapter project where every paragraph has a recorded take.
    private static func threeChapterProject() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        var chapters: [ProductionChapter] = []
        for i in 0..<3 {
            let chapterID = ids.next()
            let paragraphID = ids.next()
            let takeID = ids.next()
            let text = "Paragraph of chapter \(i + 1) for the render cancellation test."
            let hash = SHA256Hex.hex(Data(text.utf8))
            let take = Take(
                id: takeID,
                paragraphID: paragraphID,
                assetRef: AudioAssetReference(sha256: "sha-\(i)", relativePath: "Audio/Original/xx/yy/\(i).wav", byteCount: 100, contentType: "public.wav"),
                origin: .recorded,
                recordedAt: clock.now,
                duration: 2.0,
                format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                textHashAtRecording: hash
            )
            let paragraph = Paragraph(id: paragraphID, ordinal: 0, text: text, textHash: hash, takes: [take], selectedTakeID: takeID)
            chapters.append(ProductionChapter(id: chapterID, ordinal: i, title: "Chapter \(i + 1)", paragraphs: [paragraph]))
        }
        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Render Book", author: "Author", narrator: "Narrator"),
            chapters: chapters,
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    private static func cacheKey(_ chapter: ProductionChapter, in project: AudiobookProject) -> String {
        PackagingSupport.renderPlan(for: chapter, in: project).cacheKey
    }

    private static func normalRenderer(_ calls: Counter) -> ScriptedRenderer {
        ScriptedRenderer(calls: calls) { plan, url, _ in
            try Self.renderedFile(plan, to: url)
        }
    }

    @Test func rendersEveryChapterThenResumesFromCache() async throws {
        let project = Self.threeChapterProject()
        let cache = MemoryRenderCache()
        let assets = InMemoryAssetStore()
        let calls = Counter()
        let renderer = Self.normalRenderer(calls)

        let result = try await ChunkedRenderCoordinator().render(
            chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets
        )
        #expect(result.completedChapterIDs.count == 3)
        #expect(calls.value == 3)

        let rerun = try await ChunkedRenderCoordinator().render(
            chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets
        )
        #expect(rerun.completedChapterIDs.count == 3)
        #expect(calls.value == 3, "cached chapters must not re-render (resume)")
    }

    @Test func cancelBetweenChaptersThrowsAndResumesAtFirstIncomplete() async throws {
        let project = Self.threeChapterProject()
        let cache = MemoryRenderCache()
        let assets = InMemoryAssetStore()
        let calls = Counter()
        let renderer = ScriptedRenderer(calls: calls) { plan, url, counter in
            if counter.value == 2 {
                throw CancellationError()
            }
            return try Self.renderedFile(plan, to: url)
        }

        do {
            _ = try await ChunkedRenderCoordinator().render(
                chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets
            )
            Issue.record("expected a cancellation mid-run")
        } catch is CancellationError {
            // expected
        }

        // Chapter 0 completed and is cached; the cancelled chapter is not.
        let plan0 = Self.cacheKey(project.chapters[0], in: project)
        let plan1 = Self.cacheKey(project.chapters[1], in: project)
        #expect((try? await cache.cachedRender(for: plan0)) != nil)
        #expect((try? await cache.cachedRender(for: plan1)) == nil)

        // Resume: chapter 0 is skipped, chapters 1 and 2 render.
        let resume = try await ChunkedRenderCoordinator().render(
            chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets
        )
        #expect(resume.completedChapterIDs.count == 3)
        #expect((try? await cache.cachedRender(for: plan1)) != nil)
        #expect(calls.value == 4, "three renders plus one resume render for the cancelled chapter")
    }

    @Test func cancelledFirstChapterStaysUncached() async throws {
        let project = Self.threeChapterProject()
        let cache = MemoryRenderCache()
        let assets = InMemoryAssetStore()
        let calls = Counter()
        let renderer = ScriptedRenderer(calls: calls) { _, _, _ in
            throw CancellationError()
        }

        do {
            _ = try await ChunkedRenderCoordinator().render(
                chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets
            )
            Issue.record("expected immediate cancellation")
        } catch is CancellationError {
            // expected
        }
        let plan0 = Self.cacheKey(project.chapters[0], in: project)
        #expect((try? await cache.cachedRender(for: plan0)) == nil)
    }

    @Test func progressReportsCompletedChapters() async throws {
        let project = Self.threeChapterProject()
        let cache = MemoryRenderCache()
        let assets = InMemoryAssetStore()
        let calls = Counter()
        let renderer = Self.normalRenderer(calls)

        let seen = ProgressCollector()
        let result = try await ChunkedRenderCoordinator().render(
            chapters: project.chapters, in: project, renderer: renderer, cache: cache, assets: assets,
            progress: { seen.append($0) }
        )
        #expect(result.completedChapterIDs.count == 3)
        #expect(seen.values.contains { $0.completedChapterCount == 3 && $0.totalChapterCount == 3 })
        #expect(seen.values.allSatisfy { $0.totalChapterCount == 3 })
    }

    /// A thread-safe progress accumulator for the `@Sendable` progress closure.
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ChunkedRenderCoordinator.Progress] = []
        var values: [ChunkedRenderCoordinator.Progress] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ value: ChunkedRenderCoordinator.Progress) {
            lock.lock(); defer { lock.unlock() }
            storage.append(value)
        }
    }
}
