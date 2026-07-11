import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var currentSession: PlaybackSession?
    @Published var playbackError: String?

    private let engine: AudioEngine
    private let positionStore: PositionStore
    private let snapshotStore: LastPlaybackSnapshotStore
    private var progressTask: Task<Void, Never>?
    private var lastPeriodicSave = Date.distantPast
    private var notificationObservers: [NSObjectProtocol] = []
    private var isHandlingInterruption = false

    init(
        engine: AudioEngine,
        positionStore: PositionStore,
        snapshotStore: LastPlaybackSnapshotStore = LastPlaybackSnapshotStore()
    ) {
        self.engine = engine
        self.positionStore = positionStore
        self.snapshotStore = snapshotStore
        self.engine.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                await self?.advanceAfterChapterEnd()
            }
        }
        if let avEngine = engine as? AVPlayerAudioEngine {
            avEngine.onItemChanged = { [weak self] in
                Task { @MainActor in
                    await self?.handleItemChanged()
                }
            }
        }
        self.engine.configureAudioSession()
        configureRemoteCommands()
        configureNotifications()
    }

    func restoreLatestSession(from books: [BookWithChapters]) async {
        do {
            let storedPosition = try await positionStore.latestPosition()
            let snapshotPosition = snapshotStore.load()
            let latest = [storedPosition, snapshotPosition]
                .compactMap { $0 }
                .max { $0.updatedAt < $1.updatedAt }

            guard let latest,
                  let book = books.first(where: { $0.book.id == latest.bookID }),
                  let chapter = book.chapters.first(where: { $0.id == latest.chapterID }),
                  let url = chapter.resolvedPlayableURL() else {
                return
            }

            try await engine.load(url: url, startTime: latest.position)
            currentSession = PlaybackSession(
                book: book.book,
                chapters: book.chapters,
                chapter: chapter,
                position: latest.position,
                duration: latest.duration ?? chapter.duration ?? engine.duration,
                isPlaying: false
            )
            updateNowPlayingInfo()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func play(_ book: BookWithChapters, chapter requestedChapter: Chapter? = nil) async {
        let chapter = requestedChapter ?? book.chapters.first
        guard let chapter else { return }
        guard let playableURL = chapter.resolvedPlayableURL() else {
            playbackError = AudioEngineError.missingPlayableURL.localizedDescription
            return
        }

        do {
            let savedPosition = try await positionStore.position(for: book.book.id, chapterID: chapter.id)
            let startTime = savedPosition?.position ?? 0
            try await engine.load(url: playableURL, startTime: startTime)
            engine.play()

            currentSession = PlaybackSession(
                book: book.book,
                chapters: book.chapters,
                chapter: chapter,
                position: startTime,
                duration: savedPosition?.duration ?? chapter.duration ?? engine.duration,
                isPlaying: true
            )
            startProgressLoop()
            updateNowPlayingInfo()

            // Warm the streaming cache for the next chapter in the background
            prefetchNextChapter(from: book, currentChapter: chapter)

            // Preload the next chapter for near-gapless
            let nextIndex = chapterIndex(in: book, for: chapter) + 1
            if book.chapters.indices.contains(nextIndex),
               let nextURL = book.chapters[nextIndex].resolvedPlayableURL(),
               let avEngine = engine as? AVPlayerAudioEngine {
                avEngine.preloadNext(url: nextURL)
            }
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func chapterIndex(in book: BookWithChapters, for chapter: Chapter) -> Int {
        book.chapters.firstIndex { $0.id == chapter.id } ?? 0
    }

    func togglePlayPause() {
        guard currentSession != nil else { return }
        if engine.isPlaying {
            pause()
        } else {
            engine.play()
            mutateSession { $0.isPlaying = true }
            startProgressLoop()
            updateNowPlayingInfo()
        }
    }

    func pause() {
        guard currentSession != nil else { return }
        engine.pause()
        mutateSession {
            $0.position = engine.currentTime
            $0.duration = engine.duration ?? $0.duration
            $0.isPlaying = false
        }
        Task { await persistCurrentPosition(reason: .pause) }
        updateNowPlayingInfo()
    }

    func seek(to position: TimeInterval) async {
        guard currentSession != nil else { return }
        await engine.seek(to: position)
        mutateSession {
            $0.position = PlaybackMath.clampedPosition(position, duration: $0.duration)
            $0.duration = engine.duration ?? $0.duration
        }
        await persistCurrentPosition(reason: .seek)
        updateNowPlayingInfo()
    }

    func skip(by delta: TimeInterval) async {
        guard let currentSession else { return }
        await seek(to: currentSession.position + delta)
    }

    func skipToNextChapter() async {
        guard let session = currentSession else { return }
        await persistCurrentPosition(reason: .skip)

        let nextIndex = session.chapterIndex + 1
        guard session.chapters.indices.contains(nextIndex) else { return }

        if let avEngine = engine as? AVPlayerAudioEngine {
            avEngine.cancelPreload()
        }

        await loadChapter(session.chapters[nextIndex], in: session, startTime: 0, shouldPlay: engine.isPlaying)

        // Set up preload for the chapter after next
        let afterNextIndex = nextIndex + 1
        if session.chapters.indices.contains(afterNextIndex),
           let afterNextURL = session.chapters[afterNextIndex].resolvedPlayableURL(),
           let avEngine = engine as? AVPlayerAudioEngine {
            avEngine.preloadNext(url: afterNextURL)
        }
    }

    func skipToPreviousChapter() async {
        guard let session = currentSession else { return }
        if session.position > 8 {
            await seek(to: 0)
            return
        }

        await persistCurrentPosition(reason: .skip)
        let previousIndex = session.chapterIndex - 1
        guard session.chapters.indices.contains(previousIndex) else { return }
        await loadChapter(session.chapters[previousIndex], in: session, startTime: 0, shouldPlay: engine.isPlaying)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background {
            Task { await persistCurrentPosition(reason: .background) }
        }
    }

    private func prefetchNextChapter(from book: BookWithChapters, currentChapter: Chapter) {
        guard let currentIndex = book.chapters.firstIndex(where: { $0.id == currentChapter.id }) else { return }
        let nextIndex = currentIndex + 1
        guard book.chapters.indices.contains(nextIndex) else { return }
        let nextChapter = book.chapters[nextIndex]

        guard let url = nextChapter.remoteURL, nextChapter.localURL == nil,
              CachingResourceLoader.isRemoteCacheable(url),
              let avEngine = engine as? AVPlayerAudioEngine else { return }
        avEngine.prefetchIntoCache(url: url)
    }

    private func loadChapter(_ chapter: Chapter, in session: PlaybackSession, startTime: TimeInterval, shouldPlay: Bool) async {
        guard let url = chapter.resolvedPlayableURL() else { return }
        do {
            try await engine.load(url: url, startTime: startTime)
            if shouldPlay {
                engine.play()
            }
            currentSession = PlaybackSession(
                book: session.book,
                chapters: session.chapters,
                chapter: chapter,
                position: startTime,
                duration: chapter.duration ?? engine.duration,
                isPlaying: shouldPlay
            )
            await persistCurrentPosition(reason: .chapterChange)
            updateNowPlayingInfo()

            let nextIndex = chapterIndex(in: BookWithChapters(book: session.book, chapters: session.chapters), for: chapter) + 1
            if session.chapters.indices.contains(nextIndex),
               let nextURL = session.chapters[nextIndex].resolvedPlayableURL(),
               let avEngine = engine as? AVPlayerAudioEngine {
                avEngine.preloadNext(url: nextURL)
            }
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func handleItemChanged() async {
        guard let session = currentSession else { return }
        let nextIndex = session.chapterIndex + 1
        guard session.chapters.indices.contains(nextIndex) else {
            updateNowPlayingInfo()
            return
        }
        let nextChapter = session.chapters[nextIndex]

        // Save position for previous chapter as finished
        await persistCurrentPosition(reason: .chapterChange, finished: true)

        // Update session to the new chapter
        currentSession = PlaybackSession(
            book: session.book,
            chapters: session.chapters,
            chapter: nextChapter,
            position: 0,
            duration: nextChapter.duration ?? engine.duration,
            isPlaying: engine.isPlaying
        )
        startProgressLoop()
        updateNowPlayingInfo()

        // Warm the streaming cache for the chapter after next
        prefetchNextChapter(from: BookWithChapters(book: session.book, chapters: session.chapters),
                            currentChapter: nextChapter)
        // Preload the chapter after next for near-gapless
        preloadChapterAfter(nextChapter, in: session)
    }

    private func preloadChapterAfter(_ chapter: Chapter, in session: PlaybackSession) {
        guard let avEngine = engine as? AVPlayerAudioEngine else { return }
        let nextIndex = session.chapterIndex + 2
        guard session.chapters.indices.contains(nextIndex) else { return }
        let afterNext = session.chapters[nextIndex]
        guard let url = afterNext.resolvedPlayableURL() else { return }
        avEngine.preloadNext(url: url)
    }

    private func advanceAfterChapterEnd() async {
        guard let session = currentSession else { return }
        mutateSession {
            $0.position = $0.duration ?? engine.currentTime
            $0.isPlaying = false
        }

        let nextIndex = session.chapterIndex + 1
        guard session.chapters.indices.contains(nextIndex) else {
            await persistCurrentPosition(reason: .chapterChange, finished: true)
            updateNowPlayingInfo()
            return
        }

        // If the next item is already preloaded in AVQueuePlayer, it will auto-advance.
        // The handleItemChanged callback will update the session. Just persist position.
        await persistCurrentPosition(reason: .chapterChange, finished: true)

        // Fallback: if preloading didn't happen, do a manual load
        let nextChapter = session.chapters[nextIndex]
        guard let url = nextChapter.resolvedPlayableURL() else {
            updateNowPlayingInfo()
            return
        }

        // Check if engine has already moved to the next item
        if engine.duration == nil || engine.duration == session.duration {
            // Engine hasn't advanced - manually load
            await loadChapter(nextChapter, in: session, startTime: 0, shouldPlay: true)
        }
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tickProgress()
            }
        }
    }

    private func tickProgress() async {
        guard currentSession != nil else { return }
        mutateSession {
            $0.position = engine.currentTime
            $0.duration = engine.duration ?? $0.duration
            $0.isPlaying = engine.isPlaying
        }
        saveCurrentSnapshot()

        if engine.isPlaying, Date().timeIntervalSince(lastPeriodicSave) >= 5 {
            await persistCurrentPosition(reason: .periodic)
        }
        updateNowPlayingInfo()
    }

    private func persistCurrentPosition(reason: PositionPersistReason, finished: Bool = false) async {
        guard let session = currentSession else { return }
        let position = PlaybackPosition(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: engine.currentTime,
            duration: engine.duration ?? session.duration,
            updatedAt: Date(),
            isFinished: finished
        )
        snapshotStore.save(position)
        do {
            try await positionStore.save(position)
            if reason == .periodic {
                lastPeriodicSave = Date()
            }
        } catch {
            playbackError = error.localizedDescription
        }
    }

    private func saveCurrentSnapshot() {
        guard let session = currentSession else { return }
        snapshotStore.save(PlaybackPosition(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: engine.currentTime,
            duration: engine.duration ?? session.duration,
            updatedAt: Date(),
            isFinished: false
        ))
    }

    private func mutateSession(_ mutation: (inout PlaybackSession) -> Void) {
        guard var session = currentSession else { return }
        mutation(&session)
        currentSession = session
    }

    private func configureNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.persistCurrentPosition(reason: .background)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.persistCurrentPosition(reason: .background)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                await self?.handleInterruption(notification)
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.persistCurrentPosition(reason: .routeChange)
            }
        })
    }

    private func handleInterruption(_ notification: Notification) async {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            isHandlingInterruption = engine.isPlaying
            engine.pause()
            mutateSession {
                $0.position = engine.currentTime
                $0.isPlaying = false
            }
            await persistCurrentPosition(reason: .interruption)
        case .ended:
            guard isHandlingInterruption else { return }
            isHandlingInterruption = false
            engine.play()
            mutateSession { $0.isPlaying = true }
            startProgressLoop()
        @unknown default:
            break
        }
        updateNowPlayingInfo()
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.engine.play()
                self?.mutateSession { $0.isPlaying = true }
                self?.startProgressLoop()
                self?.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.skip(by: 30)
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.skip(by: -15)
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.skipToNextChapter()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.skipToPreviousChapter()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                await self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let session = currentSession else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.chapter.title,
            MPMediaItemPropertyAlbumTitle: session.book.title,
            MPMediaItemPropertyArtist: session.book.authorLine,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: engine.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let duration = engine.duration ?? session.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    deinit {
        progressTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private enum PositionPersistReason {
    case periodic
    case pause
    case seek
    case skip
    case chapterChange
    case background
    case interruption
    case routeChange
}
