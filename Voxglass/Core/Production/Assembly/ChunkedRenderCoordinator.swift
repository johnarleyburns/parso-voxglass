import Foundation

/// Chunked, cancellable chapter rendering (spec §11.2, M-4).
///
/// Render and export are chunked by chapter: the coordinator renders one
/// chapter at a time, checks `Task` cancellation before and after each chapter
/// and during a chapter's render (through the renderer's progress callback),
/// and treats an already-cached chapter as complete so a cancelled run resumes
/// at the first incomplete chapter rather than from zero. Rendered chapters
/// are moved into the content-addressed render store and recorded in the
/// `RenderCache` before the next chapter begins, so a force-quit mid-run never
/// wastes completed work.
public struct ChunkedRenderCoordinator: Sendable {

    /// Per-run progress, reported as `completedChapterCount` grows and as the
    /// current chapter's render advances (`currentChapterFraction`).
    public struct Progress: Sendable, Equatable {
        public var completedChapterCount: Int
        public var totalChapterCount: Int
        public var currentChapterOrdinal: Int?
        public var currentChapterTitle: String?
        public var currentChapterFraction: Double

        public init(
            completedChapterCount: Int,
            totalChapterCount: Int,
            currentChapterOrdinal: Int? = nil,
            currentChapterTitle: String? = nil,
            currentChapterFraction: Double = 0
        ) {
            self.completedChapterCount = completedChapterCount
            self.totalChapterCount = totalChapterCount
            self.currentChapterOrdinal = currentChapterOrdinal
            self.currentChapterTitle = currentChapterTitle
            self.currentChapterFraction = currentChapterFraction
        }
    }

    /// What a run produced. `renderings` holds the chapters actually rendered
    /// in this run; `completedChapterIDs` includes cached chapters (resume).
    public struct Result: Sendable {
        public var renderings: [UUID: ChapterRendering]
        public var completedChapterIDs: [UUID]

        public init(renderings: [UUID: ChapterRendering], completedChapterIDs: [UUID]) {
            self.renderings = renderings
            self.completedChapterIDs = completedChapterIDs
        }
    }

    public init() {}

    /// Renders `chapters` in document order. A chapter whose current
    /// `RenderCacheKey` is already in `cache` is skipped (resume). Throws
    /// `CancellationError` when the enclosing task is cancelled before or
    /// during a chapter render; everything rendered before the cancellation
    /// stays cached, so the next run resumes.
    public func render(
        chapters: [ProductionChapter],
        in project: AudiobookProject,
        renderer: any ChapterRenderable,
        cache: any RenderCache,
        assets: any ContentAddressedStore,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let total = chapters.count
        var renderings: [UUID: ChapterRendering] = [:]
        var completed: [UUID] = []
        let done = ProgressCounter()

        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()

            let plan = PackagingSupport.renderPlan(for: chapter, in: project)

            if let cached = try await cache.cachedRender(for: plan.cacheKey) {
                _ = cached
                completed.append(chapter.id)
                done.value += 1
                progress(Progress(completedChapterCount: done.value, totalChapterCount: total))
                continue
            }

            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("render-\(plan.cacheKey.prefix(16)).caf")
            let rendering = try await renderer.render(plan, to: tmpURL) { fraction in
                progress(Progress(
                    completedChapterCount: done.value,
                    totalChapterCount: total,
                    currentChapterOrdinal: index,
                    currentChapterTitle: chapter.title,
                    currentChapterFraction: fraction
                ))
            }

            // Bytes durable in the content store before the cache index moves
            // (§9.4 ordering); the render store is the first eviction class.
            let stored = try await assets.ingest(
                fileAt: tmpURL,
                ext: "caf",
                contentType: "audio/caf",
                subdirectory: .render,
                moving: true
            )
            try await cache.store(stored, for: plan.cacheKey)
            renderings[chapter.id] = rendering
            completed.append(chapter.id)
            done.value += 1

            try Task.checkCancellation()
            progress(Progress(completedChapterCount: done.value, totalChapterCount: total))
        }

        return Result(renderings: renderings, completedChapterIDs: completed)
    }
}

/// A thread-safe completed-chapter counter shared with the `@Sendable` progress
/// closure (Foundation `NSLock`, available on every Core platform).
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}
