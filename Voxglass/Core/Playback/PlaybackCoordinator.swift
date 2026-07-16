import Combine
import Foundation
import SwiftUI

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var currentSession: PlaybackSession?
    @Published public var playbackError: String?

    /// Current playback rate (P0-1). Published so the speed menu tracks it.
    @Published public private(set) var playbackRate: Float = PlaybackRate.normal

    /// Sleep timer state (P0-2), mirrored from `sleepTimer` so the UI updates.
    @Published public private(set) var sleepMode: SleepTimer.Mode = .off
    @Published public private(set) var sleepRemaining: TimeInterval?

    /// Called when a playback position is persisted (e.g. periodic save, chapter end,
    /// finished). Receives the book's UUID and whether it was set as favorite.
    /// Used by the recommendation engine for taste signal capture.
    public var onPositionSaved: ((UUID, Bool) -> Void)?
    /// Called when a bookmark is added, so the cloud sync layer can push it.
    public var onBookmarkAdded: ((Bookmark) -> Void)?

    public var bookmarkStore: BookmarkStore?

    /// Returns the count of live bookmarks for the current book, or nil when no
    /// store is present. Published so the UI can update instantly after an add.
    @Published public private(set) var bookmarkCount: Int?

    /// Records wall-clock listened time (§5). Injected by `AppServices`. Logging is
    /// unconditional (privacy-safe, on-device); only viewing stats is Pro-gated.

    /// Records wall-clock listened time (§5). Injected by `AppServices`. Logging is
    /// unconditional (privacy-safe, on-device); only viewing stats is Pro-gated.
    public var listeningStatsStore: ListeningStatsStore?
    private var listenedAccumulator: TimeInterval = 0
    private var lastListenTick: Date?

    private let engine: AudioEngine
    private let positionStore: PositionStore
    private let snapshotStore: LastPlaybackSnapshotStore
    private let rateStore: PlaybackRateStore
    private let sleepTimer: SleepTimer
    private var sleepTask: Task<Void, Never>?
    /// Duration of the sleep-timer fade-out; small in tests.
    public var fadeOutDuration: TimeInterval = 5
    private let eqSettings = EQSettingsStore()
    public let eqPresets = EQPresetStore()
    private var progressTask: Task<Void, Never>?
    private var lastPeriodicSave = Date.distantPast
    private var isHandlingInterruption = false

    private var silenceBoosted = false
    private let isSkipSilenceEnabledKey = AppPreferencesStore.Keys.skipSilenceEnabled

    /// Tracks which book's artwork is currently published, so the cover is fetched
    /// once per session load — never per 1s tick — keyed by book id. The concrete
    /// lock-screen artwork lives in the platform `bridge`.
    private var currentArtworkBookID: UUID?
    /// Fetches cover art as raw image bytes; injectable so tests can count fetches
    /// without network. The app injects a provider backed by `ArtworkService`.
    public var artworkProvider: (@MainActor (URL) async -> Data?)?

    /// The platform boundary (Now Playing, remote commands, artwork, background
    /// tasks). Injected by the app; unit tests use `NoopPlaybackBridge`.
    private let bridge: PlaybackPlatformBridge

    public init(
        engine: AudioEngine,
        positionStore: PositionStore,
        snapshotStore: LastPlaybackSnapshotStore = LastPlaybackSnapshotStore(),
        rateStore: PlaybackRateStore = PlaybackRateStore(),
        sleepTimer: SleepTimer = SleepTimer(),
        bridge: PlaybackPlatformBridge? = nil
    ) {
        self.engine = engine
        self.positionStore = positionStore
        self.snapshotStore = snapshotStore
        self.rateStore = rateStore
        self.sleepTimer = sleepTimer
        self.bridge = bridge ?? NoopPlaybackBridge()
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
        self.engine.onSilenceChanged = { [weak self] isSilent in
            self?.handleSilenceChanged(isSilent)
        }
        sleepTimer.onFire = { [weak self] in
            self?.handleSleepTimerFired()
        }
        self.engine.configureAudioSession()
        self.bridge.onRemoteCommand = { [weak self] command in
            self?.handleRemoteCommand(command)
        }
        reconfigureSkipIntervals()
        restoreEQ()
    }

    public func restoreLatestSession(from books: [BookWithChapters]) async {
        do {
            let storedPosition = try await positionStore.latestPosition()
            let snapshotPosition = snapshotStore.latest()
            let latest = Self.preferredPosition(row: storedPosition, snapshot: snapshotPosition)

            guard let latest else { return }
            guard let book = books.first(where: { $0.book.id == latest.bookID }),
                  let chapter = book.chapters.first(where: { $0.id == latest.chapterID }),
                  let url = chapter.resolvedPlayableURL() else {
                playbackError = "Couldn't restore your last listening session."
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

    /// Replays every UserDefaults snapshot into SQLite (launch reconcile). LWW on
    /// `updatedAt`, with the durable-store tie-break: for the same (book, chapter)
    /// a snapshot more than 2 s ahead of the row wins even when the row's
    /// timestamp is newer — a lost SQLite write is exactly what this defends
    /// against. FK failures (book since deleted) are skipped silently.
    public func reconcileSnapshots() async {
        for snapshot in snapshotStore.all() {
            do {
                let row = try await positionStore.position(
                    for: snapshot.bookID, chapterID: snapshot.chapterID
                )
                if Self.snapshotWins(row: row, snapshot: snapshot) {
                    try await positionStore.save(snapshot)
                }
            } catch {
                continue
            }
        }
    }

    /// Pure tie-break between a SQLite row and a UserDefaults snapshot for the
    /// same (book, chapter): the snapshot wins on newer timestamp, or whenever it
    /// is more than 2 s ahead of the row.
    public static func snapshotWins(row: PlaybackPosition?, snapshot: PlaybackPosition) -> Bool {
        guard let row else { return true }
        if snapshot.updatedAt > row.updatedAt { return true }
        return snapshot.position > row.position + 2
    }

    /// Merges the SQLite row and the snapshot for restore/resume: same
    /// (book, chapter) uses the tie-break; otherwise the newer of the two.
    public static func preferredPosition(
        row: PlaybackPosition?,
        snapshot: PlaybackPosition?
    ) -> PlaybackPosition? {
        switch (row, snapshot) {
        case (nil, nil): return nil
        case (let row?, nil): return row
        case (nil, let snapshot?): return snapshot
        case (let row?, let snapshot?):
            if row.bookID == snapshot.bookID && row.chapterID == snapshot.chapterID {
                return Self.snapshotWins(row: row, snapshot: snapshot) ? snapshot : row
            }
            return snapshot.updatedAt > row.updatedAt ? snapshot : row
        }
    }

    public func play(_ book: BookWithChapters, chapter requestedChapter: Chapter? = nil) async {
        let chapter: Chapter
        let startTime: TimeInterval
        var savedDuration: TimeInterval?

        if let requestedChapter {
            chapter = requestedChapter
            let saved = try? await positionStore.position(for: book.book.id, chapterID: requestedChapter.id)
            startTime = saved?.position ?? 0
            savedDuration = saved?.duration
        } else {
            let row = try? await positionStore.latestPosition(forBookID: book.book.id)
            let saved = Self.preferredPosition(
                row: row ?? nil,
                snapshot: snapshotStore.position(forBookID: book.book.id)
            )
            guard let target = Self.resolveResume(chapters: book.chapters, saved: saved) else { return }
            chapter = target.chapter
            startTime = target.startTime
            if saved?.chapterID == target.chapter.id {
                savedDuration = saved?.duration
            }
        }

        guard let playableURL = chapter.resolvedPlayableURL() else {
            playbackError = AudioEngineError.missingPlayableURL.localizedDescription
            return
        }

        do {
            try await engine.load(url: playableURL, startTime: startTime)
            applyStoredRate(forBookID: book.book.id)
            updateArtwork(for: book.book)
            engine.play()

            currentSession = PlaybackSession(
                book: book.book,
                chapters: book.chapters,
                chapter: chapter,
                position: startTime,
                duration: savedDuration ?? chapter.duration ?? engine.duration,
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

    // MARK: - Resume resolution (Phase 1, FREE)

    /// The chapter + offset a book should resume at. Pure result type so the
    /// resolver can be unit-tested with zero I/O (cf. `startDecision`).
    public struct ResumeTarget: Equatable {
        let chapter: Chapter
        let startTime: TimeInterval
    }

    /// Pure resume resolver. Given a book's chapters and the last saved position,
    /// decides which chapter to open and at what offset. Never touches the engine
    /// or the store, so every rule is directly assertable.
    public static func resolveResume(
        chapters: [Chapter],
        saved: PlaybackPosition?,
        startFloor: TimeInterval = 5,
        endEpsilon: TimeInterval = 5
    ) -> ResumeTarget? {
        guard let first = chapters.first else { return nil }

        guard let saved,
              let savedIndex = chapters.firstIndex(where: { $0.id == saved.chapterID }) else {
            return ResumeTarget(chapter: first, startTime: 0)
        }

        let chapter = chapters[savedIndex]
        let duration = saved.duration ?? chapter.duration
        let isFinished = saved.isFinished
            || (duration.map { $0 > 0 && saved.position >= $0 - endEpsilon } ?? false)

        if isFinished {
            let nextIndex = savedIndex + 1
            if chapters.indices.contains(nextIndex) {
                return ResumeTarget(chapter: chapters[nextIndex], startTime: 0)
            }
            return ResumeTarget(chapter: first, startTime: 0)
        }

        if saved.position < startFloor {
            return ResumeTarget(chapter: chapter, startTime: 0)
        }

        return ResumeTarget(chapter: chapter, startTime: saved.position)
    }


    public func togglePlayPause() {
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

    public func pause() {
        guard currentSession != nil else { return }
        if let bookID = currentSession?.book.id {
            flushListening(bookID: bookID)
        }
        lastListenTick = nil
        resetSilenceBoost()
        saveCurrentSnapshot()
        engine.pause()
        mutateSession {
            if engine.isReady {
                $0.position = engine.currentTime
            }
            $0.duration = engine.duration ?? $0.duration
            $0.isPlaying = false
        }
        Task { await persistCurrentPosition(reason: .pause) }
        updateNowPlayingInfo()
    }

    public func seek(to position: TimeInterval) async {
        guard currentSession != nil else { return }
        resetSilenceBoost()
        await engine.seek(to: position)
        mutateSession {
            $0.position = PlaybackMath.clampedPosition(position, duration: $0.duration)
            $0.duration = engine.duration ?? $0.duration
        }
        await persistCurrentPosition(reason: .seek)
        updateNowPlayingInfo()
    }

    public func skip(by delta: TimeInterval) async {
        guard let currentSession else { return }
        await seek(to: currentSession.position + delta)
    }

    public func skipToNextChapter() async {
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

    public func skipToPreviousChapter() async {
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

    // MARK: - Skip silence (P2-2, Pro)

    private var isSkipSilenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: isSkipSilenceEnabledKey)
    }

    private var isVolumeNormalizationEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled) != nil
            ? UserDefaults.standard.bool(forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled)
            : true
    }

    public func setVolumeNormalizationEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AppPreferencesStore.Keys.volumeNormalizationEnabled)
    }

    private func handleSilenceChanged(_ isSilent: Bool) {
        guard isSkipSilenceEnabled else { return }
        if isSilent && !silenceBoosted {
            silenceBoosted = true
            let boost = min(playbackRate * 1.5, PlaybackRate.maximum)
            engine.setRate(boost)
        } else if !isSilent && silenceBoosted {
            silenceBoosted = false
            engine.setRate(playbackRate)
        }
    }

    private func resetSilenceBoost() {
        silenceBoosted = false
    }

    public func handleScenePhase(_ phase: ScenePhase) {
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
    public func stopPlayback(forDeletedBook bookID: UUID) {
        guard currentSession?.book.id == bookID else { return }
        flushListening(bookID: bookID)
        lastListenTick = nil
        resetSilenceBoost()
        engine.pause()
        progressTask?.cancel()
        progressTask = nil
        currentSession = nil
        currentArtworkBookID = nil
        bridge.setArtwork(nil)
        snapshotStore.clear(bookID: bookID)
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
    public func setPlaybackRate(_ rate: Float) {
        let clamped = PlaybackRate.clamp(rate)
        playbackRate = clamped
        resetSilenceBoost()
        engine.setRate(clamped)
        if let bookID = currentSession?.book.id {
            rateStore.setRate(clamped, forBookID: bookID)
        }
        updateNowPlayingInfo()
    }

    // MARK: - Skip intervals (P1-1, FREE)

    /// Symbol-backed skip values (back/forward). The SF-Symbol *names* for these
    /// live in the app layer (`SkipSymbol`), since resolving them needs UIKit.
    public static let allowedSkipBackValues: [Int] = [10, 15, 30, 45, 60]
    public static let allowedSkipForwardValues: [Int] = [15, 30, 45, 60, 90]

    /// The stored skip-backward interval (seconds), defaulting to 15.
    public var resolvedSkipBackwardInterval: Int {
        let defaults = UserDefaults.standard
        let v = defaults.object(forKey: AppPreferencesStore.Keys.skipBackInterval) != nil
            ? defaults.integer(forKey: AppPreferencesStore.Keys.skipBackInterval)
            : 15
        return v > 0 ? v : 15
    }

    /// The stored skip-forward interval (seconds), defaulting to 30.
    public var resolvedSkipForwardInterval: Int {
        let defaults = UserDefaults.standard
        let v = defaults.object(forKey: AppPreferencesStore.Keys.skipForwardInterval) != nil
            ? defaults.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)
            : 30
        return v > 0 ? v : 30
    }

    /// Re-reads the stored skip values and pushes them to the platform bridge so
    /// the lock-screen skip intervals change immediately without re-registration.
    public func reconfigureSkipIntervals() {
        bridge.setSkipIntervals(
            backward: resolvedSkipBackwardInterval,
            forward: resolvedSkipForwardInterval
        )
    }

    // MARK: - Lock-screen artwork (P0-4, FREE)

    /// Populates `currentArtwork` once per book. Sets a bundled fallback
    /// immediately (so the lock screen is never blank), then, if the book has a
    /// cover URL, fetches the real cover once and re-emits the Now Playing dict.
    /// Never fetches per tick — `updateNowPlayingInfo()` only reads the cache.
    private func updateArtwork(for book: Book) {
        guard currentArtworkBookID != book.id else { return }
        currentArtworkBookID = book.id
        // nil tells the bridge to show its bundled fallback immediately, so the
        // lock screen is never blank while the real cover loads.
        bridge.setArtwork(nil)

        guard let coverURL = book.coverURL, let provider = artworkProvider else { return }
        Task { [weak self] in
            let data = await provider(coverURL)
            guard let self, let data, self.currentArtworkBookID == book.id else { return }
            self.bridge.setArtwork(data)
            self.updateNowPlayingInfo()
        }
    }

    // MARK: - Sleep timer (P0-2, FREE)

    /// Arms/cancels the sleep timer. End-of-chapter immediately cancels the
    /// gapless preload so `AVQueuePlayer` cannot advance past the current chapter;
    /// cancelling end-of-chapter re-arms the preload.
    public func setSleepTimer(_ mode: SleepTimer.Mode) {
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
    public func fadeOutAndPause() async {
        let steps = 10
        resetSilenceBoost()
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
    public var currentChapterID: UUID? { currentSession?.chapter.id }

    /// Adds a bookmark at the current position and published the count.
    public func addBookmark(note: String? = nil) {
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
    public func jump(to bookmark: Bookmark) async {
        guard let session = currentSession, session.book.id == bookmark.bookID else { return }
        if bookmark.chapterID == session.chapter.id {
            await seek(to: bookmark.position)
        } else if let chapter = session.chapters.first(where: { $0.id == bookmark.chapterID }) {
            let bwc = BookWithChapters(book: session.book, chapters: session.chapters)
            await loadChapter(chapter, in: session, startTime: bookmark.position, shouldPlay: engine.isPlaying)
        }
    }

    public func refreshBookmarkCount(for bookID: UUID) async {
        guard let store = bookmarkStore else { return }
        let all = (try? await store.bookmarks(forBookID: bookID)) ?? []
        bookmarkCount = all.isEmpty ? nil : all.count
    }

    // MARK: - Equalizer (Pro, §2)

    public var isEQEngaged: Bool {
        engine.isEQEngaged
    }

    public var eqGains: [Float] {
        eqSettings.gains
    }

    public func setEQEngaged(_ engaged: Bool) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.setEQEngaged(engaged)
        eqSettings.isEngaged = engaged
    }

    public func applyEQPreset(_ preset: EQPreset) {
        guard ProFeature.isEnabled(.eq) else { return }
        engine.applyEQPreset(preset)
        eqSettings.gains = preset.gains
    }

    public func setEQGain(_ gain: Float, at band: Int) {
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
    public static let wholeBookPrefetchDepth = 999

    /// Pure resolution of prefetch depth (§3, decision D7): free tier and cellular
    /// (when Wi-Fi-only is on) clamp to 1 so near-gapless is never broken; Pro on
    /// Wi-Fi honors the stored depth.
    public static func resolvedPrefetchDepth(isPro: Bool, stored: Int, isCellular: Bool, wifiOnly: Bool) -> Int {
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
            resetSilenceBoost()
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
        resetSilenceBoost()
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

        // Anti-zero guard (Phase 1, problem 3): never write a bogus position over a
        // good row in the window after load() and before the item is ready. A
        // finish write is exempt (it deliberately records the chapter end), as is
        // an explicit seek (the user chose that position, including 0).
        let position = engine.currentTime
        if !finished, reason != .seek, (!engine.isReady || position <= 0) {
            return
        }

        let playbackPosition = PlaybackPosition(
            bookID: session.book.id,
            chapterID: session.chapter.id,
            position: position,
            duration: engine.duration ?? session.duration,
            updatedAt: Date(),
            isFinished: finished
        )
        snapshotStore.save(playbackPosition)
        do {
            try await positionStore.save(playbackPosition)
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
        // Same anti-zero guard: the 1 Hz snapshot must not clobber a good slot with
        // a not-ready 0.
        guard engine.isReady, engine.currentTime > 0 else { return }
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

    // MARK: - Remote commands (routed through the platform bridge)

    /// Handles a remote/lock-screen command forwarded by the platform bridge.
    private func handleRemoteCommand(_ command: PlaybackRemoteCommand) {
        switch command {
        case .play:
            resume()
        case .pause:
            pause()
        case .togglePlayPause:
            togglePlayPause()
        case .skipForward:
            let seconds = resolvedSkipForwardInterval
            Task { await skip(by: TimeInterval(seconds)) }
        case .skipBackward:
            let seconds = resolvedSkipBackwardInterval
            Task { await skip(by: -TimeInterval(seconds)) }
        case .nextChapter:
            Task { await skipToNextChapter() }
        case .previousChapter:
            Task { await skipToPreviousChapter() }
        case .seek(let position):
            Task { await seek(to: position) }
        case .setRate(let rate):
            setPlaybackRate(rate)
        }
    }

    /// Resumes playback (remote "play"): starts the engine, marks the session
    /// playing, restarts the progress loop, and refreshes Now Playing.
    private func resume() {
        engine.play()
        mutateSession { $0.isPlaying = true }
        startProgressLoop()
        updateNowPlayingInfo()
    }

    // MARK: - App lifecycle hooks (called by the platform bridge)

    /// The last synchronous main-thread moment before background/kill — persist a
    /// SIGKILL-surviving snapshot. No async hop on purpose.
    public func handleWillResignActive() {
        saveCurrentSnapshot()
    }

    /// On entering the background (or terminating): the snapshot write is
    /// synchronous, and the SQLite flush is wrapped in a background-task assertion
    /// (via the bridge) so the enqueued write still runs if the OS kills the app.
    public func handleWillBackgroundOrTerminate() {
        saveCurrentSnapshot()
        bridge.runWithBackgroundTask { [weak self] in
            await self?.persistCurrentPosition(reason: .background)
        }
    }

    // MARK: - Audio interruptions & route changes (called by the platform bridge)

    /// An audio interruption began (call, Siri, another app). Pause and persist.
    public func handleAudioInterruptionBegan() {
        isHandlingInterruption = engine.isPlaying
        saveCurrentSnapshot()
        engine.pause()
        mutateSession {
            if engine.isReady {
                $0.position = engine.currentTime
            }
            $0.isPlaying = false
        }
        Task { [weak self] in
            await self?.persistCurrentPosition(reason: .interruption)
            self?.updateNowPlayingInfo()
        }
    }

    /// An audio interruption ended. Resume only if we were the one interrupted.
    public func handleAudioInterruptionEnded() {
        guard isHandlingInterruption else { return }
        isHandlingInterruption = false
        engine.play()
        mutateSession { $0.isPlaying = true }
        startProgressLoop()
        updateNowPlayingInfo()
    }

    /// An audio route change (e.g. headphones unplugged) — persist position.
    public func handleAudioRouteChanged() {
        Task { [weak self] in
            await self?.persistCurrentPosition(reason: .routeChange)
        }
    }

    private func updateNowPlayingInfo() {
        guard let session = currentSession else {
            bridge.updateNowPlaying(nil)
            return
        }
        bridge.updateNowPlaying(Self.nowPlayingInfo(
            session: session,
            currentTime: engine.currentTime,
            duration: engine.duration ?? session.duration,
            rate: engine.rate,
            isPlaying: engine.isPlaying
        ))
    }

    /// Pure builder for the Now Playing payload (Step 0b). Keeping it a plain
    /// `NowPlayingInfo` value (no MediaPlayer types) makes the lock-screen payload
    /// directly assertable and host-testable. The app's bridge maps it to
    /// `MPNowPlayingInfoCenter`. `reportedRate` is 0 when paused so the system
    /// stops advancing the scrubber; `defaultRate` carries the book's rate.
    public nonisolated static func nowPlayingInfo(
        session: PlaybackSession,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        rate: Float,
        isPlaying: Bool
    ) -> NowPlayingInfo {
        NowPlayingInfo(
            title: session.chapter.title,
            albumTitle: session.book.title,
            artist: session.book.authorLine,
            elapsed: currentTime,
            duration: duration,
            reportedRate: isPlaying ? Double(rate) : 0.0,
            defaultRate: Double(rate)
        )
    }

    deinit {
        progressTask?.cancel()
        sleepTask?.cancel()
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
