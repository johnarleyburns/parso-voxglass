import XCTest
@testable import VoxglassCore

/// Phase 1 — resume where you actually were. The pure `resolveResume` rules are
/// asserted with zero I/O; the through-the-coordinator cases run against the
/// `FakeAudioEngine` + a real SQLite position store.
@MainActor
final class PlaybackResumeTests: XCTestCase {

    private func makeChapters(_ count: Int, bookID: UUID = UUID(), duration: TimeInterval? = 100) -> [Chapter] {
        (0..<count).map { index in
            Chapter(
                bookID: bookID, title: "Ch \(index)", index: index, duration: duration,
                localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-\(index).mp3")
            )
        }
    }

    // MARK: - Pure resolver

    func testResolveResumeReturnsSavedChapterAtSavedOffset() {
        let chapters = makeChapters(3)
        let saved = PlaybackPosition(
            bookID: chapters[1].bookID, chapterID: chapters[1].id,
            position: 60, duration: 100
        )
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[1].id)
        XCTAssertEqual(target?.startTime ?? -1, 60, accuracy: 0.001)
    }

    func testResolveResumeWithNoSavedPositionStartsAtChapterOne() {
        let chapters = makeChapters(3)
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: nil)
        XCTAssertEqual(target?.chapter.id, chapters[0].id)
        XCTAssertEqual(target?.startTime ?? -1, 0, accuracy: 0.001)
    }

    func testResolveResumeWithMissingChapterFallsBackToChapterOne() {
        let chapters = makeChapters(3)
        let saved = PlaybackPosition(bookID: chapters[0].bookID, chapterID: UUID(), position: 40)
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[0].id)
        XCTAssertEqual(target?.startTime ?? -1, 0, accuracy: 0.001)
    }

    func testResolveResumeFinishedChapterAdvancesToNextAtZero() {
        let chapters = makeChapters(3)
        let saved = PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 100, duration: 100, isFinished: true
        )
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[1].id)
        XCTAssertEqual(target?.startTime ?? -1, 0, accuracy: 0.001)
    }

    func testResolveResumeFinishedLastChapterRestartsAtBookStart() {
        let chapters = makeChapters(3)
        let saved = PlaybackPosition(
            bookID: chapters[2].bookID, chapterID: chapters[2].id,
            position: 100, duration: 100, isFinished: true
        )
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[0].id)
        XCTAssertEqual(target?.startTime ?? -1, 0, accuracy: 0.001)
    }

    func testResolveResumeWithinEndEpsilonTreatsChapterAsFinished() {
        let chapters = makeChapters(2)
        let saved = PlaybackPosition(
            bookID: chapters[0].bookID, chapterID: chapters[0].id,
            position: 97, duration: 100, isFinished: false
        )
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[1].id, "Within endEpsilon of the end advances to next")
    }

    func testResolveResumeBelowFloorStartsChapterAtZero() {
        let chapters = makeChapters(2)
        let saved = PlaybackPosition(
            bookID: chapters[1].bookID, chapterID: chapters[1].id,
            position: 3, duration: 100
        )
        let target = PlaybackCoordinator.resolveResume(chapters: chapters, saved: saved)
        XCTAssertEqual(target?.chapter.id, chapters[1].id)
        XCTAssertEqual(target?.startTime ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Through the coordinator

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine, SQLitePositionStore, AppDatabase) {
        let db = AppDatabase.makeTemporaryDatabase(named: "resume-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let store = SQLitePositionStore(database: db)
        let defaults = UserDefaults(suiteName: "resume-\(UUID().uuidString)")!
        let coordinator = PlaybackCoordinator(
            engine: engine,
            positionStore: store,
            snapshotStore: LastPlaybackSnapshotStore(defaults: defaults),
            rateStore: PlaybackRateStore(defaults: defaults)
        )
        return (coordinator, engine, store, db)
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

    func testPlayBookWithoutChapterResumesLastPlayedChapter() async throws {
        let (coordinator, _, store, db) = makeCoordinator()
        let bookID = UUID()
        let chapters = makeChapters(6, bookID: bookID)
        try await seedBook(in: db, chapters: chapters)
        try await store.save(PlaybackPosition(
            bookID: bookID, chapterID: chapters[4].id,
            position: 750, duration: 100 * 60
        ))

        let book = BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chapters)
        await coordinator.play(book)

        XCTAssertEqual(coordinator.currentSession?.chapter.id, chapters[4].id,
                       "Play with no chapter must resume the last played chapter, not chapter 1")
        XCTAssertEqual(coordinator.currentSession?.position ?? -1, 750, accuracy: 0.001)
    }

    func testPlayBookResumesAtSavedOffsetNotChapterZero() async throws {
        let (coordinator, engine, store, db) = makeCoordinator()
        let bookID = UUID()
        let chapters = makeChapters(3, bookID: bookID)
        try await seedBook(in: db, chapters: chapters)
        try await store.save(PlaybackPosition(
            bookID: bookID, chapterID: chapters[1].id,
            position: 42, duration: 100
        ))
        let book = BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chapters)

        await coordinator.play(book)

        XCTAssertEqual(coordinator.currentSession?.chapter.id, chapters[1].id)
        XCTAssertEqual(engine.loadCalls.last?.startTime ?? -1, 42, accuracy: 0.001)
    }

    func testEngineZeroTimeDoesNotOverwriteSavedPosition() async throws {
        let (coordinator, engine, store, db) = makeCoordinator()
        let bookID = UUID()
        let chapters = makeChapters(2, bookID: bookID)
        try await seedBook(in: db, chapters: chapters)
        try await store.save(PlaybackPosition(
            bookID: bookID, chapterID: chapters[0].id,
            position: 60, duration: 100
        ))
        let book = BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: chapters)
        await coordinator.play(book)

        // Simulate the post-load, pre-ready window: engine reports 0 and not ready.
        engine.isReady = false
        engine.currentTime = 0
        coordinator.pause()
        // Let the fire-and-forget persist Task run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let saved = try await store.position(for: bookID, chapterID: chapters[0].id)
        XCTAssertEqual(saved?.position ?? -1, 60, accuracy: 0.001,
                       "A not-ready engine reporting 0 must never overwrite a good saved position")
    }
}
