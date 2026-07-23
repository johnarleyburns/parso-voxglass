import Foundation
import VoxglassCore

/// Watch-specific playback coordinator. Wraps Core's `PlaybackCoordinator` with a
/// `WatchPlaybackEngine`, the watch snapshot store, and the watch position store.
@MainActor
public final class WatchPlaybackCoordinator: ObservableObject {
    @Published public private(set) var currentSession: PlaybackSession?
    @Published public var playbackError: String?

    private let engine: WatchPlaybackEngine
    private let positionStore: SQLitePositionStore
    private let snapshotStore: LastPlaybackSnapshotStore
    private var isEngineLoaded = false
    private var engineLoadTask: Task<Bool, Never>?
    private var progressTask: Task<Void, Never>?
    private var lastPeriodicSave = Date.distantPast
    private var currentArtworkBookID: UUID?

    public init(
        positionStore: SQLitePositionStore,
        snapshotStore: LastPlaybackSnapshotStore
    ) {
        self.engine = WatchPlaybackEngine()
        self.positionStore = positionStore
        self.snapshotStore = snapshotStore

        engine.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                await self?.handlePlaybackEnded()
            }
        }
        engine.configureAudioSession()
    }

    // MARK: - Presentation & Play

    public func present(_ book: BookWithChapters, chapter: Chapter? = nil) {
        let target = chapter ?? book.chapters.first
        guard let target else { return }

        currentSession = PlaybackSession(
            book: book.book,
            chapters: book.chapters,
            chapter: target,
            position: 0,
            duration: target.duration,
            isPlaying: false
        )
        isEngineLoaded = false
    }

    public func play(_ book: BookWithChapters, chapter: Chapter? = nil) async {
        let target = chapter ?? book.chapters.first
        guard let target,
              let url = target.resolvedPlayableURL() else {
            playbackError = "No playable URL for this chapter."
            return
        }

        do {
            try await engine.load(url: url, startTime: currentSession?.position ?? 0)
            isEngineLoaded = true
            engine.play()

            currentSession = PlaybackSession(
                book: book.book,
                chapters: book.chapters,
                chapter: target,
                position: 0,
                duration: target.duration ?? engine.duration,
                isPlaying: true
            )
            startProgressLoop()
        } catch {
            isEngineLoaded = false
            playbackError = error.localizedDescription
        }
    }

    public func togglePlayPause() {
        guard currentSession != nil else { return }
        if engine.isPlaying {
            pause()
        } else {
            Task { @MainActor in
                guard await ensureEngineLoaded() else { return }
                engine.play()
                currentSession?.isPlaying = true
                startProgressLoop()
            }
        }
    }

    public func pause() {
        guard currentSession != nil else { return }
        saveCurrentSnapshot()
        engine.pause()
        currentSession?.isPlaying = false
        Task { await persistCurrentPosition() }
    }

    public func skipBackward(seconds: TimeInterval = 15) async {
        guard let session = currentSession else { return }
        let newPos = max(0, session.position - seconds)
        await seek(to: newPos)
    }

    public func skipForward(seconds: TimeInterval = 30) async {
        guard let session = currentSession else { return }
        let dur = engine.duration ?? session.duration
        let newPos = min(dur ?? .infinity, session.position + seconds)
        await seek(to: newPos)
    }

    public func seek(to position: TimeInterval) async {
        guard currentSession != nil else { return }
        if isEngineLoaded {
            await engine.seek(to: position)
        }
        currentSession?.position = position
        await persistCurrentPosition()
    }

    public func skipToChapter(_ chapter: Chapter, in book: BookWithChapters) async {
        guard let url = chapter.resolvedPlayableURL() else { return }
        await persistCurrentPosition()
        do {
            try await engine.load(url: url, startTime: 0)
            isEngineLoaded = true
            if currentSession?.isPlaying == true {
                engine.play()
            }
            currentSession = PlaybackSession(
                book: book.book,
                chapters: book.chapters,
                chapter: chapter,
                position: 0,
                duration: chapter.duration ?? engine.duration,
                isPlaying: currentSession?.isPlaying ?? false
            )
        } catch {
            playbackError = error.localizedDescription
        }
    }

    // MARK: - Position persistence

    /// Persists the current playback position. Uses the heartbeat pattern from
    /// Core: save on pause, seek, chapter change, app resign active, and
    /// periodically during playback (every 5 s).
    public func persistCurrentPosition() async {
        guard let session = currentSession else { return }
        let pos = isEngineLoaded ? engine.currentTime : session.position
        guard pos > 0 || !isEngineLoaded else { return }
        let playbackPosition = PlaybackPosition(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: pos,
            duration: engine.duration ?? session.duration,
            updatedAt: Date(),
            isFinished: false
        )
        snapshotStore.save(playbackPosition)
        try? await positionStore.save(playbackPosition)
    }

    public func handleWillResignActive() {
        saveCurrentSnapshot()
    }

    public func handleWillBackgroundOrTerminate() {
        saveCurrentSnapshot()
        Task { await persistCurrentPosition() }
    }

    // MARK: - Private

    private func ensureEngineLoaded() async -> Bool {
        if isEngineLoaded { return true }
        if let engineLoadTask { return await engineLoadTask.value }
        let task = Task { @MainActor [weak self] in
            await self?.loadEngineForPresentedSession() ?? false
        }
        engineLoadTask = task
        let loaded = await task.value
        engineLoadTask = nil
        return loaded
    }

    private func loadEngineForPresentedSession() async -> Bool {
        guard let session = currentSession,
              let url = session.chapter.resolvedPlayableURL() else { return false }
        do {
            try await engine.load(url: url, startTime: session.position)
            isEngineLoaded = true
            return true
        } catch {
            playbackError = error.localizedDescription
            return false
        }
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.tickProgress()
            }
        }
    }

    private func tickProgress() async {
        guard currentSession != nil else { return }
        currentSession?.position = engine.currentTime
        currentSession?.duration = engine.duration
        saveCurrentSnapshot()

        if engine.isPlaying, Date().timeIntervalSince(lastPeriodicSave) >= 5 {
            await persistCurrentPosition()
        }
    }

    private func saveCurrentSnapshot() {
        guard let session = currentSession, isEngineLoaded, engine.isReady, engine.currentTime > 0 else { return }
        snapshotStore.save(PlaybackPosition(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: engine.currentTime,
            duration: engine.duration ?? session.duration,
            updatedAt: Date(),
            isFinished: false
        ))
    }

    private func handlePlaybackEnded() async {
        guard let session = currentSession else { return }
        await persistCurrentPosition()
        currentSession?.isPlaying = false
    }
}
