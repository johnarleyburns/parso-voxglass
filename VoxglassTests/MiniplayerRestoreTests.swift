import Testing
import Foundation
@testable import VoxglassCore

/// Miniplayer launch-restore (docs/MINIPLAYER_RESTORE_PLAN.md). Restore is a
/// presentation concern: `restorePresentedSession` rebuilds the paused session
/// from persisted metadata without touching the engine; the engine loads lazily
/// on the first play press. Asserted against the `FakeAudioEngine` call log +
/// a real SQLite position store, following `PlaybackResumeTests`.
@MainActor
@Suite struct MiniplayerRestoreTests {

    private struct Harness {
        let coordinator: PlaybackCoordinator
        let engine: FakeAudioEngine
        let store: SQLitePositionStore
        let db: AppDatabase
        let defaults: UserDefaults
        let bridge: NoopPlaybackBridge
    }

    private func makeChapters(_ count: Int, bookID: UUID = UUID(), duration: TimeInterval? = 100) -> [Chapter] {
        (0..<count).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: duration,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
    }

    private func makeHarness(
        db existingDB: AppDatabase? = nil,
        defaults existingDefaults: UserDefaults? = nil
    ) -> Harness {
        let db = existingDB ?? AppDatabase.makeTemporaryDatabase(named: "mini-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLitePositionStore(database: db)
        let defaults = existingDefaults ?? UserDefaults(suiteName: "mini-\(UUID().uuidString)")!
        let bridge = NoopPlaybackBridge()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults),
            bridge: bridge
        )
        return Harness(coordinator: coordinator, engine: engine, store: store, db: db, defaults: defaults, bridge: bridge)
    }

    private func seedBook(in db: AppDatabase, chapters: [Chapter], title: String = "Book") async throws {
        let bookID = chapters.first!.bookID
        let sourceID = UUID()
        let now = Date().timeIntervalSince1970
        try await db.execute(
            "INSERT INTO sources (id, kind, title, url, created_at) VALUES (?, ?, ?, ?, ?)",
            [.string(sourceID.uuidString), .string(SourceKind.localFiles.rawValue), .string("S"), .null, .double(now)]
        )
        try await db.execute("""
        INSERT INTO books (id, title, authors_json, summary, source_id, cover_url, created_at, updated_at, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .string(bookID.uuidString), .string(title), .string("[]"), .null,
            .string(sourceID.uuidString), .null, .double(now), .double(now), .bool(false)
        ])
        for chapter in chapters {
            try await db.execute("""
            INSERT INTO chapters (id, book_id, title, sort_key, chapter_index, duration_seconds, remote_url, local_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .string(chapter.id.uuidString), .string(bookID.uuidString), .string(chapter.title),
                .string(chapter.sortKey), .int(Int64(chapter.index)),
                chapter.duration.map { .double($0) } ?? .null, .null,
                chapter.localURL.map { .string($0.absoluteString) } ?? .null
            ])
        }
    }

    private func makeBook(chapters: [Chapter], title: String = "Book") -> BookWithChapters {
        BookWithChapters(
            book: Book(id: chapters.first!.bookID, title: title, authors: ["A"], sourceID: UUID()),
            chapters: chapters
        )
    }

    /// Lets the fire-and-forget MainActor tasks spawned by togglePlayPause /
    /// remote resume run to completion.
    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - §5.1 Engine-free presented restore

    @Test func restorePresentedSessionPresentsPausedSessionWithoutTouchingEngine() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[1].id,
            position: 42, duration: 100
        ))

        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        #expect(h.coordinator.currentSession?.book.id == chapters[0].bookID)
        #expect(h.coordinator.currentSession?.chapter.id == chapters[1].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (42)) <= 0.001)
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(h.engine.loadCalls.isEmpty)  // Presented restore must never call engine.load — the paused miniplayer needs only metadata
        #expect(h.coordinator.playbackError == nil)
    }

    @Test func restorePresentedSessionWithNothingRestorableStaysEmptyWithoutError() async {
        let h = makeHarness()
        await h.coordinator.restorePresentedSession(from: [])
        #expect(h.coordinator.currentSession == nil)
        #expect(h.coordinator.playbackError == nil)
    }

    // MARK: - §5.2 Finished latest row advances (RC3)

    @Test func restoreAfterFinishedLatestRowPresentsNextChapterAtZero() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 100, duration: 100, isFinished: true
        ))

        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        #expect(h.coordinator.currentSession?.chapter.id == chapters[1].id)  // A finished newest row must restore the *next* chapter, not the finished one at its end
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (0)) <= 0.001)
        #expect(h.coordinator.playbackError == nil)
    }

    // MARK: - §5.3 Stale chapter id falls back, no error banner

    @Test func restoreWithStaleChapterIDFallsBackToBookStartWithoutError() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        // A row whose chapter no longer exists (FK-free direct snapshot write).
        LastPlaybackSnapshotStore(defaults: h.defaults).save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: UUID(), position: 40, duration: 100
        ))

        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        #expect(h.coordinator.currentSession?.chapter.id == chapters[0].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (0)) <= 0.001)
        #expect(h.coordinator.playbackError == nil)  // Degrade to book start — never a dead-end error
    }

    // MARK: - §5.4 First play lazily loads at the presented position

    @Test func firstTogglePlayLoadsEngineAtPresentedPositionThenSecondTogglePausesWithoutReload() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[1].id,
            position: 42, duration: 100
        ))
        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])
        #expect(h.engine.loadCalls.isEmpty)

        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(h.engine.loadCalls.count == 1)
        #expect(h.engine.loadCalls.last?.url == chapters[1].localURL)
        #expect(abs((h.engine.loadCalls.last?.startTime ?? -1) - (42)) <= 0.001)
        #expect(h.engine.isPlaying)
        #expect(h.coordinator.currentSession?.isPlaying == true)

        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(!(h.engine.isPlaying))
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(h.engine.loadCalls.count == 1)  // Pause and later resumes must not reload the engine
    }

    // MARK: - §5.5 Load failure keeps the session (miniplayer must not vanish)

    @Test func engineLoadFailureOnFirstPlayKeepsSessionAndAllowsRetry() async throws {
        let h = makeHarness()
        let chapters = makeChapters(2)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 30, duration: 100
        ))
        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        h.engine.loadError = URLError(.notConnectedToInternet)
        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(h.coordinator.playbackError != nil)
        #expect(h.coordinator.currentSession != nil)  // The presented session must survive a failed lazy load
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(!(h.engine.isPlaying))

        h.engine.loadError = nil
        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(h.engine.isPlaying)  // Retry after a failed load must work
        #expect(h.engine.loadCalls.count == 2)
        #expect(abs((h.engine.loadCalls.last?.startTime ?? -1) - (30)) <= 0.001)
    }

    // MARK: - §5.6 Seek before first play

    @Test func seekBeforeFirstPlayMovesPresentedPositionPersistsAndLoadsAtNewOffset() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[1].id,
            position: 42, duration: 100
        ))
        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        await h.coordinator.seek(to: 77)

        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (77)) <= 0.001)
        #expect(!(h.engine.calls.contains(.seek(77))))  // No engine.seek while unloaded
        let persisted = try await h.store.position(for: chapters[0].bookID, chapterID: chapters[1].id)
        #expect(abs((persisted?.position ?? -1) - (77)) <= 0.001)  // A pre-play seek must land durably while unloaded

        h.coordinator.togglePlayPause()
        await drainMainQueue()

        #expect(abs((h.engine.loadCalls.last?.startTime ?? -1) - (77)) <= 0.001)  // The lazy load must pick up the seeked offset
    }

    // MARK: - §5.7 Cloud-pull refresh

    @Test func cloudPullRefreshAdoptsNewerPositionWhileUnplayed() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[1].id,
            position: 42, duration: 100, updatedAt: Date(timeIntervalSinceNow: -60)
        ))
        let book = makeBook(chapters: chapters)
        await h.coordinator.restorePresentedSession(from: [book])
        #expect(h.coordinator.currentSession?.chapter.id == chapters[1].id)

        // The iCloud pull upserts a newer position from another device.
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[2].id,
            position: 10, duration: 100, updatedAt: Date()
        ))
        await h.coordinator.refreshPresentedSessionAfterCloudPull(from: [book])

        #expect(h.coordinator.currentSession?.chapter.id == chapters[2].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (10)) <= 0.001)
        #expect(h.coordinator.currentSession?.isPlaying == false)
        #expect(h.engine.loadCalls.isEmpty)
    }

    @Test func cloudPullRefreshNoopsOnceEngineIsLoaded() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[1].id,
            position: 42, duration: 100, updatedAt: Date(timeIntervalSinceNow: -60)
        ))
        let book = makeBook(chapters: chapters)
        await h.coordinator.restorePresentedSession(from: [book])
        h.coordinator.togglePlayPause()
        await drainMainQueue()
        h.coordinator.togglePlayPause()   // pause again — engine stays loaded
        await drainMainQueue()

        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[2].id,
            position: 10, duration: 100, updatedAt: Date()
        ))
        await h.coordinator.refreshPresentedSessionAfterCloudPull(from: [book])

        #expect(h.coordinator.currentSession?.chapter.id == chapters[1].id)  // Local activity wins: once the engine loaded, the pull is presentation-irrelevant
    }

    @Test func cloudPullRefreshPresentsSessionOnFreshInstallOncePullLands() async throws {
        let h = makeHarness()
        let chapters = makeChapters(2)
        try await seedBook(in: h.db, chapters: chapters)
        let book = makeBook(chapters: chapters)
        await h.coordinator.restorePresentedSession(from: [book])
        #expect(h.coordinator.currentSession == nil)

        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 55, duration: 100
        ))
        await h.coordinator.refreshPresentedSessionAfterCloudPull(from: [book])

        #expect(h.coordinator.currentSession?.chapter.id == chapters[0].id)
        #expect(abs((h.coordinator.currentSession?.position ?? -1) - (55)) <= 0.001)
    }

    // MARK: - §5.8 Auto-advance writes a durable row for the new chapter (RC4)

    @Test func autoAdvanceWritesDurableRowSoRestoreLandsOnNewChapter() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        let book = makeBook(chapters: chapters)

        await h.coordinator.play(book)
        #expect(h.coordinator.currentSession?.chapter.id == chapters[0].id)

        // Gapless advance at the chapter boundary.
        h.engine.currentTime = 100
        h.engine.duration = 100
        h.engine.fireItemChanged()
        await drainMainQueue()
        #expect(h.coordinator.currentSession?.chapter.id == chapters[1].id)

        let newRow = try await h.store.position(for: chapters[0].bookID, chapterID: chapters[1].id)
        #expect(newRow != nil)  // The new chapter must have a durable row immediately after the advance
        #expect(abs((newRow?.position ?? -1) - (0)) <= 0.001)
        #expect(newRow?.isFinished == false)

        // Force quit + relaunch: a fresh coordinator over the same stores.
        let relaunch = makeHarness(db: h.db, defaults: h.defaults)
        await relaunch.coordinator.restorePresentedSession(from: [book])
        #expect(relaunch.coordinator.currentSession?.chapter.id == chapters[1].id)  // A force quit seconds after an auto-advance must restore the new chapter (RC4)
        #expect(abs((relaunch.coordinator.currentSession?.position ?? -1) - (0)) <= 0.001)
        #expect(relaunch.engine.loadCalls.isEmpty)
    }

    @Test func manualChapterSkipWritesDurableRowForNewChapter() async throws {
        let h = makeHarness()
        let chapters = makeChapters(3)
        try await seedBook(in: h.db, chapters: chapters)
        let book = makeBook(chapters: chapters)

        await h.coordinator.play(book)
        h.engine.currentTime = 0   // freshly loaded next chapter reports 0
        await h.coordinator.skipToNextChapter()

        let newRow = try await h.store.position(for: chapters[0].bookID, chapterID: chapters[1].id)
        #expect(newRow != nil)  // Manual skips must not leave the previous chapter as the newest row
        #expect(abs((newRow?.position ?? -1) - (0)) <= 0.001)
        #expect(newRow?.isFinished == false)
    }

    // MARK: - §5.9 Now Playing while unloaded

    @Test func nowPlayingInfoUsesSessionPositionWhileUnloaded() async throws {
        let h = makeHarness()
        let chapters = makeChapters(2)
        try await seedBook(in: h.db, chapters: chapters)
        try await h.store.save(PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 42, duration: 100
        ))
        h.engine.currentTime = 0

        await h.coordinator.restorePresentedSession(from: [makeBook(chapters: chapters)])

        #expect(abs((h.bridge.lastNowPlaying?.elapsed ?? -1) - (42)) <= 0.001)  // Lock screen must match the miniplayer, not the unloaded engine's 0
        #expect(h.bridge.lastNowPlaying?.reportedRate ?? -1 == 0)  // Presented restore is paused — the scrubber must not advance
    }
}
