import Foundation
import Observation
import VoxglassCore

/// Backs the Chapter Assembly screen (spec §18.1.11). Computes per-chapter
/// render cache keys from the current `AssemblySettings`, diffs them against
/// the store's `render_cache`, renders missing chapters, and plays assembled
/// chapters.
@Observable @MainActor
public final class AssemblyModel {
    public struct ChapterState: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var title: String
        public var ordinal: Int
        public var segments: [PlaybackSegment]
        public var cacheKey: String
        public var isCached: Bool
        public var duration: TimeInterval
        public var paragraphCount: Int

        public init(
            id: UUID,
            title: String,
            ordinal: Int,
            segments: [PlaybackSegment],
            cacheKey: String,
            isCached: Bool,
            duration: TimeInterval,
            paragraphCount: Int
        ) {
            self.id = id
            self.title = title
            self.ordinal = ordinal
            self.segments = segments
            self.cacheKey = cacheKey
            self.isCached = isCached
            self.duration = duration
            self.paragraphCount = paragraphCount
        }
    }

    public var settings: AssemblySettings {
        didSet {
            guard settings != oldValue else { return }
            Task { await recompute() }
        }
    }
    public private(set) var chapterStates: [ChapterState] = []
    public private(set) var changedChapterCount: Int = 0
    public private(set) var isRendering: Bool = false
    public private(set) var error: String?
    public private(set) var isPlaying: Bool = false

    private let project: AudiobookProject
    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let renderer: any ChapterRenderable
    private let player: any SegmentPlayer

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        renderer: any ChapterRenderable,
        player: any SegmentPlayer
    ) {
        self.project = project
        self.store = store
        self.assets = assets
        self.renderer = renderer
        self.player = player
        self.settings = project.profile.assembly
    }

    public func load() async {
        await recompute()
    }

    public func renderChapter(_ id: UUID) async {
        guard let state = chapterStates.first(where: { $0.id == id }), !state.segments.isEmpty else { return }
        isRendering = true
        defer { isRendering = false }
        do {
            let format = renderFormat
            let plan = RenderPlan(
                chapterID: id,
                segments: state.segments,
                settings: settings,
                outputFormat: format,
                cacheKey: state.cacheKey
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("render-\(id.uuidString).caf")
            let rendered = try await renderer.render(plan, to: url) { _ in }
            let ref = try await assets.ingest(
                fileAt: url,
                ext: "caf",
                contentType: "audio/caf",
                subdirectory: .render,
                moving: true
            )
            try await store.storeRender(ref, key: state.cacheKey, chapterID: id, duration: rendered.duration)
            await recompute()
        } catch {
            self.error = "Render failed: \(error.localizedDescription)"
        }
    }

    /// Renders every chapter whose key is missing from the cache, sequentially
    /// (§12.6 "Rebuild Changed Audio").
    public func rebuildChanged() async {
        for state in chapterStates where !state.isCached && !state.segments.isEmpty {
            await renderChapter(state.id)
            if isRendering { return }
        }
    }

    public func playChapter(_ id: UUID) async {
        guard let state = chapterStates.first(where: { $0.id == id }) else { return }
        do {
            try await player.load(state.segments)
            try await player.play()
            isPlaying = true
        } catch {
            self.error = "Playback failed: \(error.localizedDescription)"
        }
    }

    public func pausePlayback() async {
        await player.pause()
        isPlaying = false
    }

    // MARK: - Private

    private var renderFormat: AudioSpec {
        AudioSpec(
            container: .caf,
            codec: .pcm,
            sampleRate: project.profile.recording.sampleRate,
            channels: project.profile.recording.channels
        )
    }

    private func recompute() async {
        var newStates: [ChapterState] = []
        var changed = 0
        for chapter in project.chapters.sorted(by: { $0.ordinal < $1.ordinal }) {
            let segments = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: settings)
            let key = RenderCacheKey.key(
                chapterID: chapter.id,
                segments: segments,
                settings: settings,
                format: renderFormat
            )
            let cached = (try? await store.cachedRender(forKey: key)) != nil
            let needsRebuild = !cached && !segments.isEmpty
            if needsRebuild { changed += 1 }
            newStates.append(ChapterState(
                id: chapter.id,
                title: chapter.title,
                ordinal: chapter.ordinal,
                segments: segments,
                cacheKey: key,
                isCached: cached,
                duration: AssemblyDuration.duration(of: segments),
                paragraphCount: segments.count
            ))
        }
        chapterStates = newStates
        changedChapterCount = changed
    }
}
