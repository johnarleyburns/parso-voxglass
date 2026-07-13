import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var currentSession: PlaybackSession?
    @Published var playbackError: String?

    /// Current playback rate (P0-1). Published so the speed menu tracks it.
    @Published private(set) var playbackRate: Float = PlaybackRate.normal

    /// Sleep timer state (P0-2), mirrored from `sleepTimer` so the UI updates.
    @Published private(set) var sleepMode: SleepTimer.Mode = .off
    @Published private(set) var sleepRemaining: TimeInterval?

    /// Called when a playback position is persisted (e.g. periodic save, chapter end,
    /// finished). Receives the book's UUID and whether it was set as favorite.
    /// Used by the recommendation engine for taste signal capture.
    var onPositionSaved: ((UUID, Bool) -> Void)?
    /// Called when a bookmark is added, so the cloud sync layer can push it.
    var onBookmarkAdded: ((Bookmark) -> Void)?

    var bookmarkStore: BookmarkStore?

    /// Returns the count of live bookmarks for the current book, or nil when no
    /// store is present. Published so the UI can update instantly after an add.
    @Published private(set) var bookmarkCount: Int?

    /// Records wall-clock listened time (§5). Injected by `AppServices`. Logging is
    /// unconditional (privacy-safe, on-device); only viewing stats is Pro-gated.

    /// Records wall-clock listened time (§5). Injected by `AppServices`. Logging is
    /// unconditional (privacy-safe, on-device); only viewing stats is Pro-gated.
    var listeningStatsStore: ListeningStatsStore?
    private var listenedAccumulator: TimeInterval = 0
    private var lastListenTick: Date?

    private let engine: AudioEngine
    private let positionStore: PositionStore
    private let snapshotStore: LastPlaybackSnapshotStore
    private let rateStore: PlaybackRateStore
    private let sleepTimer: SleepTimer
    private var sleepTask: Task<Void, Never>?
    /// Duration of the sleep-timer fade-out; small in tests.
    var fadeOutDuration: TimeInterval = 5
    private let eqSettings = EQSettingsStore()
    let eqPresets = EQPresetStore()
    private var progressTask: Task<Void, Never>?
    private var lastPeriodicSave = Date.distantPast
    private var notificationObservers: [NSObjectProtocol] = []
    private var isHandlingInterruption = false

    /// Cached lock-screen artwork for the current book (P0-4). Built once per
    /// session load — never per 1s tick — keyed by book id.
    private(set) var currentArtwork: MPMediaItemArtwork?
    private var currentArtworkBookID: UUID?
    /// Fetches cover art; injectable so tests can count fetches without network.
    var artworkProvider: (@MainActor (URL) async -> UIImage?)?

    init(
        engine: AudioEngine,
        positionStore: PositionStore,
        snapshotStore: LastPlaybackSnapshotStore = LastPlaybackSnapshotStore(),
        rateStore: PlaybackRateStore = PlaybackRateStore(),
        sleepTimer: SleepTimer = SleepTimer()
    ) {
        self.engine = engine
        self.positionStore = positionStore
        self.snapshotStore = snapshotStore
        self.rateStore = rateStore
        self.sleepTimer = sleepTimer
        self.engine.onPlaybackEnded = { [weak self] in
            Task { @MainActor in
                await self?.advanceAfterChapterEnd()
            }
        }
        self.engine.onItemChanged = { [weak self] in
            Task { @MainActor in
                await self?.handleItemChanged()
            }
        }
        sleepTimer.onFire = { [weak self] in
            self?.handleSleepTimerFired()
        }
        self.engine.configureAudioSession()
        configureRemoteCommands()
        configureNotifications()
        restoreEQ()
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
            applyStoredRate(forBookID: book.book.id)
            updateArtwork(for: book.book)
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
            applyStoredRate(forBookID: book.book.id)
            updateArtwork(for: book.book)
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
               let nextURL = book.chapters[nextIndex].resolvedPlayableURL() {
                engine.preloadNext(url: nextURL)
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
        if let bookID = currentSession?.book.id {
            flushListening(bookID: bookID)
        }
        lastListenTick = nil
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

        engine.cancelPreload()

        await loadChapter(session.chapters[nextIndex], in: session, startTime: 0, shouldPlay: engine.isPlaying)

        // Set up preload for the chapter after next
        let afterNextIndex = nextIndex + 1
        if session.chapters.indices.contains(afterNextIndex),
           let afterNextURL = session.chapters[afterNextIndex].resolvedPlayableURL() {
            engine.preloadNext(url: afterNextURL)
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
            if let bookID = currentSession?.book.id {
                flushListening(bookID: bookID)
            }
            lastListenTick = nil
            Task { await persistCurrentPosition(reason: .background) }
        }
    }

    /// Stops and tears down the current session when its book is deleted (§6),
    /// and clears the restore snapshot so it can't resurface on next launch.
    func stopPlayback(forDeletedBook bookID: UUID) {
        guard currentSession?.book.id == bookID else { return }
        flushListening(bookID: bookID)
        lastListenTick = nil
        engine.pause()
        progressTask?.cancel()
        progressTask = nil
        currentSession = nil
        currentArtwork = nil
        currentArtworkBookID = nil
        snapshotStore.clear()
        updateNowPlayingInfo()
    }

    // MARK: - Playback speed (P0-1, FREE)

    /// Applies the per-book stored rate to the engine and publishes it. Called
    /// after every `engine.load(...)` and on gapless advance.
    private func applyStoredRate(forBookID bookID: UUID) {
        let rate = rateStore.rate(forBookID: bookID)
        playbackRate = rate
        engine.setRate(rate)
    }

    /// Sets the playback rate for the current book (0.5–3.5×) and remembers it.
    func setPlaybackRate(_ rate: Float) {
        let clamped = PlaybackRate.clamp(rate)
        playbackRate = clamped
        engine.setRate(clamped)
        if let bookID = currentSession?.book.id {
            rateStore.setRate(clamped, forBookID: bookID)
        }
        updateNowPlayingInfo()
    }

    // MARK: - Skip intervals (P1-1, FREE)

    /// Symbol-backed skip values and their SF Symbols (back/forward).
    static let allowedSkipBackValues: [Int] = [10, 15, 30, 45, 60]
    static let allowedSkipForwardValues: [Int] = [15, 30, 45, 60, 90]

    nonisolated static func skipBackSymbol(_ seconds: Int) -> String {
        UIImage(systemName: "gobackward.\(seconds)") != nil
            ? "gobackward.\(seconds)"
            : "gobackward.15"
    }

    nonisolated static func skipForwardSymbol(_ seconds: Int) -> String {
        UIImage(systemName: "goforward.\(seconds)") != nil
            ? "goforward.\(seconds)"
            : "goforward.30"
    }

    /// Re-reads the stored skip values and updates `preferredIntervals` on the
    /// remote-command center so they change immediately without re-registration.
    func reconfigureSkipIntervals() {
        let defaults = UserDefaults.standard
        let skipBack = defaults.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil
            ? defaults.integer(forKey: AppPreferencesStore.Keys.skipBackInterval)
            : 15
        let skipForward = defaults.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil
            ? defaults.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)
            : 30

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
    }

    // MARK: - Lock-screen artwork (P0-4, FREE)

    /// Populates `currentArtwork` once per book. Sets a bundled fallback
    /// immediately (so the lock screen is never blank), then, if the book has a
    /// cover URL, fetches the real cover once and re-emits the Now Playing dict.
    /// Never fetches per tick — `updateNowPlayingInfo()` only reads the cache.
    private func updateArtwork(for book: Book) {
        guard currentArtworkBookID != book.id else { return }
        currentArtworkBookID = book.id
        currentArtwork = Self.fallbackArtwork

        guard let coverURL = book.coverURL else { return }
        let provider = artworkProvider ?? { url in await ArtworkService.shared.image(for: url) }
        Task { [weak self] in
            let image = await provider(coverURL)
            guard let self, let image, self.currentArtworkBookID == book.id else { return }
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    /// A static, procedurally-rendered cover used for books without art (or where
    /// the IA placeholder was rejected). Built once, never per tick.
    private static let fallbackArtwork: MPMediaItemArtwork = {
        let size = CGSize(width: 512, height: 512)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.16, green: 0.11, blue: 0.03, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 220, weight: .regular)
            if let symbol = UIImage(systemName: "headphones", withConfiguration: symbolConfig)?
                .withTintColor(UIColor(red: 0.93, green: 0.70, blue: 0.36, alpha: 1), renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2,
                                     y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }()

    // MARK: - Sleep timer (P0-2, FREE)

    /// Arms/cancels the sleep timer. End-of-chapter immediately cancels the
    /// gapless preload so `AVQueuePlayer` cannot advance past the current chapter;
    /// cancelling end-of-chapter re-arms the preload.
    func setSleepTimer(_ mode: SleepTimer.Mode) {
        let wasEndOfChapter = sleepTimer.mode == .endOfChapter
        sleepTimer.arm(mode)
        sleepMode = mode
        sleepRemaining = sleepTimer.remaining

        switch mode {
        case .endOfChapter:
            engine.cancelPreload()
            stopSleepTask()
        case .duration:
            startSleepTask()
        case .off:
            stopSleepTask()
            if wasEndOfChapter, let session = currentSession {
                preloadImmediateNextChapter(in: session)
            }
        }
    }

    private func startSleepTask() {
        sleepTask?.cancel()
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard let self else { return }
                self.sleepTimer.tick()
                self.sleepRemaining = self.sleepTimer.remaining
            }
        }
    }

    private func stopSleepTask() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    private func handleSleepTimerFired() {
        sleepMode = .off
        sleepRemaining = nil
        stopSleepTask()
        Task { @MainActor in await fadeOutAndPause() }
    }

    /// Ramps volume to 0, pauses, then restores volume to 1.0 (or the next play
    /// is silent). Internal so the effectful shell is directly testable.
    func fadeOutAndPause() async {
        let steps = 10
        let startVolume = engine.volume
        for step in 1...steps {
            engine.volume = startVolume * Float(steps - step) / Float(steps)
            try? await Task.sleep(for: .seconds(fadeOutDuration / Double(steps)))
        }
        pause()
        engine.volume = 1.0
    }

    private func preloadImmediateNextChapter(in session: PlaybackSession) {
        let nextIndex = session.chapterIndex + 1
        guard session.chapters.indices.contains(nextIndex),
              let url = session.chapters[nextIndex].resolvedPlayableURL() else { return }
        engine.preloadNext(url: url)
    }

    // MARK: - Bookmarks (P0-3, FREE; bookmark sync = Pro iCloud gate)

    /// The chapter id of the current session, or `nil`.
    var currentChapterID: UUID? { currentSession?.chapter.id }

    /// Adds a bookmark at the current position and published the count.
    func addBookmark(note: String? = nil) {
        guard let store = bookmarkStore, let session = currentSession else { return }
        let pos = engine.currentTime
        let bookmark = Bookmark(
            bookID: session.book.id, chapterID: session.chapter.id,
            position: pos, note: note, createdAt: Date(), updatedAt: Date()
        )
        Task {
            let saved = try? await store.add(bookmark)
            if let saved {
                await refreshBookmarkCount(for: session.book.id)
                onBookmarkAdded?(saved)
            }
        }
    }

    /// Jumps to a bookmark's position, loading a different chapter if needed.
    func jump(to bookmark: Bookmark) async {
        guard let session = currentSession, session.book.id == bookmark.bookID else { return }
        if bookmark.chapterID == session.chapter.id {
            await seek(to: bookmark.position)
        } else if let chapter = session.chapters.first(where: { $0.id == bookmark.chapterID }) {
            let bwc = BookWithChapters(book: session.book, chapters: session.chapters)
            await loadChapter(chapter, in: session, startTime: bookmark.position, shouldPlay: engine.isPlaying)
        }
    }

    func refreshBookmarkCount(for bookID: UUID) async {
        guard let store = bookmarkStore else { return }
        let all = (try? await store.bookmarks(forBookID: bookID)) ?? []
        bookmarkCount = all.isEmpty ? nil : all.count
    }

    // MARK: - Equalizer (Pro, §2)

    var isEQEngaged: Bool {
        engine.isEQEngaged
    }

    var eqGains: [Float] {
        eqSettings.gains
    }

    func setEQEngaged(_ engaged: Bool) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.setEQEngaged(engaged)
        eqSettings.isEngaged = engaged
    }

    func applyEQPreset(_ preset: EQPreset) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.applyEQPreset(preset)
        eqSettings.gains = preset.gains
    }

    func setEQGain(_ gain: Float, at band: Int) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.setEQGain(gain, at: band)
        var gains = eqSettings.gains
        guard band >= 0, band < gains.count else { return }
        gains[band] = gain
        eqSettings.gains = gains
    }

    /// Re-applies persisted gains + engaged-state on launch so the equalizer
    /// survives relaunch. The engine's desired-engaged flag is set now (before any
    /// track loads) so `load(...)` re-attaches the tap automatically.
    private func restoreEQ() {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.setEQGains(eqSettings.gains)
        if eqSettings.isEngaged {
            engine.setEQEngaged(true)
        }
    }

    private func prefetchNextChapter(from book: BookWithChapters, currentChapter: Chapter) {
        prefetchUpcomingChapters(from: book, currentChapter: currentChapter)
    }

    /// Sentinel depth meaning "the rest of the book".
    static let wholeBookPrefetchDepth = 999

    /// Pure resolution of prefetch depth (§3, decision D7): free tier and cellular
    /// (when Wi-Fi-only is on) clamp to 1 so near-gapless is never broken; Pro on
    /// Wi-Fi honors the stored depth.
    static func resolvedPrefetchDepth(isPro: Bool, stored: Int, isCellular: Bool, wifiOnly: Bool) -> Int {
        guard isPro else { return 1 }
        if wifiOnly && isCellular { return 1 }
        return max(1, stored)
    }

    private var storedPrefetchDepth: Int {
        let raw = UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.prefetchDepth)
        return raw <= 0 ? 1 : raw
    }

    private var prefetchWifiOnly: Bool {
        UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.prefetchWifiOnly) == nil
            ? true
            : UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.prefetchWifiOnly)
    }

    private func prefetchUpcomingChapters(from book: BookWithChapters, currentChapter: Chapter) {
        guard let currentIndex = book.chapters.firstIndex(where: { $0.id == currentChapter.id }) else { return }

        let depth = Self.resolvedPrefetchDepth(
            isPro: ProFeature.isEnabled(.prefetchDepth),
            stored: storedPrefetchDepth,
            isCellular: NetworkMonitor.shared.isCellular,
            wifiOnly: prefetchWifiOnly
        )

        var urls: [URL] = []
        var index = currentIndex + 1
        while urls.count < depth && book.chapters.indices.contains(index) {
            let chapter = book.chapters[index]
            if let url = chapter.remoteURL,
               chapter.localURL == nil,
               CachingResourceLoader.isRemoteCacheable(url) {
                urls.append(url)
            }
            index += 1
        }
        guard !urls.isEmpty else { return }
        engine.prefetchIntoCache(urls: urls)
    }

    private func loadChapter(_ chapter: Chapter, in session: PlaybackSession, startTime: TimeInterval, shouldPlay: Bool) async {
        guard let url = chapter.resolvedPlayableURL() else { return }
        do {
            try await engine.load(url: url, startTime: startTime)
            applyStoredRate(forBookID: session.book.id)
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
               let nextURL = session.chapters[nextIndex].resolvedPlayableURL() {
                engine.preloadNext(url: nextURL)
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
        // Re-assert the rate: `defaultRate` carries across the gapless advance, but
        // re-asserting keeps `playbackRate` and Now Playing correct (idempotent).
        applyStoredRate(forBookID: session.book.id)
        startProgressLoop()
        updateNowPlayingInfo()

        // Warm the streaming cache for the chapter after next
        prefetchNextChapter(from: BookWithChapters(book: session.book, chapters: session.chapters),
                            currentChapter: nextChapter)
        // Preload the chapter after next for near-gapless
        preloadChapterAfter(nextChapter, in: session)
    }

    private func preloadChapterAfter(_ chapter: Chapter, in session: PlaybackSession) {
        let nextIndex = session.chapterIndex + 2
        guard session.chapters.indices.contains(nextIndex) else { return }
        let afterNext = session.chapters[nextIndex]
        guard let url = afterNext.resolvedPlayableURL() else { return }
        engine.preloadNext(url: url)
    }

    private func advanceAfterChapterEnd() async {
        guard let session = currentSession else { return }
        mutateSession {
            $0.position = $0.duration ?? engine.currentTime
            $0.isPlaying = false
        }

        // Sleep timer set to "end of chapter": stop here — do not roll into the
        // next chapter. The preload was already cancelled when it was armed.
        if sleepTimer.mode == .endOfChapter {
            engine.pause()
            await persistCurrentPosition(reason: .chapterChange, finished: true)
            sleepTimer.cancel()
            sleepMode = .off
            sleepRemaining = nil
            updateNowPlayingInfo()
            return
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
        accumulateListening()
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

    private func accumulateListening() {
        guard engine.isPlaying, let session = currentSession else {
            lastListenTick = nil
            return
        }
        // Records wall-clock seconds on purpose — do NOT scale by playback rate.
        // "How long you listened" is wall-clock time regardless of speed.
        let now = Date()
        if let last = lastListenTick {
            let elapsed = min(now.timeIntervalSince(last), 2)
            if elapsed > 0 {
                listenedAccumulator += elapsed
            }
        }
        lastListenTick = now

        if listenedAccumulator >= 30 {
            flushListening(bookID: session.book.id)
        }
    }

    private func flushListening(bookID: UUID) {
        let seconds = listenedAccumulator
        listenedAccumulator = 0
        guard seconds > 0, let store = listeningStatsStore else { return }
        Task {
            await store.record(bookID: bookID, seconds: seconds)
        }
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
            if reason == .periodic || finished {
                onPositionSaved?(session.book.id, session.book.isFavorite)
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
                let configured = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil
                    ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)
                    : 30
                let resolved = configured > 0 ? configured : 30
                await self?.skip(by: TimeInterval(resolved))
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                let configured = UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil
                    ? UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval)
                    : 15
                let resolved = configured > 0 ? configured : 15
                await self?.skip(by: -TimeInterval(resolved))
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

        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRate.systemLadder.map { NSNumber(value: $0) }
        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.setPlaybackRate(event.playbackRate)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let session = currentSession else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.nowPlayingInfo(
            session: session,
            currentTime: engine.currentTime,
            duration: engine.duration ?? session.duration,
            rate: engine.rate,
            isPlaying: engine.isPlaying,
            artwork: currentArtwork
        )
    }

    /// Pure builder for the Now Playing dictionary (Step 0b). Extracting it makes
    /// the lock-screen payload — including the playback-rate fields that would
    /// otherwise make the scrubber drift at non-1.0x speed, and the artwork — a
    /// plain assertable dictionary. Sets both `PlaybackRate` (0 when paused so the
    /// system stops advancing the scrubber) and `DefaultPlaybackRate`.
    nonisolated static func nowPlayingInfo(
        session: PlaybackSession,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        rate: Float,
        isPlaying: Bool,
        artwork: MPMediaItemArtwork?
    ) -> [String: Any] {        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.chapter.title,
            MPMediaItemPropertyAlbumTitle: session.book.title,
            MPMediaItemPropertyArtist: session.book.authorLine,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    deinit {
        progressTask?.cancel()
        sleepTask?.cancel()
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
