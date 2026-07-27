import Foundation
import VoxglassCore

/// Watch-specific playback coordinator. Wraps Core's `PlaybackCoordinator` with a
/// `WatchPlaybackEngine`, the watch snapshot store, and the watch position store.
@MainActor
public final class WatchPlaybackCoordinator: ObservableObject {
    @Published public private(set) var currentSession: PlaybackSession?
    @Published public var playbackError: String?

    public var navigationHistory: NavigationHistoryStore

    /// Resolves a device-local cached file for a chapter, if one exists. Wired to
    /// `WatchStorageManager.localURL(for:)` so downloaded books play from the
    /// on-watch cache instead of streaming. Returns nil to fall back to streaming.
    public var localURLProvider: (@MainActor (Chapter) -> URL?)?

    /// The effective URL to play for a chapter: a downloaded local file wins,
    /// otherwise the streaming (remote) URL.
    private func resolvedURL(for chapter: Chapter) -> URL? {
        localURLProvider?(chapter) ?? chapter.resolvedPlayableURL()
    }

    private let engine: WatchPlaybackEngine
    private let positionStore: SQLitePositionStore
    private let snapshotStore: LastPlaybackSnapshotStore
    private var isEngineLoaded = false
    private var engineLoadTask: Task<Bool, Never>?
    private var progressTask: Task<Void, Never>?
    private var lastPeriodicSave = Date.distantPast
    private var currentArtworkBookID: UUID?
    private var suppressNextHistoryPush = false

    public init(
        positionStore: SQLitePositionStore,
        snapshotStore: LastPlaybackSnapshotStore,
        navigationHistoryStore: NavigationHistoryStore = NavigationHistoryStore()
    ) {
        self.engine = WatchPlaybackEngine()
        self.positionStore = positionStore
        self.snapshotStore = snapshotStore
        self.navigationHistory = navigationHistoryStore

        engine.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                await self?.handlePlaybackEnded()
            }
        }
        engine.configureAudioSession()
    }

    // MARK: - Presentation & Play

    public func pushNavigationHistory() {
        guard !suppressNextHistoryPush else { suppressNextHistoryPush = false; return }
        guard let session = currentSession, isEngineLoaded else { return }
        let record = NavigationRecord(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: engine.currentTime,
            duration: engine.duration ?? session.duration,
            recordedAt: Date()
        )
        navigationHistory.push(record)
    }

    @discardableResult
    public func undoLastNavigation(from books: [BookWithChapters]) -> Bool {
        guard let record = navigationHistory.pop(),
              let book = books.first(where: { $0.book.id == record.bookID }),
              let chapter = book.chapters.first(where: { $0.id == record.chapterID })
                  ?? book.chapters.first else { return false }
        suppressNextHistoryPush = true
        present(book, chapter: chapter)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.seek(to: record.position)
        }
        return true
    }

    public func present(_ book: BookWithChapters, chapter: Chapter? = nil) {
        pushNavigationHistory()
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
              let url = resolvedURL(for: target) else {
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
        guard let url = resolvedURL(for: chapter) else { return }
        pushNavigationHistory()
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

    // MARK: - Chapter navigation

    public var canGoToNextChapter: Bool {
        guard let session = currentSession else { return false }
        return WatchChapterNavigation.next(after: session.chapter.id, in: session.chapters) != nil
    }

    public var canGoToPreviousChapter: Bool {
        guard let session = currentSession else { return false }
        return WatchChapterNavigation.previous(before: session.chapter.id, in: session.chapters) != nil
    }

    public func nextChapter() async {
        guard let session = currentSession,
              let next = WatchChapterNavigation.next(after: session.chapter.id, in: session.chapters) else { return }
        await skipToChapter(next, in: BookWithChapters(book: session.book, chapters: session.chapters))
    }

    public func previousChapter() async {
        guard let session = currentSession,
              let prev = WatchChapterNavigation.previous(before: session.chapter.id, in: session.chapters) else { return }
        await skipToChapter(prev, in: BookWithChapters(book: session.book, chapters: session.chapters))
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
              let url = resolvedURL(for: session.chapter) else { return false }
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
